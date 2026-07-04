import Foundation

/// `git worktree list --porcelain` の1エントリ。
public struct Worktree: Sendable, Equatable {
    public let path: URL
    /// チェックアウト中のブランチ名(短縮形。例: `main`, `feature/x`)。detached HEAD の場合は `nil`。
    public let branch: String?
    public let head: String
    public let isBare: Bool
    public let isDetached: Bool
    public let isLocked: Bool
    public let isPrunable: Bool

    public init(
        path: URL,
        branch: String?,
        head: String,
        isBare: Bool = false,
        isDetached: Bool = false,
        isLocked: Bool = false,
        isPrunable: Bool = false
    ) {
        self.path = path
        self.branch = branch
        self.head = head
        self.isBare = isBare
        self.isDetached = isDetached
        self.isLocked = isLocked
        self.isPrunable = isPrunable
    }
}

/// `for-each-ref` から得たブランチ情報。
public struct Branch: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case local
        case remote
    }

    /// local は短縮ブランチ名(例: `main`)、remote は `<remote>/<branch>` 形式(例: `origin/main`)。
    public let name: String
    public let kind: Kind

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }
}

/// `git rev-list --left-right --count <upstream>...<branch>` の結果。
public struct AheadBehind: Sendable, Equatable {
    /// branch にあって upstream にないコミット数。
    public let ahead: Int
    /// upstream にあって branch にないコミット数。
    public let behind: Int

    public init(ahead: Int, behind: Int) {
        self.ahead = ahead
        self.behind = behind
    }
}

/// `git diff --shortstat` の結果 + 作業ツリーの dirty 判定。
public struct DiffStat: Sendable, Equatable {
    public let filesChanged: Int
    public let insertions: Int
    public let deletions: Int
    /// `git status --porcelain` が非空(未追跡ファイル含む)かどうか。
    public let isDirty: Bool

    public init(filesChanged: Int, insertions: Int, deletions: Int, isDirty: Bool) {
        self.filesChanged = filesChanged
        self.insertions = insertions
        self.deletions = deletions
        self.isDirty = isDirty
    }
}

/// `addWorktree` の作成元パターン。
public enum WorktreeSource: Sendable, Equatable {
    /// 新規ブランチを作成して worktree を追加する(`git worktree add -b <name> <path> [<startPoint>]`)。
    /// `startPoint` を省略すると現在の HEAD から分岐する。
    case newBranch(name: String, startPoint: String? = nil)
    /// 既存のローカルブランチをチェックアウトする(`git worktree add <path> <name>`)。
    case existingLocalBranch(name: String)
    /// リモートブランチを追跡する新規ローカルブランチを作って worktree を追加する
    /// (`git worktree add --track -b <local> <path> <remote>/<name>`)。
    /// `newLocalName` を省略するとリモートと同名のローカルブランチになる。
    case remoteBranch(remote: String, name: String, newLocalName: String? = nil)
}

/// worktree 間のマージ方式。
public enum MergeStrategy: Sendable, Equatable {
    /// `git merge <arguments> <source>` を target の worktree で実行する。既定は `--no-ff`。
    case merge(arguments: [String] = ["--no-ff"])
    /// source の worktree で `git rebase <target>` した後、target の worktree で
    /// `git merge --ff-only <source>` を実行する。
    case rebase
}

/// GitService の操作固有(git コマンドの単純失敗ではない)エラー。
public enum GitServiceError: Error, CustomStringConvertible, Sendable, Equatable {
    /// `removeWorktree(force: false)` で worktree に未コミットの変更があった場合。
    case worktreeDirty(path: URL)
    /// git の出力が期待した形式でパースできなかった場合。
    case unexpectedOutput(command: String, output: String)

    public var description: String {
        switch self {
        case let .worktreeDirty(path):
            return "worktree at \(path.path) has uncommitted changes; pass force: true to remove anyway"
        case let .unexpectedOutput(command, output):
            return "unexpected output from `git \(command)`: \(output)"
        }
    }
}
