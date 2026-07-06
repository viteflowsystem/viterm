import Foundation
import GitKit
import Observation
import VitermCore

/// What the UI should do next after dispatching a `PaletteAction`.
/// Operations that need additional input (a choice made in a dialog) are not executed;
/// the UI is expected to collect the remaining input and then call the corresponding
/// `AppModel` method (`createWorktree`, etc.) directly.
public enum PaletteDispatchOutcome: Sendable, Equatable {
    /// Open the new-worktree creation dialog.
    case openCreateWorktreeDialog
    /// Open the add-repository dialog (directory picker).
    case openAddRepositoryDialog
    /// Open the merge-method (merge/rebase) selection dialog.
    case confirmMergeWorktree(worktreeID: String)
    /// Open the removal confirmation dialog.
    case confirmRemoveWorktree(worktreeID: String)
    /// Executed on the spot and completed (switchToWorktree / startSession).
    case completed
    /// Attempted to execute on the spot but failed.
    case failed(String)
}

/// Abstracts the wait for one cycle of `AppModel.startAutoRefresh`. The default waits in
/// real time, but tests can inject a fake that returns immediately so verification runs
/// without interval waits.
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

/// Orchestration layer for the app state that the UI (VitermApp) binds to directly.
///
/// Builds and publishes a `SidebarViewModel` from: config load → merge of registered
/// repositories + auto-discovery → worktree status scan → session list. It performs no
/// git operations, file I/O, or session launches itself — everything goes through the
/// injected abstractions (see `AppModelDependencies.swift`), so it can be unit tested
/// deterministically with fakes.
///
/// Isolated to `@MainActor` because it is meant to be bound directly from AppKit.
/// It carries `@Observable`, but that is not SwiftUI-specific — it comes from the
/// `Observation` framework, so the AppKit side can subscribe manually via
/// `withObservationTracking` or simply read properties on demand.
@MainActor
@Observable
public final class AppModel {
    // MARK: Published state

    public private(set) var config: VitermConfig
    public private(set) var repositories: [Repository]
    public private(set) var worktrees: [VitermCore.Worktree]
    public private(set) var sessions: [AgentSession]
    public private(set) var sidebar: SidebarViewModel
    /// The worktree currently shown in the terminal pane (= the target of `dispatch`'s `startSession`/`switchToWorktree`).
    public private(set) var currentWorktreeID: String?
    /// Non-fatal error messages produced by the most recent `refresh()`. Used for UI toasts, etc.
    public private(set) var lastRefreshErrors: [String]
    /// Fired on the main actor each time a `refresh()` completes via auto-refresh (`startAutoRefresh`).
    /// `AppModel` is `@Observable`, but the AppKit side assumes explicit calls (`render()`),
    /// so this callback is used as the redraw trigger for the UI.
    public var onRefreshCompleted: (() -> Void)?

    // MARK: Injected dependencies

    private let configProvider: any ConfigProviding
    private let repositoryConfigPersister: any RepositoryConfigPersisting
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

    /// Re-fetches, in order: config → registered repositories + auto-discovery → worktree scan,
    /// and updates the state. If loading the config fails, keeps the previous config, records the
    /// error in `lastRefreshErrors`, and continues (per-repository failure isolation within the
    /// worktree scan itself is the responsibility of the `WorktreeStatusScanning` implementation).
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
    /// Whether the previous auto-refresh-triggered `refresh()` is still running (guards against overlapping runs).
    private var isAutoRefreshing = false

    /// Keeps worktree ahead/behind, diffstat, dirty state, etc. up to date by calling `refresh()` every `interval`.
    /// If auto-refresh is already running, stops it first and re-registers (prevents duplicate starts).
    /// While the previous `refresh()` is still running, the next tick is skipped (runs never overlap).
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

    /// Stops auto-refresh. A `refresh()` already in progress runs to completion.
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

    /// Expands one `discoveryRoots` entry (a string that may contain `~`) into an actual directory URL.
    static func expandDiscoveryRoot(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// Prefers registered repositories (identified by `path`) and appends any found only via auto-discovery at the end.
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
        let previousSelection = sidebar.selectedSessionID
        sidebar = SidebarViewModel(
            repositories: repositories,
            worktrees: worktrees,
            sessions: sessions,
            selectedSessionID: previousSelection
        )
    }

    // MARK: - PaletteAction dispatch

    /// Handles a `PaletteAction`. For operations that need additional input (create, add,
    /// merge, remove) it only returns an outcome indicating that a dialog should be opened,
    /// without executing anything. Operations that can run immediately (switch, launch)
    /// are executed here and their result returned.
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

    /// Converts the result of `NewWorktreeFormModel.buildRequest()` into an actual creation and executes it.
    /// The 1:1 conversion from `VitermCore.NewWorktreeSource` to `GitKit.WorktreeSource` happens here
    /// (VitermCore cannot depend on GitKit, so the conversion is the responsibility of this layer, which can).
    /// After success, calls `refresh()` to bring the state up to date, and launches a session if
    /// `launchSessionPresetName` is present.
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

        // If no hook was explicitly specified in the form, use the default post-creation hook from the config.
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

    /// Runs merge/rebase plus worktree and branch cleanup, then calls `refresh()` when done.
    @discardableResult
    public func mergeAndCleanUp(_ request: MergeCleanupRequest) async -> MergeCleanupResult {
        let result = await mergeCleanupCoordinator.mergeAndCleanUp(request)
        await refresh()
        return result
    }

    /// Standalone worktree removal without a merge. Calls `refresh()` when done.
    public func removeWorktree(at path: String, in repositoryPath: String, force: Bool = false) async throws {
        try await worktreeRemover.removeWorktree(
            at: URL(fileURLWithPath: path),
            in: URL(fileURLWithPath: repositoryPath),
            force: force
        )
        await refresh()
    }

    // MARK: - Repository registration

    /// Registers a repository, persists it to the global config, then calls `refresh()`.
    /// If the same `path` is already registered, only the name is overwritten (no duplicate registration).
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

    /// Launches a session via `SessionLaunching` and adds it to the list.
    @discardableResult
    public func startSession(worktreePath: String, presetName: String) async throws -> AgentSession {
        let session = try await sessionLauncher.startSession(worktreePath: worktreePath, presetName: presetName)
        sessions.append(session)
        rebuildSidebar()
        return session
    }

    /// Switches the currently displayed worktree.
    public func switchToWorktree(_ worktreePath: String) async {
        currentWorktreeID = worktreePath
        await sessionLauncher.switchToWorktree(worktreePath)
    }

    /// Renames a session's display name.
    public func renameSession(_ sessionID: AgentSession.ID, to newName: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              !newName.isEmpty else { return }
        sessions[index].displayName = newName
        rebuildSidebar()
    }

    /// Removes a session from the list (disposing the PTY/surface is the caller's = SessionManager's responsibility).
    public func removeSession(_ sessionID: AgentSession.ID) {
        sessions.removeAll { $0.id == sessionID }
        if sidebar.selectedSessionID == sessionID {
            sidebar.select(sessionID: nil)
        }
        rebuildSidebar()
    }

    /// Entry point for session state changes. Receives the new state finalized by `SessionStateMachine` etc.
    /// If the state actually changed, updates the `AgentSession` and fires the `StatusChangeHookRunner`.
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
    public func selectShortcut(_ number: Int) -> Bool {
        sidebar.selectShortcut(number)
    }

    @discardableResult
    public func jumpToLatestWaitingSession() -> Bool {
        sidebar.jumpToLatestWaiting()
    }
}
