import Foundation
import GitKit
import Observation
import ViteaCore

/// `PaletteAction` をディスパッチした結果、UI 側が次に何をすべきか。
/// 追加入力(ダイアログでの選択)が必要な操作は実行せず、UI が続く入力を集めてから
/// `AppModel` の対応するメソッド(`createWorktree` 等)を直接呼ぶ想定。
public enum PaletteDispatchOutcome: Sendable, Equatable {
    /// worktree 新規作成ダイアログを開く。
    case openCreateWorktreeDialog
    /// リポジトリ追加ダイアログ(ディレクトリ選択)を開く。
    case openAddRepositoryDialog
    /// マージ方式(merge/rebase)選択ダイアログを開く。
    case confirmMergeWorktree(worktreeID: String)
    /// 削除確認ダイアログを開く。
    case confirmRemoveWorktree(worktreeID: String)
    /// その場で実行され、完了した(switchToWorktree / startSession)。
    case completed
    /// その場で実行しようとしたが失敗した。
    case failed(String)
}

/// UI(ViteaApp)が直接バインドするアプリ状態のオーケストレーション層。
///
/// 設定ロード → 登録リポジトリ + 自動検出の統合 → worktree 状態スキャン → セッション一覧、から
/// `SidebarViewModel` を構築して公開する。git 操作・ファイルI/O・セッション起動は一切自前で行わず、
/// すべて注入された抽象(`AppModelDependencies.swift` 参照)経由で行うため、フェイクで
/// 決定的にユニットテストできる。
///
/// AppKit から直接バインドされる想定のため `@MainActor` で隔離する。`@Observable` を付与しているが、
/// これは SwiftUI 専用ではなく `Observation` フレームワーク由来で、AppKit 側は
/// `withObservationTracking` で手動購読するか、単に都度プロパティを読む形でも使える。
@MainActor
@Observable
public final class AppModel {
    // MARK: 公開状態

    public private(set) var config: ViteaConfig
    public private(set) var repositories: [Repository]
    public private(set) var worktrees: [ViteaCore.Worktree]
    public private(set) var sessions: [AgentSession]
    public private(set) var sidebar: SidebarViewModel
    /// 現在ターミナルペインに表示中の worktree(= `dispatch` の `startSession`/`switchToWorktree` の対象)。
    public private(set) var currentWorktreeID: String?
    /// 直近の `refresh()` で発生した(致命的でない)エラーメッセージ。UI のトースト表示等に使う。
    public private(set) var lastRefreshErrors: [String]

    // MARK: 注入された依存

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

    // MARK: - リフレッシュ

    /// 設定 → 登録リポジトリ+自動検出 → worktree スキャン、の順に再取得して状態を更新する。
    /// 設定の読み込みに失敗した場合は直前の設定を維持したまま `lastRefreshErrors` に記録し、続行する
    /// (worktree スキャン自体のリポジトリ単位の失敗隔離は `WorktreeStatusScanning` 実装側の責務)。
    public func refresh() async {
        var errors: [String] = []

        let loadedConfig: ViteaConfig
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

    /// `discoveryRoots` の1エントリ(`~` を含みうる文字列)を実際のディレクトリ URL に展開する。
    static func expandDiscoveryRoot(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// 登録済みリポジトリ(`path` で同定)を優先し、自動検出のみで見つかったものを末尾に追加する。
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

    // MARK: - PaletteAction ディスパッチ

    /// `PaletteAction` を処理する。追加入力が要る操作(作成・追加・マージ・削除)はダイアログを
    /// 開くべきことを示す outcome を返すだけで、実行は行わない。即座に実行できる操作
    /// (切替・起動)はここで実行して結果を返す。
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

    // MARK: - worktree 作成

    /// `NewWorktreeFormModel.buildRequest()` の結果を実際の作成に変換して実行する。
    /// `ViteaCore.NewWorktreeSource` → `GitKit.WorktreeSource` の1:1変換をここで行う
    /// (ViteaCore は GitKit に依存できないため、変換は依存できるこの層の責務)。
    /// 成功後は `refresh()` で状態を最新化し、`launchSessionPresetName` があればセッションも起動する。
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

        // フォームで hook が明示的に指定されていなければ、設定の既定 post-creation hook を使う。
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

    // MARK: - マージ・削除

    /// merge/rebase + worktree・ブランチ後始末を実行し、完了後に `refresh()` する。
    @discardableResult
    public func mergeAndCleanUp(_ request: MergeCleanupRequest) async -> MergeCleanupResult {
        let result = await mergeCleanupCoordinator.mergeAndCleanUp(request)
        await refresh()
        return result
    }

    /// マージを伴わない worktree 単独削除。完了後に `refresh()` する。
    public func removeWorktree(at path: String, in repositoryPath: String, force: Bool = false) async throws {
        try await worktreeRemover.removeWorktree(
            at: URL(fileURLWithPath: path),
            in: URL(fileURLWithPath: repositoryPath),
            force: force
        )
        await refresh()
    }

    // MARK: - リポジトリ登録

    /// リポジトリを登録し、グローバル設定に永続化してから `refresh()` する。
    /// 既に同じ `path` が登録済みなら名前を上書きするだけ(重複登録はしない)。
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

    // MARK: - セッション(T6 の SessionManager 統合までの暫定窓口)

    /// `SessionLaunching` 経由でセッションを起動し、一覧に追加する。
    @discardableResult
    public func startSession(worktreePath: String, presetName: String) async throws -> AgentSession {
        let session = try await sessionLauncher.startSession(worktreePath: worktreePath, presetName: presetName)
        sessions.append(session)
        rebuildSidebar()
        return session
    }

    /// 表示中の worktree を切り替える。
    public func switchToWorktree(_ worktreePath: String) async {
        currentWorktreeID = worktreePath
        await sessionLauncher.switchToWorktree(worktreePath)
    }

    /// セッションの表示名を変更する。
    public func renameSession(_ sessionID: AgentSession.ID, to newName: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              !newName.isEmpty else { return }
        sessions[index].displayName = newName
        rebuildSidebar()
    }

    /// セッションを一覧から取り除く(PTY/サーフェスの破棄は呼び出し側 = SessionManager の責務)。
    public func removeSession(_ sessionID: AgentSession.ID) {
        sessions.removeAll { $0.id == sessionID }
        if sidebar.selectedSessionID == sessionID {
            sidebar.select(sessionID: nil)
        }
        rebuildSidebar()
    }

    /// セッション状態変化の受け口。`SessionStateMachine` 等が確定させた新状態を渡す。
    /// 状態が実際に変わっていれば `AgentSession` を更新し、`StatusChangeHookRunner` を発火する。
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

    // MARK: - サイドバー選択(SidebarViewModel への薄い委譲)

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
