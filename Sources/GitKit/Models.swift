import Foundation

/// One entry of `git worktree list --porcelain`.
public struct Worktree: Sendable, Equatable {
    public let path: URL
    /// Name of the checked-out branch (short form, e.g. `main`, `feature/x`). `nil` for a detached HEAD.
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

/// Branch info obtained from `for-each-ref`.
public struct Branch: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case local
        case remote
    }

    /// For local: the short branch name (e.g. `main`); for remote: `<remote>/<branch>` form (e.g. `origin/main`).
    public let name: String
    public let kind: Kind

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }
}

/// Result of `git rev-list --left-right --count <upstream>...<branch>`.
public struct AheadBehind: Sendable, Equatable {
    /// Number of commits on branch but not on upstream.
    public let ahead: Int
    /// Number of commits on upstream but not on branch.
    public let behind: Int

    public init(ahead: Int, behind: Int) {
        self.ahead = ahead
        self.behind = behind
    }
}

/// Result of `git diff --shortstat` plus the working tree's dirty flag.
public struct DiffStat: Sendable, Equatable {
    public let filesChanged: Int
    public let insertions: Int
    public let deletions: Int
    /// Whether `git status --porcelain` is non-empty (including untracked files).
    public let isDirty: Bool

    public init(filesChanged: Int, insertions: Int, deletions: Int, isDirty: Bool) {
        self.filesChanged = filesChanged
        self.insertions = insertions
        self.deletions = deletions
        self.isDirty = isDirty
    }
}

/// Presence of staged / unstaged changes in the working tree (summary of the XY columns of `git status --porcelain`).
public struct WorkingState: Sendable, Equatable {
    public let hasStagedChanges: Bool
    public let hasUnstagedChanges: Bool

    public init(hasStagedChanges: Bool, hasUnstagedChanges: Bool) {
        self.hasStagedChanges = hasStagedChanges
        self.hasUnstagedChanges = hasUnstagedChanges
    }
}

/// Source patterns for `addWorktree`.
public enum WorktreeSource: Sendable, Equatable {
    /// Create a new branch and add a worktree (`git worktree add -b <name> <path> [<startPoint>]`).
    /// Omitting `startPoint` branches from the current HEAD.
    case newBranch(name: String, startPoint: String? = nil)
    /// Check out an existing local branch (`git worktree add <path> <name>`).
    case existingLocalBranch(name: String)
    /// Create a new local branch tracking a remote branch and add a worktree
    /// (`git worktree add --track -b <local> <path> <remote>/<name>`).
    /// Omitting `newLocalName` gives the local branch the same name as the remote one.
    case remoteBranch(remote: String, name: String, newLocalName: String? = nil)
}

/// Merge strategy between worktrees.
public enum MergeStrategy: Sendable, Equatable {
    /// Run `git merge <arguments> <source>` in the target worktree. Defaults to `--no-ff`.
    case merge(arguments: [String] = ["--no-ff"])
    /// Run `git rebase <target>` in the source worktree, then
    /// `git merge --ff-only <source>` in the target worktree.
    case rebase
}

/// GitService operation-specific errors (not plain git command failures).
public enum GitServiceError: Error, CustomStringConvertible, Sendable, Equatable {
    /// `removeWorktree(force: false)` found uncommitted changes in the worktree.
    case worktreeDirty(path: URL)
    /// git output could not be parsed in the expected format.
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
