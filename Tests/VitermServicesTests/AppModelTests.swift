import Foundation
import GitKit
import Testing
import VitermCore
@testable import VitermServices

// MARK: - Fakes
//
// AppModel never runs git, does file I/O, or launches sessions itself — everything goes
// through the protocols in AppModelDependencies.swift. Here we provide fakes for those
// and verify only AppModel's behavior, without touching real git or the real filesystem.

/// Fake behaving as one in-memory state for both config loading and persistence
/// (used to verify that addRepository → refresh re-reads what was saved).
final class FakeConfigStore: ConfigProviding, RepositoryConfigPersisting, @unchecked Sendable {
    var config: VitermConfig
    var loadError: Error?

    init(config: VitermConfig = .default) {
        self.config = config
    }

    func loadConfig(repositoryRoot: URL?) throws -> VitermConfig {
        if let loadError { throw loadError }
        return config
    }

    func persist(repositories: [Repository]) throws {
        config.repositories = repositories
    }
}


final class FakeSidebarPreferencePersister: SidebarPreferencePersisting, @unchecked Sendable {
    var persistedModes: [SidebarDisplayMode] = []
    var errorToThrow: Error?

    func persist(sidebarDisplayMode: SidebarDisplayMode) throws {
        if let errorToThrow { throw errorToThrow }
        persistedModes.append(sidebarDisplayMode)
    }
}

final class FakeRepositoryDiscovery: RepositoryDiscovering, @unchecked Sendable {
    /// Result returned per root directory (its `path`). Falls back to `defaultRepositoriesToReturn`.
    var repositoriesByRoot: [String: [Repository]] = [:]
    var defaultRepositoriesToReturn: [Repository] = []
    private(set) var requestedRootDirectories: [URL] = []

    func discover(rootDirectory: URL) -> [Repository] {
        requestedRootDirectories.append(rootDirectory)
        return repositoriesByRoot[rootDirectory.path] ?? defaultRepositoriesToReturn
    }
}

final class FakeWorktreeStatusScanner: WorktreeStatusScanning, @unchecked Sendable {
    var worktreesToReturn: [VitermCore.Worktree] = []
    private(set) var scannedRepositories: [[Repository]] = []

    func scan(repositories: [Repository]) async -> [VitermCore.Worktree] {
        scannedRepositories.append(repositories)
        return worktreesToReturn
    }
}

final class FakeWorktreeProvisioner: WorktreeProvisioning, @unchecked Sendable {
    var resultToReturn: Result<WorktreeCreationResult, Error> = .success(
        WorktreeCreationResult(worktreePath: "/wt/result", branch: "result-branch")
    )
    private(set) var receivedRequests: [WorktreeCreationRequest] = []

    func createWorktree(_ request: WorktreeCreationRequest) async throws -> WorktreeCreationResult {
        receivedRequests.append(request)
        return try resultToReturn.get()
    }
}

final class FakeWorktreeRemover: WorktreeRemoving, @unchecked Sendable {
    private(set) var removedPaths: [(path: URL, repository: URL, force: Bool)] = []
    private(set) var deletedBranches: [(name: String, repository: URL, force: Bool)] = []
    var shouldThrow = false
    var branchDeletionShouldThrow = false

    func removeWorktree(at path: URL, in repository: URL, force: Bool) async throws {
        if shouldThrow { throw StubError(description: "remove failed") }
        removedPaths.append((path, repository, force))
    }

    func deleteBranch(_ name: String, in repository: URL, force: Bool) async throws {
        if branchDeletionShouldThrow { throw StubError(description: "branch delete failed") }
        deletedBranches.append((name, repository, force))
    }
}

final class FakeMergeCleanupCoordinator: MergeCleaningUp, @unchecked Sendable {
    var resultToReturn = MergeCleanupResult(steps: [MergeCleanupStepResult(step: .merge)])
    private(set) var receivedRequests: [MergeCleanupRequest] = []

    func mergeAndCleanUp(_ request: MergeCleanupRequest) async -> MergeCleanupResult {
        receivedRequests.append(request)
        return resultToReturn
    }
}

final class FakeStatusChangeNotifier: StatusChangeNotifying, @unchecked Sendable {
    struct Call: Equatable {
        var sessionName: String
        var worktreePath: String
        var oldState: AgentSession.State?
        var newState: AgentSession.State
    }

    private(set) var calls: [Call] = []
    private(set) var configUpdates: [StatusChangeHookConfig] = []

    @discardableResult
    func notify(
        sessionName: String,
        worktreePath: String,
        oldState: AgentSession.State?,
        newState: AgentSession.State
    ) -> Task<Void, Never>? {
        calls.append(Call(sessionName: sessionName, worktreePath: worktreePath, oldState: oldState, newState: newState))
        return nil
    }

    func updateConfig(_ config: StatusChangeHookConfig) {
        configUpdates.append(config)
    }
}

final class FakeSessionLauncher: SessionLaunching, @unchecked Sendable {
    var shouldThrow = false
    private(set) var startedRequests: [(worktreePath: String, presetName: String)] = []
    private(set) var switchedWorktrees: [String] = []

    func startSession(worktreePath: String, presetName: String) async throws -> AgentSession {
        startedRequests.append((worktreePath, presetName))
        if shouldThrow { throw StubError(description: "start failed") }
        return AgentSession(worktreePath: worktreePath, presetName: presetName, displayName: presetName)
    }

    func switchToWorktree(_ worktreePath: String) async {
        switchedWorktrees.append(worktreePath)
    }
}

/// Immediately-firing test clock. Returns from `sleep(for:)` right away without waiting
/// real time. Used to skip `startAutoRefresh`'s polling-interval wait and produce ticks
/// immediately.
struct ImmediateAutoRefreshClock: AutoRefreshClock {
    func sleep(for duration: Duration) async {}
}

/// Clock whose first `sleep(for:)` fires immediately while subsequent calls wait
/// effectively forever (on the test's time scale). For tests that want to verify only
/// the first tick without busy-looping afterwards (the `stopAutoRefresh` verification).
actor SingleShotThenForeverAutoRefreshClock: AutoRefreshClock {
    private var hasFiredOnce = false

    func sleep(for duration: Duration) async {
        guard hasFiredOnce else {
            hasFiredOnce = true
            return
        }
        try? await Task.sleep(for: .seconds(3600))
    }
}

/// Gate allowing external control over when `scan(repositories:)` completes.
/// To verify that "the next tick is skipped while the previous refresh() is still
/// running", the scan is deliberately paused and completed at a moment of the test's
/// choosing.
actor AutoRefreshGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// Scanner whose `scan` completion timing is controlled via `AutoRefreshGate`.
actor GatedWorktreeStatusScanner: WorktreeStatusScanning {
    let gate = AutoRefreshGate()
    private(set) var scanCount = 0

    func scan(repositories: [Repository]) async -> [VitermCore.Worktree] {
        scanCount += 1
        await gate.wait()
        return []
    }
}

// MARK: - Tests

@MainActor
@Suite("AppModel")
struct AppModelTests {
    let repository = Repository(name: "viterm", path: "/repo/viterm")

    func makeModel(
        configStore: FakeConfigStore = FakeConfigStore(),
        sidebarPersister: FakeSidebarPreferencePersister = FakeSidebarPreferencePersister(),
        discovery: FakeRepositoryDiscovery = FakeRepositoryDiscovery(),
        scanner: any WorktreeStatusScanning = FakeWorktreeStatusScanner(),
        provisioner: FakeWorktreeProvisioner = FakeWorktreeProvisioner(),
        remover: FakeWorktreeRemover = FakeWorktreeRemover(),
        merger: FakeMergeCleanupCoordinator = FakeMergeCleanupCoordinator(),
        notifier: FakeStatusChangeNotifier = FakeStatusChangeNotifier(),
        launcher: FakeSessionLauncher = FakeSessionLauncher()
    ) -> AppModel {
        AppModel(
            configProvider: configStore,
            repositoryConfigPersister: configStore,
            sidebarPreferencePersister: sidebarPersister,
            repositoryDiscovery: discovery,
            worktreeStatusScanner: scanner,
            worktreeProvisioner: provisioner,
            worktreeRemover: remover,
            mergeCleanupCoordinator: merger,
            statusChangeHookRunner: notifier,
            sessionLauncher: launcher
        )
    }

    // MARK: refresh()

    @Test("refreshは設定のリポジトリとスキャン結果を反映する")
    func refreshPopulatesStateFromConfigAndScanner() async {
        let configStore = FakeConfigStore(config: VitermConfig.merge(
            global: VitermConfigFile(repositories: [repository]),
            project: nil
        ))
        let scanner = FakeWorktreeStatusScanner()
        let worktree = VitermCore.Worktree(path: "/repo/viterm", repositoryPath: repository.path, branch: "main")
        scanner.worktreesToReturn = [worktree]

        let model = makeModel(configStore: configStore, scanner: scanner)
        await model.refresh()

        #expect(model.repositories == [repository])
        #expect(model.worktrees == [worktree])
        #expect(model.sidebar.repositories.map(\.repository.name) == ["viterm"])
        #expect(model.lastRefreshErrors.isEmpty)
        #expect(scanner.scannedRepositories.last == [repository])
    }

    @Test("設定のdiscoveryRootsがあれば自動検出の結果をマージし、登録済みが優先される")
    func refreshMergesDiscoveredRepositoriesWithRegisteredTakingPriority() async {
        let configStore = FakeConfigStore(config: VitermConfig.merge(
            global: VitermConfigFile(
                repositories: [Repository(name: "registered-name", path: "/repo/shared")],
                discoveryRoots: ["/root"]
            ),
            project: nil
        ))
        let discovery = FakeRepositoryDiscovery()
        discovery.defaultRepositoriesToReturn = [
            Repository(name: "discovered-name", path: "/repo/shared"),
            Repository(name: "extra", path: "/repo/extra"),
        ]

        let model = makeModel(configStore: configStore, discovery: discovery)
        await model.refresh()

        #expect(model.repositories.map(\.name) == ["registered-name", "extra"])
        #expect(discovery.requestedRootDirectories == [URL(fileURLWithPath: "/root")])
    }

    @Test("discoveryRootsが複数あればそれぞれについて自動検出し、結果を合算する")
    func refreshDiscoversAcrossMultipleRoots() async {
        let configStore = FakeConfigStore(config: VitermConfig.merge(
            global: VitermConfigFile(discoveryRoots: ["/root-a", "/root-b"]),
            project: nil
        ))
        let discovery = FakeRepositoryDiscovery()
        discovery.repositoriesByRoot = [
            "/root-a": [Repository(name: "repo-a", path: "/repo/a")],
            "/root-b": [Repository(name: "repo-b", path: "/repo/b")],
        ]

        let model = makeModel(configStore: configStore, discovery: discovery)
        await model.refresh()

        #expect(model.repositories.map(\.name).sorted() == ["repo-a", "repo-b"])
        #expect(discovery.requestedRootDirectories.map(\.path).sorted() == ["/root-a", "/root-b"])
    }

    @Test("discoveryRootsが空なら自動検出は呼ばれない")
    func refreshSkipsDiscoveryWhenRootsAreEmpty() async {
        let configStore = FakeConfigStore()
        let discovery = FakeRepositoryDiscovery()

        let model = makeModel(configStore: configStore, discovery: discovery)
        await model.refresh()

        #expect(discovery.requestedRootDirectories.isEmpty)
    }

    @Test("discoveryRootsの~はホームディレクトリに展開される")
    func refreshExpandsTildeInDiscoveryRoots() async {
        let configStore = FakeConfigStore(config: VitermConfig.merge(
            global: VitermConfigFile(discoveryRoots: ["~/dev"]),
            project: nil
        ))
        let discovery = FakeRepositoryDiscovery()

        let model = makeModel(configStore: configStore, discovery: discovery)
        await model.refresh()

        #expect(discovery.requestedRootDirectories == [URL(fileURLWithPath: NSHomeDirectory() + "/dev")])
    }

    @Test("refreshはconfigのstatusHooksをStatusChangeHookConfigとして反映する")
    func refreshAppliesStatusHooksToNotifier() async {
        let configStore = FakeConfigStore(config: VitermConfig.merge(
            global: VitermConfigFile(statusHooks: StatusHooksFile(onBusy: "notify-busy", onIdle: "notify-idle")),
            project: nil
        ))
        let notifier = FakeStatusChangeNotifier()

        let model = makeModel(configStore: configStore, notifier: notifier)
        await model.refresh()

        #expect(notifier.configUpdates.count == 1)
        #expect(notifier.configUpdates.first == StatusChangeHookConfig(onBusy: "notify-busy", onWaitingInput: nil, onIdle: "notify-idle"))
    }

    @Test("設定の読み込みに失敗しても前回の設定を維持しエラーを記録する")
    func refreshIsolatesConfigLoadFailure() async {
        let configStore = FakeConfigStore(config: VitermConfig.merge(
            global: VitermConfigFile(repositories: [repository]),
            project: nil
        ))
        let model = makeModel(configStore: configStore)
        await model.refresh()
        #expect(model.repositories == [repository])

        configStore.loadError = StubError(description: "boom")
        await model.refresh()

        #expect(model.lastRefreshErrors.count == 1)
        #expect(model.repositories == [repository], "直前の設定(リポジトリ一覧)が維持される")
    }

    // MARK: startAutoRefresh / stopAutoRefresh

    @Test("startAutoRefreshはクロックが即座に発火するとrefreshを実行し、onRefreshCompletedを呼ぶ")
    func startAutoRefreshTriggersRefreshAndNotifiesCompletion() async {
        let scanner = FakeWorktreeStatusScanner()
        let model = makeModel(scanner: scanner)

        // onRefreshCompleted is called from AppModel (@MainActor) and this test itself
        // also runs on @MainActor, so a simple local-variable capture counts safely.
        var completedCount = 0
        model.onRefreshCompleted = { completedCount += 1 }

        model.startAutoRefresh(interval: .seconds(30), clock: ImmediateAutoRefreshClock())
        defer { model.stopAutoRefresh() }

        while completedCount == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(scanner.scannedRepositories.count >= 1)
        #expect(completedCount >= 1)
    }

    @Test("前回のrefreshが走っている間は次のtickをスキップする(重複実行防止)")
    func startAutoRefreshSkipsOverlappingTicks() async {
        let scanner = GatedWorktreeStatusScanner()
        let model = makeModel(scanner: scanner)

        model.startAutoRefresh(interval: .seconds(30), clock: ImmediateAutoRefreshClock())
        defer { model.stopAutoRefresh() }

        // Wait until the first refresh() is held up inside scan().
        while await scanner.scanCount == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }

        // The clock fires immediately, so multiple ticks should be arriving meanwhile, but
        // scan() doesn't increase because the first refresh() hasn't completed yet.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await scanner.scanCount == 1, "前回の refresh() が完了するまで次の tick はスキップされる")

        await scanner.gate.open()

        // Once the first completes, refresh() resumes on later ticks and scan() gets called.
        while await scanner.scanCount < 2 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await scanner.scanCount >= 2)
    }

    @Test("stopAutoRefreshを呼ぶと以降のtickは発生しない")
    func stopAutoRefreshHaltsFurtherTicks() async {
        let scanner = FakeWorktreeStatusScanner()
        let model = makeModel(scanner: scanner)

        model.startAutoRefresh(interval: .seconds(30), clock: SingleShotThenForeverAutoRefreshClock())
        while scanner.scannedRepositories.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        model.stopAutoRefresh()

        let countAfterStop = scanner.scannedRepositories.count
        try? await Task.sleep(for: .milliseconds(100))
        #expect(scanner.scannedRepositories.count == countAfterStop, "stopAutoRefresh後は新たなrefreshが走らない")
    }

    // MARK: dispatch(_:)

    @Test("createWorktreeのdispatchはダイアログを開くべきことを示すだけで何も実行しない")
    func dispatchCreateWorktreeOpensDialog() async {
        let provisioner = FakeWorktreeProvisioner()
        let model = makeModel(provisioner: provisioner)
        let outcome = await model.dispatch(.createWorktree)
        #expect(outcome == .openCreateWorktreeDialog)
        #expect(provisioner.receivedRequests.isEmpty)
    }

    @Test("addRepositoryのdispatchはダイアログを開くべきことを示す")
    func dispatchAddRepositoryOpensDialog() async {
        let model = makeModel()
        let outcome = await model.dispatch(.addRepository)
        #expect(outcome == .openAddRepositoryDialog)
    }

    @Test("mergeWorktreeのdispatchは確認を促すだけで実行しない")
    func dispatchMergeWorktreeAsksForConfirmation() async {
        let merger = FakeMergeCleanupCoordinator()
        let model = makeModel(merger: merger)
        let outcome = await model.dispatch(.mergeWorktree(worktreeID: "/wt/feat"))
        #expect(outcome == .confirmMergeWorktree(worktreeID: "/wt/feat"))
        #expect(merger.receivedRequests.isEmpty)
    }

    @Test("removeWorktreeのdispatchは確認を促すだけで実行しない")
    func dispatchRemoveWorktreeAsksForConfirmation() async {
        let remover = FakeWorktreeRemover()
        let model = makeModel(remover: remover)
        let outcome = await model.dispatch(.removeWorktree(worktreeID: "/wt/feat"))
        #expect(outcome == .confirmRemoveWorktree(worktreeID: "/wt/feat"))
        #expect(remover.removedPaths.isEmpty)
    }

    @Test("switchToWorktreeのdispatchは即座に実行され、currentWorktreeIDが更新される")
    func dispatchSwitchToWorktreeExecutesImmediately() async {
        let launcher = FakeSessionLauncher()
        let model = makeModel(launcher: launcher)
        let outcome = await model.dispatch(.switchToWorktree(worktreeID: "/wt/feat"))
        #expect(outcome == .completed)
        #expect(model.currentWorktreeID == "/wt/feat")
        #expect(launcher.switchedWorktrees == ["/wt/feat"])
    }

    @Test("startSessionのdispatchは即座に実行され、セッションが追加される")
    func dispatchStartSessionExecutesImmediately() async {
        let launcher = FakeSessionLauncher()
        let model = makeModel(launcher: launcher)
        let outcome = await model.dispatch(.startSession(worktreeID: "/wt/feat", presetName: "claude"))
        #expect(outcome == .completed)
        #expect(model.sessions.count == 1)
        #expect(launcher.startedRequests.first?.presetName == "claude")
    }

    @Test("startSessionのdispatchが失敗した場合はfailedを返す")
    func dispatchStartSessionFailure() async {
        let launcher = FakeSessionLauncher()
        launcher.shouldThrow = true
        let model = makeModel(launcher: launcher)
        let outcome = await model.dispatch(.startSession(worktreeID: "/wt/feat", presetName: "claude"))
        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(model.sessions.isEmpty)
    }

    // MARK: createWorktree(from:)

    @Test("createWorktreeはNewWorktreeSourceの3パターンをGitKit.WorktreeSourceに変換する")
    func createWorktreeConvertsSourceForAllModes() async throws {
        let provisioner = FakeWorktreeProvisioner()
        let model = makeModel(provisioner: provisioner)
        let template = WorktreePathTemplate("~/worktrees/{project}/{branch}")

        let newBranchRequest = NewWorktreeRequest(
            repository: repository, source: .newBranch(name: "feat", startPoint: "develop"),
            worktreePath: "/wt/feat", pathTemplate: template
        )
        _ = try await model.createWorktree(from: newBranchRequest)

        let existingRequest = NewWorktreeRequest(
            repository: repository, source: .existingLocalBranch(name: "main"),
            worktreePath: "/wt/main", pathTemplate: template
        )
        _ = try await model.createWorktree(from: existingRequest)

        let remoteRequest = NewWorktreeRequest(
            repository: repository, source: .remoteBranch(remote: "origin", name: "feature", newLocalName: nil),
            worktreePath: "/wt/feature", pathTemplate: template
        )
        _ = try await model.createWorktree(from: remoteRequest)

        #expect(provisioner.receivedRequests.count == 3)
        #expect(provisioner.receivedRequests[0].source == .newBranch(name: "feat", startPoint: "develop"))
        #expect(provisioner.receivedRequests[1].source == .existingLocalBranch(name: "main"))
        #expect(provisioner.receivedRequests[2].source == .remoteBranch(remote: "origin", name: "feature", newLocalName: nil))
    }

    @Test("createWorktreeは作成後にrefreshし、launchSessionPresetNameがあればセッションも起動する")
    func createWorktreeRefreshesAndLaunchesSession() async throws {
        let scanner = FakeWorktreeStatusScanner()
        let launcher = FakeSessionLauncher()
        let provisioner = FakeWorktreeProvisioner()
        provisioner.resultToReturn = .success(WorktreeCreationResult(worktreePath: "/wt/feat", branch: "feat"))

        let model = makeModel(scanner: scanner, provisioner: provisioner, launcher: launcher)
        let request = NewWorktreeRequest(
            repository: repository, source: .newBranch(name: "feat", startPoint: nil),
            worktreePath: "/wt/feat", pathTemplate: WorktreePathTemplate("~/wt/{branch}"),
            launchSessionPresetName: "claude"
        )

        let result = try await model.createWorktree(from: request)

        #expect(result.worktreePath == "/wt/feat")
        #expect(scanner.scannedRepositories.count == 1, "作成後にrefreshが呼ばれてスキャンが実行される")
        #expect(launcher.startedRequests.first?.worktreePath == "/wt/feat")
        #expect(launcher.startedRequests.first?.presetName == "claude")
        #expect(model.sessions.count == 1)
    }

    @Test("createWorktreeはフォームにhook指定が無ければconfigのpostCreationHookをフォールバックとして使う")
    func createWorktreeFallsBackToConfigPostCreationHook() async throws {
        let configStore = FakeConfigStore(config: VitermConfig.merge(
            global: VitermConfigFile(postCreationHook: "echo from-config"),
            project: nil
        ))
        let provisioner = FakeWorktreeProvisioner()
        let model = makeModel(configStore: configStore, provisioner: provisioner)
        await model.refresh()

        let request = NewWorktreeRequest(
            repository: repository, source: .newBranch(name: "feat", startPoint: nil),
            worktreePath: "/wt/feat", pathTemplate: WorktreePathTemplate("~/wt/{branch}")
        )
        _ = try await model.createWorktree(from: request)

        #expect(provisioner.receivedRequests.first?.postCreationHookCommand == "echo from-config")
    }

    @Test("createWorktreeはフォームにhook指定があればconfigのpostCreationHookより優先する")
    func createWorktreeFormHookTakesPriorityOverConfig() async throws {
        let configStore = FakeConfigStore(config: VitermConfig.merge(
            global: VitermConfigFile(postCreationHook: "echo from-config"),
            project: nil
        ))
        let provisioner = FakeWorktreeProvisioner()
        let model = makeModel(configStore: configStore, provisioner: provisioner)
        await model.refresh()

        let request = NewWorktreeRequest(
            repository: repository, source: .newBranch(name: "feat", startPoint: nil),
            worktreePath: "/wt/feat", pathTemplate: WorktreePathTemplate("~/wt/{branch}"),
            runHookCommand: "echo from-form"
        )
        _ = try await model.createWorktree(from: request)

        #expect(provisioner.receivedRequests.first?.postCreationHookCommand == "echo from-form")
    }

    // MARK: mergeAndCleanUp / removeWorktree

    @Test("mergeAndCleanUpはコーディネータを呼び、完了後にrefreshする")
    func mergeAndCleanUpDelegatesAndRefreshes() async {
        let merger = FakeMergeCleanupCoordinator()
        let scanner = FakeWorktreeStatusScanner()
        let model = makeModel(scanner: scanner, merger: merger)

        let request = MergeCleanupRequest(
            source: "feat", target: "main",
            sourceWorktree: URL(fileURLWithPath: "/wt/feat"),
            targetWorktree: URL(fileURLWithPath: "/wt/main")
        )
        let result = await model.mergeAndCleanUp(request)

        #expect(result.isFullySuccessful)
        #expect(merger.receivedRequests.count == 1)
        #expect(scanner.scannedRepositories.count == 1)
    }

    @Test("removeWorktreeはリムーバーを呼び、完了後にrefreshする")
    func removeWorktreeDelegatesAndRefreshes() async throws {
        let remover = FakeWorktreeRemover()
        let scanner = FakeWorktreeStatusScanner()
        let model = makeModel(scanner: scanner, remover: remover)

        try await model.removeWorktree(at: "/wt/feat", in: "/repo/viterm", force: true)

        #expect(remover.removedPaths.count == 1)
        #expect(remover.removedPaths.first?.force == true)
        #expect(scanner.scannedRepositories.count == 1)
    }

    @Test("removeWorktreeが失敗した場合はrefreshされない")
    func removeWorktreeFailurePropagatesAndSkipsRefresh() async {
        let remover = FakeWorktreeRemover()
        remover.shouldThrow = true
        let scanner = FakeWorktreeStatusScanner()
        let model = makeModel(scanner: scanner, remover: remover)

        await #expect(throws: StubError.self) {
            try await model.removeWorktree(at: "/wt/feat", in: "/repo/viterm")
        }
        #expect(scanner.scannedRepositories.isEmpty)
    }

    @Test("deleteBranchはリムーバーにブランチ名を渡し、完了後にrefreshする")
    func deleteBranchDelegatesAndRefreshes() async throws {
        let remover = FakeWorktreeRemover()
        let scanner = FakeWorktreeStatusScanner()
        let model = makeModel(scanner: scanner, remover: remover)

        try await model.deleteBranch("feat/x", in: "/repo/viterm")

        #expect(remover.deletedBranches.count == 1)
        #expect(remover.deletedBranches.first?.name == "feat/x")
        #expect(remover.deletedBranches.first?.force == false)
        #expect(scanner.scannedRepositories.count == 1)
    }

    @Test("deleteBranchが失敗した場合はrefreshされない")
    func deleteBranchFailurePropagatesAndSkipsRefresh() async {
        let remover = FakeWorktreeRemover()
        remover.branchDeletionShouldThrow = true
        let scanner = FakeWorktreeStatusScanner()
        let model = makeModel(scanner: scanner, remover: remover)

        await #expect(throws: StubError.self) {
            try await model.deleteBranch("feat/x", in: "/repo/viterm")
        }
        #expect(scanner.scannedRepositories.isEmpty)
    }

    // MARK: addRepository

    @Test("addRepositoryは永続化してからrefreshし、保存内容が反映される")
    func addRepositoryPersistsAndRefreshes() async throws {
        let configStore = FakeConfigStore()
        let model = makeModel(configStore: configStore)

        _ = try await model.addRepository(name: "viterm", path: "/repo/viterm")

        #expect(model.repositories == [Repository(name: "viterm", path: "/repo/viterm")])
        #expect(configStore.config.repositories == [Repository(name: "viterm", path: "/repo/viterm")])
    }

    @Test("addRepositoryは同じpathなら追加せず名前を上書きする")
    func addRepositoryUpdatesNameForExistingPath() async throws {
        let configStore = FakeConfigStore(config: VitermConfig.merge(
            global: VitermConfigFile(repositories: [Repository(name: "old-name", path: "/repo/viterm")]),
            project: nil
        ))
        let model = makeModel(configStore: configStore)

        _ = try await model.addRepository(name: "new-name", path: "/repo/viterm")

        #expect(model.repositories.count == 1)
        #expect(model.repositories.first?.name == "new-name")
    }

    // MARK: sessionStateChanged

    @Test("sessionStateChangedは状態と時刻を更新しhookを発火する")
    func sessionStateChangedUpdatesAndNotifies() async {
        let launcher = FakeSessionLauncher()
        let notifier = FakeStatusChangeNotifier()
        let model = makeModel(notifier: notifier, launcher: launcher)

        let session = try! await model.startSession(worktreePath: "/wt/feat", presetName: "claude")
        #expect(session.state == .idle)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        model.sessionStateChanged(sessionID: session.id, newState: .busy, at: now)

        let updated = model.sessions.first { $0.id == session.id }
        #expect(updated?.state == .busy)
        #expect(updated?.stateChangedAt == now)
        #expect(notifier.calls.count == 1)
        #expect(notifier.calls.first?.oldState == .idle)
        #expect(notifier.calls.first?.newState == .busy)
    }

    @Test("状態が変わらない場合はhookを発火しない")
    func sessionStateChangedNoOpWhenStateUnchanged() async throws {
        let notifier = FakeStatusChangeNotifier()
        let model = makeModel(notifier: notifier)
        let session = try await model.startSession(worktreePath: "/wt/feat", presetName: "claude")

        model.sessionStateChanged(sessionID: session.id, newState: .idle)

        #expect(notifier.calls.isEmpty)
    }

    @Test("存在しないsessionIDは無視される")
    func sessionStateChangedIgnoresUnknownSessionID() async {
        let notifier = FakeStatusChangeNotifier()
        let model = makeModel(notifier: notifier)
        model.sessionStateChanged(sessionID: UUID(), newState: .busy)
        #expect(notifier.calls.isEmpty)
    }

    // MARK: Selection delegation

    @Test("選択系メソッドはSidebarViewModelへ委譲される")
    func selectionMethodsDelegateToSidebar() async {
        let configStore = FakeConfigStore(config: VitermConfig.merge(
            global: VitermConfigFile(repositories: [repository]),
            project: nil
        ))
        let scanner = FakeWorktreeStatusScanner()
        let worktree = VitermCore.Worktree(path: "/repo/viterm", repositoryPath: repository.path, branch: "main")
        scanner.worktreesToReturn = [worktree]

        let model = makeModel(configStore: configStore, scanner: scanner)
        await model.refresh()
        _ = try! await model.startSession(worktreePath: worktree.path, presetName: "claude")
        _ = try! await model.startSession(worktreePath: worktree.path, presetName: "codex")

        model.selectNextSession()
        let first = model.sidebar.selectedSessionID
        #expect(first != nil)

        model.selectNextSession()
        #expect(model.sidebar.selectedSessionID != first)

        model.selectPreviousSession()
        #expect(model.sidebar.selectedSessionID == first)

        #expect(model.jumpToLatestWaitingSession() == false, "waitingInputのセッションが無いのでfalse")
    }

    @Test("worktree選択系メソッドはSidebarViewModelへ委譲される")
    func worktreeSelectionMethodsDelegateToSidebar() async {
        let configStore = FakeConfigStore(config: VitermConfig.merge(
            global: VitermConfigFile(repositories: [repository]),
            project: nil
        ))
        let scanner = FakeWorktreeStatusScanner()
        let main = VitermCore.Worktree(path: "/repo/viterm", repositoryPath: repository.path, branch: "main")
        let feature = VitermCore.Worktree(path: "/wt/viterm/feat", repositoryPath: repository.path, branch: "feat")
        scanner.worktreesToReturn = [main, feature]

        let model = makeModel(configStore: configStore, scanner: scanner)
        await model.refresh()

        model.selectWorktree(main.path)
        #expect(model.sidebar.selectedWorktreePath == main.path)

        model.selectNextWorktree()
        #expect(model.sidebar.selectedWorktreePath == feature.path)

        model.selectPreviousWorktree()
        #expect(model.sidebar.selectedWorktreePath == main.path)

        model.selectWorktree(nil)
        #expect(model.sidebar.selectedWorktreePath == nil)
    }

    // MARK: removeSession

    private func makeModelWithRegisteredWorktree(
        launcher: FakeSessionLauncher = FakeSessionLauncher()
    ) async -> (model: AppModel, worktree: VitermCore.Worktree) {
        let configStore = FakeConfigStore(config: VitermConfig.merge(
            global: VitermConfigFile(repositories: [repository]),
            project: nil
        ))
        let scanner = FakeWorktreeStatusScanner()
        let worktree = VitermCore.Worktree(path: repository.path, repositoryPath: repository.path, branch: "main")
        scanner.worktreesToReturn = [worktree]

        let model = makeModel(configStore: configStore, scanner: scanner, launcher: launcher)
        await model.refresh()
        return (model, worktree)
    }

    @Test("removeSessionでアクティブタブを閉じると同じworktreeの別タブへ自動的に切り替わる")
    func removeSessionReselectsAnotherTabInSameWorktree() async throws {
        let (model, worktree) = await makeModelWithRegisteredWorktree()

        let first = try await model.startSession(worktreePath: worktree.path, presetName: "claude")
        let second = try await model.startSession(worktreePath: worktree.path, presetName: "codex")
        model.selectSession(first.id)

        model.removeSession(first.id)

        #expect(model.sidebar.selectedWorktreePath == worktree.path, "worktreeの選択は維持される")
        #expect(model.sidebar.selectedSessionID == second.id, "残った別タブに自動的に切り替わる")
    }

    @Test("removeSessionで非選択タブを閉じても現在の選択には影響しない")
    func removeSessionOfNonActiveTabDoesNotChangeSelection() async throws {
        let (model, worktree) = await makeModelWithRegisteredWorktree()

        let first = try await model.startSession(worktreePath: worktree.path, presetName: "claude")
        let second = try await model.startSession(worktreePath: worktree.path, presetName: "codex")
        model.selectSession(first.id)

        model.removeSession(second.id)

        #expect(model.sidebar.selectedSessionID == first.id)
    }

    @Test("removeSessionでworktree内最後のタブを閉じるとセッション選択は解除される")
    func removeSessionClearsSelectionWhenWorktreeBecomesEmpty() async throws {
        let (model, worktree) = await makeModelWithRegisteredWorktree()

        let only = try await model.startSession(worktreePath: worktree.path, presetName: "claude")
        model.selectSession(only.id)

        model.removeSession(only.id)

        #expect(model.sidebar.selectedWorktreePath == worktree.path, "worktreeの選択自体は維持される")
        #expect(model.sidebar.selectedSessionID == nil)
    }

    // MARK: moveSession

    @Test("moveSessionは他worktreeのflat-array位置を変えずに並べ替える")
    func moveSessionPreservesInterleavedWorktreePositions() async throws {
        let model = makeModel()
        let a1 = try await model.startSession(worktreePath: "/wt/a", presetName: "a1")
        let b1 = try await model.startSession(worktreePath: "/wt/b", presetName: "b1")
        let a2 = try await model.startSession(worktreePath: "/wt/a", presetName: "a2")
        let b2 = try await model.startSession(worktreePath: "/wt/b", presetName: "b2")
        let a3 = try await model.startSession(worktreePath: "/wt/a", presetName: "a3")

        model.moveSession(a3.id, toTabIndex: 0)

        #expect(model.sessions.map(\.id) == [a3.id, b1.id, a1.id, b2.id, a2.id])
    }

    @Test("moveSessionは先頭末尾間の移動とdestinationのclampを行う")
    func moveSessionMovesAcrossBoundsAndClamps() async throws {
        let model = makeModel()
        let first = try await model.startSession(worktreePath: "/wt/a", presetName: "first")
        let middle = try await model.startSession(worktreePath: "/wt/a", presetName: "middle")
        let last = try await model.startSession(worktreePath: "/wt/a", presetName: "last")

        model.moveSession(first.id, toTabIndex: .max)
        #expect(model.sessions.map(\.id) == [middle.id, last.id, first.id])

        model.moveSession(first.id, toTabIndex: 0)
        #expect(model.sessions.map(\.id) == [first.id, middle.id, last.id])

        model.moveSession(last.id, toTabIndex: -100)
        #expect(model.sessions.map(\.id) == [last.id, first.id, middle.id])
    }

    @Test("moveSessionは不明IDと同順序になる移動では変更しない")
    func moveSessionUnknownAndNoOp() async throws {
        let model = makeModel()
        let first = try await model.startSession(worktreePath: "/wt/a", presetName: "first")
        let second = try await model.startSession(worktreePath: "/wt/a", presetName: "second")
        let original = model.sessions

        model.moveSession(UUID(), toTabIndex: 0)
        #expect(model.sessions == original)

        model.moveSession(first.id, toTabIndex: 0)
        #expect(model.sessions == original)
        #expect(model.sessions.map(\.id) == [first.id, second.id])
    }

    @Test("moveSession後も選択を維持しショートカット番号を新順序に振る")
    func moveSessionPreservesSelectionAndRenumbersShortcuts() async throws {
        let (model, worktree) = await makeModelWithRegisteredWorktree()
        let first = try await model.startSession(worktreePath: worktree.path, presetName: "first")
        let second = try await model.startSession(worktreePath: worktree.path, presetName: "second")
        let third = try await model.startSession(worktreePath: worktree.path, presetName: "third")
        model.selectSession(second.id)

        model.moveSession(third.id, toTabIndex: 0)

        #expect(model.sidebar.selectedSessionID == second.id)
        let tabs = TabBarViewModel(
            sessions: model.sidebar.selectedWorktree?.sessions.map(\.session) ?? []
        ).tabs
        #expect(tabs.map(\.id) == [third.id, first.id, second.id])
        #expect(tabs.map(\.shortcutNumber) == [1, 2, 3])
    }

    // MARK: sidebar display mode

    @Test("setSidebarDisplayModeはモードを切り替えて永続化する")
    func setSidebarDisplayModePersists() {
        let persister = FakeSidebarPreferencePersister()
        let model = makeModel(sidebarPersister: persister)

        model.setSidebarDisplayMode(.state)

        #expect(model.sidebar.displayMode == .state)
        #expect(persister.persistedModes == [.state])
    }

    @Test("永続化に失敗してもメモリ上の切替は維持されエラーが記録される")
    func setSidebarDisplayModeKeepsSwitchOnPersistFailure() {
        let persister = FakeSidebarPreferencePersister()
        persister.errorToThrow = NSError(domain: "test", code: 1)
        let model = makeModel(sidebarPersister: persister)

        model.setSidebarDisplayMode(.state)

        #expect(model.sidebar.displayMode == .state)
        #expect(model.lastRefreshErrors.count == 1)
    }

    @Test("初回refreshは設定のsidebarDisplayModeをシードし、以後のrefreshは上書きしない")
    func refreshSeedsDisplayModeOnceFromConfig() async {
        let configStore = FakeConfigStore(config: VitermConfig.merge(
            global: VitermConfigFile(sidebarDisplayMode: "state"),
            project: nil
        ))
        let model = makeModel(configStore: configStore)

        await model.refresh()
        #expect(model.sidebar.displayMode == .state)

        // An in-session toggle must survive later refreshes even though the (stale)
        // config still says "state".
        model.setSidebarDisplayMode(.tree)
        await model.refresh()
        #expect(model.sidebar.displayMode == .tree)
    }

    @Test("rebuildSidebarはフィルタとdisplayModeを引き継ぐ")
    func rebuildCarriesFilterAndDisplayMode() async {
        let configStore = FakeConfigStore(config: VitermConfig.merge(
            global: VitermConfigFile(repositories: [repository]),
            project: nil
        ))
        let model = makeModel(configStore: configStore)
        await model.refresh()

        model.setSidebarFilter("vit")
        model.setSidebarDisplayMode(.state)
        await model.refresh() // rebuildSidebar() runs inside

        #expect(model.sidebar.filterText == "vit")
        #expect(model.sidebar.displayMode == .state)
    }
}
