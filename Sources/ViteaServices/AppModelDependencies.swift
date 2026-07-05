import Foundation
import GitKit
import ViteaCore

// MARK: - AppModel が使う外部作用の抽象。
//
// `AppModel` 自体はこれらのプロトコル越しにしか副作用(git 実行・ファイルI/O・設定読み書き)を
// 起こさない。各プロトコルは既存の具象型(WorktreeStatusScanner 等)のメソッドと1:1で対応しており、
// 具象型は下部の extension で無変更のまま準拠する。テストでは同じプロトコルに準拠したフェイクを注入する。

/// 設定読み込みの抽象(`ConfigLoader.load` のラッパー)。
public protocol ConfigProviding: Sendable {
    func loadConfig(repositoryRoot: URL?) throws -> ViteaConfig
}

/// グローバル設定への登録リポジトリ一覧の永続化の抽象。
public protocol RepositoryConfigPersisting: Sendable {
    func persist(repositories: [Repository]) throws
}

/// 指定ルート配下の git リポジトリ自動検出の抽象(`RepositoryDiscovery` のラッパー)。
public protocol RepositoryDiscovering: Sendable {
    func discover(rootDirectory: URL) -> [Repository]
}

/// 登録リポジトリ群の worktree 状態収集の抽象(`WorktreeStatusScanner` のラッパー)。
public protocol WorktreeStatusScanning: Sendable {
    func scan(repositories: [Repository]) async -> [ViteaCore.Worktree]
}

/// worktree 作成の抽象(`WorktreeProvisioner` のラッパー)。
public protocol WorktreeProvisioning: Sendable {
    func createWorktree(_ request: WorktreeCreationRequest) async throws -> WorktreeCreationResult
}

/// worktree 単独削除の抽象(マージを伴わない `git worktree remove`。`GitService` のラッパー)。
public protocol WorktreeRemoving: Sendable {
    func removeWorktree(at path: URL, in repository: URL, force: Bool) async throws
}

/// merge/rebase + 後始末の抽象(`MergeCleanupCoordinator` のラッパー)。
public protocol MergeCleaningUp: Sendable {
    func mergeAndCleanUp(_ request: MergeCleanupRequest) async -> MergeCleanupResult
}

/// セッション状態変化 hook 発火の抽象(`StatusChangeHookRunner` のラッパー)。
public protocol StatusChangeNotifying: Sendable {
    @discardableResult
    func notify(
        sessionName: String,
        worktreePath: String,
        oldState: AgentSession.State?,
        newState: AgentSession.State
    ) -> Task<Void, Never>?

    /// 設定リロード(`AppModel.refresh()`)ごとに hook コマンド設定を最新化する。
    mutating func updateConfig(_ config: StatusChangeHookConfig)
}

/// セッションの起動・切替の抽象。T6 で実装される `SessionManager` がこれに準拠する想定
/// (今回はプロトコル定義とテスト用フェイクのみ)。
public protocol SessionLaunching: Sendable {
    /// 指定 worktree でプリセットを起動し、生成された `AgentSession` を返す。
    func startSession(worktreePath: String, presetName: String) async throws -> AgentSession
    /// 表示中の worktree を切り替える(実際のサーフェス切替は UI 側の責務、ここでは通知のみ)。
    func switchToWorktree(_ worktreePath: String) async
}

// MARK: - 既存の具象型をそのままプロトコルに準拠させる(シグネチャは完全一致)。

extension RepositoryDiscovery: RepositoryDiscovering {}
extension WorktreeStatusScanner: WorktreeStatusScanning {}
extension WorktreeProvisioner: WorktreeProvisioning {}
extension MergeCleanupCoordinator: MergeCleaningUp {}
extension StatusChangeHookRunner: StatusChangeNotifying {}
extension GitService: WorktreeRemoving {}

// MARK: - Live 実装

/// `ConfigLoader.load` をそのまま呼ぶ既定実装。
public struct LiveConfigProvider: ConfigProviding {
    public var globalURL: URL?

    public init(globalURL: URL? = nil) {
        self.globalURL = globalURL
    }

    public func loadConfig(repositoryRoot: URL?) throws -> ViteaConfig {
        try ConfigLoader.load(globalURL: globalURL, repositoryRoot: repositoryRoot)
    }
}

/// グローバル設定ファイル(`~/.config/viterm/config.json`)の `repositories` フィールドだけを
/// 読み込み直して上書きする既定実装。他のフィールド(テンプレート・プリセット等)は保持する。
public struct LiveRepositoryConfigPersister: RepositoryConfigPersisting {
    public var globalConfigURL: URL

    public init(globalConfigURL: URL = ConfigLoader.defaultGlobalConfigURL()) {
        self.globalConfigURL = globalConfigURL
    }

    public func persist(repositories: [Repository]) throws {
        try FileManager.default.createDirectory(
            at: globalConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var file = (try? ConfigLoader.loadFile(at: globalConfigURL)) ?? ViteaConfigFile()
        file.repositories = repositories

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: globalConfigURL, options: .atomic)
    }
}
