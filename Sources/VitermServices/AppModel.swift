import Foundation
import GitKit
import Observation
import VitermCore

/// What the UI should do next as the result of dispatching a `PaletteAction`.
/// Operations requiring extra input (a dialog selection) are not executed; the UI is
/// expected to collect the remaining input and then call the corresponding `AppModel`
/// method (`createWorktree`, etc.) directly.
public enum PaletteDispatchOutcome: Sendable, Equatable {
    /// Open the new-worktree dialog.
    case openCreateWorktreeDialog
    /// Open the add-repository dialog (directory picker).
    case openAddRepositoryDialog
    /// Open the merge-strategy (merge/rebase) selection dialog.
    case confirmMergeWorktree(worktreeID: String)
    /// Open the removal confirmation dialog.
    case confirmRemoveWorktree(worktreeID: String)
    /// Executed on the spot and completed (switchToWorktree / startSession).
    case completed
    /// Attempted to execute on the spot but failed.
    case failed(String)
}

/// Abstracts the per-cycle wait of `AppModel.startAutoRefresh`. The default waits in
/// real time; tests can inject a fake that returns immediately to verify without
/// interval waits.
public protocol AutoRefreshClock: Sendable {
    func sleep(for duration: Duration) async
}

/// Default implementation that waits in real time (delegates to `Task.sleep`).
public struct SystemAutoRefreshClock: AutoRefreshClock {
    public init() {}
    public func sleep(for duration: Duration) async {
        try? await Task.sleep(for: duration)
    }
}

/// Orchestration layer for app state that the UI (VitermApp) binds to directly.
///
/// Builds and publishes a `SidebarViewModel` from: config load → merge of registered
/// repositories + auto-discovery → worktree status scan → session list. It performs no
/// git operations, file I/O, or session launching itself — everything goes through
/// injected abstractions (see `AppModelDependencies.swift`), so it can be unit-tested
/// deterministically with fakes.
///
/// Isolated with `@MainActor` since it is meant to be bound directly from AppKit.
/// `@Observable` is not SwiftUI-only — it comes from the `Observation` framework; the
/// AppKit side can subscribe manually via `withObservationTracking` or simply read
/// properties as needed.
@MainActor
@Observable
public final class AppModel {
    // MARK: Published state

    public private(set) var config: VitermConfig
    public private(set) var repositories: [Repository]
    public private(set) var worktrees: [VitermCore.Worktree]
    public private(set) var sessions: [AgentSession]
    public private(set) var sidebar: SidebarViewModel
    /// The worktree currently shown in the terminal pane (= target of `dispatch`'s `startSession`/`switchToWorktree`).
    public private(set) var currentWorktreeID: String?
    /// Non-fatal error messages from the most recent `refresh()`. Used for UI toasts and the like.
    public private(set) var lastRefreshErrors: [String]
    /// Fires on the main actor each time a `refresh()` driven by auto-refresh
    /// (`startAutoRefresh`) completes. `AppModel` is `@Observable`, but the AppKit side
    /// works via explicit calls (`render()`), so this callback is used as the UI redraw
    /// trigger.
    public var onRefreshCompleted: (() -> Void)?

    // MARK: Injected dependencies

    private let configProvider: any ConfigProviding
    private let repositoryConfigPersister: any RepositoryConfigPersisting
    private let sidebarPreferencePersister: any SidebarPreferencePersisting
    private let repositoryDiscovery: any RepositoryDiscovering
    private let worktreeStatusScanner: any WorktreeStatusScanning
    private let worktreeProvisioner: any WorktreeProvisioning
    private let worktreeRemover: any WorktreeRemoving
    private let mergeCleanupCoordinator: any MergeCleaningUp
    private var statusChangeHookRunner: any StatusChangeNotifying
    private let sessionLauncher: any SessionLaunching

    public init(
        configProvider: any ConfigProviding = LiveConfigProvider(),
        repositoryConfigPersister: any RepositoryConfigPersisting = LiveRepositoryConfigPersister(),
        sidebarPreferencePersister: any SidebarPreferencePersisting = LiveSidebarPreferencePersister(),
        repositoryDiscovery: any RepositoryDiscovering = RepositoryDiscovery(),
        worktreeStatusScanner: any WorktreeStatusScanning = WorktreeStatusScanner(),
        worktreeProvisioner: any WorktreeProvisioning = WorktreeProvisioner(),
        worktreeRemover: any WorktreeRemoving = GitService(),
        mergeCleanupCoordinator: any MergeCleaningUp = MergeCleanupCoordinator(),
        statusChangeHookRunner: any StatusChangeNotifying = StatusChangeHookRunner(config: StatusChangeHookConfig()),
        sessionLauncher: any SessionLaunching
    ) {
        self.configProvider = configProvider
        self.repositoryConfigPersister = repositoryConfigPersister
        self.sidebarPreferencePersister = sidebarPreferencePersister
        self.repositoryDiscovery = repositoryDiscovery
        self.worktreeStatusScanner = worktreeStatusScanner
        self.worktreeProvisioner = worktreeProvisioner
        self.worktreeRemover = worktreeRemover
        self.mergeCleanupCoordinator = mergeCleanupCoordinator
        self.statusChangeHookRunner = statusChangeHookRunner
        self.sessionLauncher = sessionLauncher

        config = .default
        repositories = []
        worktrees = []
        sessions = []
        sidebar = SidebarViewModel(repositories: [], worktrees: [], sessions: [])
        currentWorktreeID = nil
        lastRefreshErrors = []
    }

    // MARK: - Refresh

    /// Re-fetch and update state in order: config → registered repositories +
    /// auto-discovery → worktree scan. If loading the config fails, keep the previous
    /// config, record the error in `lastRefreshErrors`, and continue (per-repository
    /// failure isolation within the worktree scan itself is the responsibility of the
    /// `WorktreeStatusScanning` implementation).
    public func refresh() async {
        var errors: [String] = []

        let loadedConfig: VitermConfig
        do {
            loadedConfig = try configProvider.loadConfig(repositoryRoot: nil)
        } catch {
            errors.append("設定の読み込みに失敗しました: \(error)")
            loadedConfig = config
        }
        config = loadedConfig

        // Seed the sidebar display mode from config once, on the first successful load.
        // Later refreshes must not override an in-session toggle (the toggle also writes
        // the config back, but a stale in-flight read should never flip the UI).
        if !hasSeededSidebarDisplayMode {
            hasSeededSidebarDisplayMode = true
            sidebar.setDisplayMode(loadedConfig.sidebarDisplayMode)
        }

        var mergedRepositories = loadedConfig.repositories
        if !loadedConfig.discoveryRoots.isEmpty {
            let discovered = loadedConfig.discoveryRoots.flatMap { root in
                repositoryDiscovery.discover(rootDirectory: Self.expandDiscoveryRoot(root))
            }
            mergedRepositories = Self.merging(registered: mergedRepositories, discovered: discovered)
        }
        repositories = mergedRepositories

        worktrees = await worktreeStatusScanner.scan(repositories: repositories)

        statusChangeHookRunner.updateConfig(StatusChangeHookConfig(
            onBusy: loadedConfig.statusHooks.onBusy,
            onWaitingInput: loadedConfig.statusHooks.onWaitingInput,
            onIdle: loadedConfig.statusHooks.onIdle
        ))

        rebuildSidebar()
        lastRefreshErrors = errors
    }

    // MARK: - Auto refresh

    private var autoRefreshTask: Task<Void, Never>?
    /// Whether the previous auto-refresh-driven `refresh()` is still running (guards against overlapping runs).
    private var isAutoRefreshing = false

    /// Keep worktree ahead/behind, diffstat, dirty flags, etc. fresh by calling
    /// `refresh()` every `interval`. If auto-refresh is already running, stop it first
    /// and re-register (prevents duplicate loops). While the previous `refresh()` is
    /// still running, the next tick is skipped (never runs concurrently).
    public func startAutoRefresh(
        interval: Duration = .seconds(30),
        clock: any AutoRefreshClock = SystemAutoRefreshClock()
    ) {
        stopAutoRefresh()
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await clock.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.performAutoRefresh()
            }
        }
    }

    /// Stop auto-refresh. Any in-flight `refresh()` still runs to completion.
    public func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    private func performAutoRefresh() async {
        guard !isAutoRefreshing else { return }
        isAutoRefreshing = true
        defer { isAutoRefreshing = false }
        await refresh()
        onRefreshCompleted?()
    }

    /// Expand one `discoveryRoots` entry (a string that may contain `~`) into an actual directory URL.
    static func expandDiscoveryRoot(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// Prefer registered repositories (identified by `path`) and append ones found only by auto-discovery at the end.
    static func merging(registered: [Repository], discovered: [Repository]) -> [Repository] {
        var seenPaths = Set(registered.map(\.path))
        var merged = registered
        for repository in discovered where !seenPaths.contains(repository.path) {
            merged.append(repository)
            seenPaths.insert(repository.path)
        }
        return merged
    }

    private func rebuildSidebar() {
        // `rebuilt(...)` carries over all UI state (selection, per-worktree memory, filter)
        // in one place; adding a new carried field must not require touching this call site.
        sidebar = sidebar.rebuilt(
            repositories: repositories,
            worktrees: worktrees,
            sessions: sessions
        )
    }

    /// Update the sidebar's incremental filter text.
    public func setSidebarFilter(_ text: String) {
        sidebar.setFilterText(text)
    }

    /// Whether the display mode has been seeded from config (first successful load only).
    private var hasSeededSidebarDisplayMode = false

    /// Switch the sidebar body mode (tree / state lanes) and persist it to the global
    /// config. A persistence failure keeps the in-memory switch and is surfaced via
    /// `lastRefreshErrors` (same channel the UI already uses for toasts).
    public func setSidebarDisplayMode(_ mode: SidebarDisplayMode) {
        sidebar.setDisplayMode(mode)
        do {
            try sidebarPreferencePersister.persist(sidebarDisplayMode: mode)
        } catch {
            lastRefreshErrors.append("サイドバー表示モードの保存に失敗しました: \(error)")
        }
    }

    // MARK: - PaletteAction dispatch

    /// Handle a `PaletteAction`. Operations requiring extra input (create / add / merge /
    /// remove) only return an outcome indicating a dialog should open — nothing is
    /// executed. Operations that can run immediately (switch / launch) are executed here
    /// and their result returned.
    public func dispatch(_ action: PaletteAction) async -> PaletteDispatchOutcome {
        switch action {
        case .createWorktree:
            return .openCreateWorktreeDialog
        case .addRepository:
            return .openAddRepositoryDialog
        case let .mergeWorktree(worktreeID):
            return .confirmMergeWorktree(worktreeID: worktreeID)
        case let .removeWorktree(worktreeID):
            return .confirmRemoveWorktree(worktreeID: worktreeID)
        case let .switchToWorktree(worktreeID):
            await switchToWorktree(worktreeID)
            return .completed
        case let .startSession(worktreeID, presetName):
            do {
                _ = try await startSession(worktreePath: worktreeID, presetName: presetName)
                return .completed
            } catch {
                return .failed("\(error)")
            }
        }
    }

    // MARK: - Worktree creation

    /// Turn the result of `NewWorktreeFormModel.buildRequest()` into an actual creation
    /// and execute it. The 1:1 conversion `VitermCore.NewWorktreeSource` →
    /// `GitKit.WorktreeSource` happens here (VitermCore cannot depend on GitKit, so the
    /// conversion belongs to this layer, which can). On success, `refresh()` brings state
    /// up to date, and if `launchSessionPresetName` is set, a session is launched too.
    @discardableResult
    public func createWorktree(from formRequest: NewWorktreeRequest) async throws -> WorktreeCreationResult {
        let source: WorktreeSource = switch formRequest.source {
        case let .newBranch(name, startPoint):
            .newBranch(name: name, startPoint: startPoint)
        case let .existingLocalBranch(name):
            .existingLocalBranch(name: name)
        case let .remoteBranch(remote, name, newLocalName):
            .remoteBranch(remote: remote, name: name, newLocalName: newLocalName)
        }

        // If no hook was explicitly specified in the form, use the config's default post-creation hook.
        let postCreationHookCommand: String? = if let formHook = formRequest.runHookCommand, !formHook.isEmpty {
            formHook
        } else {
            config.postCreationHook
        }

        let request = WorktreeCreationRequest(
            repository: formRequest.repository,
            source: source,
            pathTemplate: formRequest.pathTemplate,
            copySessionData: formRequest.copySessionData,
            postCreationHookCommand: postCreationHookCommand
        )

        let result = try await worktreeProvisioner.createWorktree(request)
        await refresh()

        if let presetName = formRequest.launchSessionPresetName {
            _ = try? await startSession(worktreePath: result.worktreePath, presetName: presetName)
        }

        return result
    }

    // MARK: - Merge / removal

    /// Run merge/rebase plus worktree/branch cleanup, then `refresh()` when done.
    @discardableResult
    public func mergeAndCleanUp(_ request: MergeCleanupRequest) async -> MergeCleanupResult {
        let result = await mergeCleanupCoordinator.mergeAndCleanUp(request)
        await refresh()
        return result
    }

    /// Remove a worktree on its own, without merging. Runs `refresh()` when done.
    public func removeWorktree(at path: String, in repositoryPath: String, force: Bool = false) async throws {
        try await worktreeRemover.removeWorktree(
            at: URL(fileURLWithPath: path),
            in: URL(fileURLWithPath: repositoryPath),
            force: force
        )
        await refresh()
    }

    /// Delete a local branch (`git branch -d`, safe by default). Kept separate from
    /// `removeWorktree` so the caller can treat a failed branch deletion (e.g. unmerged
    /// commits) as non-fatal after the worktree itself was already removed.
    public func deleteBranch(_ name: String, in repositoryPath: String, force: Bool = false) async throws {
        try await worktreeRemover.deleteBranch(name, in: URL(fileURLWithPath: repositoryPath), force: force)
        await refresh()
    }

    // MARK: - Repository registration

    /// Register a repository, persist it to the global config, then `refresh()`.
    /// If the same `path` is already registered, only the name is overwritten (no duplicates).
    @discardableResult
    public func addRepository(name: String, path: String) async throws -> Repository {
        let repository = Repository(name: name, path: path)
        var updated = repositories
        if let index = updated.firstIndex(where: { $0.path == repository.path }) {
            updated[index] = repository
        } else {
            updated.append(repository)
        }
        try repositoryConfigPersister.persist(repositories: updated)
        await refresh()
        return repository
    }

    // MARK: - Sessions (interim entry point until the T6 SessionManager integration)

    /// Launch a session via `SessionLaunching` and add it to the list.
    @discardableResult
    public func startSession(worktreePath: String, presetName: String) async throws -> AgentSession {
        let session = try await sessionLauncher.startSession(worktreePath: worktreePath, presetName: presetName)
        sessions.append(session)
        rebuildSidebar()
        return session
    }

    /// Switch the displayed worktree.
    public func switchToWorktree(_ worktreePath: String) async {
        currentWorktreeID = worktreePath
        await sessionLauncher.switchToWorktree(worktreePath)
    }

    /// Rename a session's display name.
    public func renameSession(_ sessionID: AgentSession.ID, to newName: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              !newName.isEmpty else { return }
        sessions[index].displayName = newName
        rebuildSidebar()
    }

    /// Remove a session from the list (destroying the PTY/surface is the caller's —
    /// SessionManager's — responsibility).
    ///
    /// If the closed session was the active tab (the selected session), the selected
    /// worktree stays and selection automatically moves to another tab of the same
    /// worktree (delegated to `selectWorktree`'s remembered-selection logic). If no tabs
    /// remain in the worktree, the selection is cleared.
    public func removeSession(_ sessionID: AgentSession.ID) {
        sessions.removeAll { $0.id == sessionID }
        let worktreePathToReselect = sidebar.selectedSessionID == sessionID ? sidebar.selectedWorktreePath : nil
        rebuildSidebar()
        if let worktreePathToReselect {
            sidebar.selectWorktree(worktreePathToReselect)
        }
    }

    /// Entry point for session state changes. Pass the new state finalized by
    /// `SessionStateMachine` or similar. If the state actually changed, updates the
    /// `AgentSession` and fires the `StatusChangeHookRunner`.
    public func sessionStateChanged(sessionID: AgentSession.ID, newState: AgentSession.State, at date: Date = Date()) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let oldState = sessions[index].state
        guard oldState != newState else { return }

        sessions[index].state = newState
        sessions[index].stateChangedAt = date

        statusChangeHookRunner.notify(
            sessionName: sessions[index].displayName,
            worktreePath: sessions[index].worktreePath,
            oldState: oldState,
            newState: newState
        )

        rebuildSidebar()
    }

    // MARK: - Sidebar selection (thin delegation to SidebarViewModel)

    public func selectSession(_ sessionID: AgentSession.ID?) {
        sidebar.select(sessionID: sessionID)
    }

    public func selectNextSession() {
        sidebar.selectNext()
    }

    public func selectPreviousSession() {
        sidebar.selectPrevious()
    }

    @discardableResult
    public func jumpToLatestWaitingSession() -> Bool {
        sidebar.jumpToLatestWaiting()
    }

    /// Select a worktree (switches what the selection refers to). `nil` clears the selection.
    public func selectWorktree(_ path: String?) {
        sidebar.selectWorktree(path)
    }

    /// Equivalent to ⌘⌥↓: select the next worktree in display order (across repositories, wrapping).
    public func selectNextWorktree() {
        sidebar.selectNextWorktree()
    }

    /// Equivalent to ⌘⌥↑: select the previous worktree in display order (across repositories, wrapping).
    public func selectPreviousWorktree() {
        sidebar.selectPreviousWorktree()
    }
}
