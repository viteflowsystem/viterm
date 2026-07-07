import Foundation

/// Status snapshot of one git worktree.
public struct Worktree: Codable, Sendable, Hashable, Identifiable {
    /// Absolute path of the worktree.
    public var path: String
    /// Reference to the associated `Repository.id` (= the repository root's absolute path).
    public var repositoryPath: String
    /// Name of the checked-out branch.
    public var branch: String
    /// Commits ahead of the parent branch.
    public var ahead: Int
    /// Commits behind the parent branch.
    public var behind: Int
    /// Whether there are staged changes (the X column of `git status --porcelain`).
    public var hasStagedChanges: Bool
    /// Whether there are unstaged changes, including untracked (its Y column / `??`).
    public var hasUnstagedChanges: Bool

    public init(
        path: String,
        repositoryPath: String,
        branch: String,
        ahead: Int = 0,
        behind: Int = 0,
        hasStagedChanges: Bool = false,
        hasUnstagedChanges: Bool = false
    ) {
        self.path = path
        self.repositoryPath = repositoryPath
        self.branch = branch
        self.ahead = ahead
        self.behind = behind
        self.hasStagedChanges = hasStagedChanges
        self.hasUnstagedChanges = hasUnstagedChanges
    }

    public var id: String { path }

    /// Whether there are uncommitted changes (staged or unstaged).
    public var isDirty: Bool { hasStagedChanges || hasUnstagedChanges }
}
