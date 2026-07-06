import Foundation

/// Snapshot of the state of one git worktree.
public struct Worktree: Codable, Sendable, Hashable, Identifiable {
    /// Absolute path of the worktree.
    public var path: String
    /// Reference to the associated `Repository.id` (= absolute path of the repository root).
    public var repositoryPath: String
    /// Name of the checked-out branch.
    public var branch: String
    /// Number of commits ahead of the parent branch.
    public var ahead: Int
    /// Number of commits behind the parent branch.
    public var behind: Int
    /// Whether there are staged changes (the X column of `git status --porcelain`).
    public var hasStagedChanges: Bool
    /// Whether there are unstaged changes, including untracked (the Y column / `??` of the same).
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

    /// Whether there are uncommitted changes (either staged or unstaged).
    public var isDirty: Bool { hasStagedChanges || hasUnstagedChanges }
}
