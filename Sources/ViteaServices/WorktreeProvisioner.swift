import Foundation
import GitKit
import ViteaCore

/// 新規 worktree 作成のリクエスト。
public struct WorktreeCreationRequest: Sendable {
    public var repository: ViteaCore.Repository
    /// 新規ブランチ / 既存ローカルブランチ / リモートブランチの3パターン(GitKit.WorktreeSource)。
    public var source: WorktreeSource
    public var pathTemplate: WorktreePathTemplate
    /// Claude セッションデータ(`~/.claude/projects/…`)をコピーするかどうか。
    public var copySessionData: Bool
    /// コピー元のプロジェクトパス。省略時は `repository.path`(リポジトリルート)を使う。
    public var copySessionDataFrom: String?
    /// 作成後に実行する post-creation hook のシェルコマンド。nil/空文字なら実行しない。
    public var postCreationHookCommand: String?

    public init(
        repository: ViteaCore.Repository,
        source: WorktreeSource,
        pathTemplate: WorktreePathTemplate,
        copySessionData: Bool = false,
        copySessionDataFrom: String? = nil,
        postCreationHookCommand: String? = nil
    ) {
        self.repository = repository
        self.source = source
        self.pathTemplate = pathTemplate
        self.copySessionData = copySessionData
        self.copySessionDataFrom = copySessionDataFrom
        self.postCreationHookCommand = postCreationHookCommand
    }
}

/// `createWorktree` の結果。
public struct WorktreeCreationResult: Sendable {
    public var worktreePath: String
    public var branch: String
    /// worktree 作成自体は成功したが非致命的に失敗した処理(セッションデータコピー等)の警告。
    public var warnings: [String]
    /// post-creation hook を起動した場合の Task。呼び出し側は待つ必要はない(非同期・非ブロッキング実行)が、
    /// テストでは `await hookTask?.value` で完了を待てる。
    public var hookTask: Task<Void, Never>?

    public init(worktreePath: String, branch: String, warnings: [String] = [], hookTask: Task<Void, Never>? = nil) {
        self.worktreePath = worktreePath
        self.branch = branch
        self.warnings = warnings
        self.hookTask = hookTask
    }
}

extension WorktreeSource {
    /// 作成される worktree でチェックアウトされることになるローカルブランチ名(生の形、`/` を含みうる)。
    /// パステンプレートの `{branch}` / `{branch_raw}` 展開に使う。
    public var localBranchName: String {
        switch self {
        case let .newBranch(name, _):
            return name
        case let .existingLocalBranch(name):
            return name
        case let .remoteBranch(_, name, newLocalName):
            return newLocalName ?? name
        }
    }
}

/// worktree 作成のオーケストレーション: パステンプレート展開 → `GitService.addWorktree` →
/// Claude セッションデータコピー(オプション・非致命的) → post-creation hook 実行(オプション・非同期)。
public struct WorktreeProvisioner: Sendable {
    public var gitService: GitService
    /// `~` 展開に使うホームディレクトリ。テスト用に注入可能。
    public var homeDirectory: String
    /// Claude セッションデータのルート(既定 `<home>/.claude/projects`)。テスト用に注入可能。
    public var claudeProjectsDirectory: String
    public var fileExists: @Sendable (URL) -> Bool
    public var fileCopier: @Sendable (_ source: URL, _ destination: URL) throws -> Void
    /// post-creation hook の実行本体。テストでは実プロセスを起動しない差し替えが可能。
    public var hookRunner: @Sendable (_ command: String, _ environment: [String: String]) async -> Void

    public init(
        gitService: GitService = GitService(),
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        claudeProjectsDirectory: String? = nil,
        fileExists: @escaping @Sendable (URL) -> Bool = WorktreeProvisioner.defaultFileExists,
        fileCopier: @escaping @Sendable (URL, URL) throws -> Void = WorktreeProvisioner.defaultFileCopier,
        hookRunner: @escaping @Sendable (String, [String: String]) async -> Void = WorktreeProvisioner.defaultHookRunner
    ) {
        self.gitService = gitService
        self.homeDirectory = homeDirectory
        self.claudeProjectsDirectory = claudeProjectsDirectory ?? homeDirectory + "/.claude/projects"
        self.fileExists = fileExists
        self.fileCopier = fileCopier
        self.hookRunner = hookRunner
    }

    public func createWorktree(_ request: WorktreeCreationRequest) async throws -> WorktreeCreationResult {
        let branch = request.source.localBranchName
        let context = WorktreePathTemplate.Context(
            projectName: request.repository.name,
            branch: branch,
            repositoryRoot: request.repository.path
        )
        let expandedPath = request.pathTemplate.expand(context: context, homeDirectory: homeDirectory)
        let worktreeURL = URL(fileURLWithPath: expandedPath)
        let repositoryURL = URL(fileURLWithPath: request.repository.path)

        try await gitService.addWorktree(in: repositoryURL, path: worktreeURL, source: request.source)

        var warnings: [String] = []

        if request.copySessionData {
            let sourcePath = request.copySessionDataFrom ?? request.repository.path
            do {
                try copyClaudeSessionData(from: sourcePath, to: expandedPath)
            } catch {
                warnings.append("Claude セッションデータのコピーに失敗しました: \(error)")
            }
        }

        var hookTask: Task<Void, Never>?
        if let command = request.postCreationHookCommand, !command.isEmpty {
            let environment: [String: String] = [
                "VITEA_WORKTREE_PATH": expandedPath,
                "VITEA_BRANCH": branch,
                "VITEA_GIT_ROOT": request.repository.path,
            ]
            let runHook = hookRunner
            hookTask = Task {
                await runHook(command, environment)
            }
        }

        return WorktreeCreationResult(worktreePath: expandedPath, branch: branch, warnings: warnings, hookTask: hookTask)
    }

    /// `~/.claude/projects/<エンコード済みパス>` を新しい worktree 用にコピーする。
    /// コピー元が存在しない(その projectパスでの Claude Code 利用履歴がまだ無い)場合は何もしない
    /// (これは失敗ではなく普通にありうるケースのため、警告にはしない)。
    private func copyClaudeSessionData(from sourcePath: String, to destinationPath: String) throws {
        let root = URL(fileURLWithPath: claudeProjectsDirectory)
        let source = root.appendingPathComponent(Self.encodeProjectPath(sourcePath))
        guard fileExists(source) else { return }
        let destination = root.appendingPathComponent(Self.encodeProjectPath(destinationPath))
        try fileCopier(source, destination)
    }

    /// Claude Code のプロジェクトディレクトリ命名規則: 絶対パスの `/` を `-` に置き換える。
    /// 例: `/Users/foo/repo` → `-Users-foo-repo`
    static func encodeProjectPath(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
    }

    public static let defaultFileExists: @Sendable (URL) -> Bool = { url in
        FileManager.default.fileExists(atPath: url.path)
    }

    public static let defaultFileCopier: @Sendable (URL, URL) throws -> Void = { source, destination in
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: destination)
    }

    /// `/bin/sh -c <command>` で hook を起動し、指定 env を追加する。ゾンビプロセス化を避けるため
    /// 終了は監視するが、呼び出し側(`createWorktree`)はこの Task 自体を待たないため実行は非ブロッキング。
    public static let defaultHookRunner: @Sendable (String, [String: String]) async -> Void = { command, environment in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]

        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            env[key] = value
        }
        process.environment = env

        do {
            try process.run()
        } catch {
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }
    }
}
