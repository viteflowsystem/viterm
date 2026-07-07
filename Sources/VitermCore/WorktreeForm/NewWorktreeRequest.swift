import Foundation

/// The three worktree source patterns. Same shape as `GitKit.WorktreeSource`, but defined
/// independently here because `VitermCore` does not depend on GitKit (callers are
/// expected to convert 1:1 into `GitKit.WorktreeSource`).
public enum NewWorktreeSource: Sendable, Equatable {
    /// Create a new branch and add a worktree. Omitting `startPoint` branches from the current HEAD.
    case newBranch(name: String, startPoint: String?)
    /// Check out an existing local branch as-is.
    case existingLocalBranch(name: String)
    /// Create a new local branch tracking a remote branch and add a worktree.
    /// Omitting `newLocalName` gives the local branch the same name as the remote one.
    case remoteBranch(remote: String, name: String, newLocalName: String?)
}

/// The full set of values needed to create a worktree, returned by
/// `NewWorktreeFormModel.buildRequest()` once validation passes. Intended to be converted
/// into `VitermServices.WorktreeCreationRequest` and handed to `WorktreeProvisioner`, but
/// this type itself does not depend on VitermServices.
public struct NewWorktreeRequest: Sendable, Equatable {
    public var repository: Repository
    public var source: NewWorktreeSource
    /// The actual destination path, template already expanded.
    public var worktreePath: String
    /// The path template used for expansion (the in-place override if any, else the default).
    public var pathTemplate: WorktreePathTemplate
    public var copySessionData: Bool
    /// Session preset name to launch after creation. `nil` launches no session afterwards.
    public var launchSessionPresetName: String?
    /// Shell command run as the post-creation hook. Not run if `nil`/empty.
    public var runHookCommand: String?

    public init(
        repository: Repository,
        source: NewWorktreeSource,
        worktreePath: String,
        pathTemplate: WorktreePathTemplate,
        copySessionData: Bool = false,
        launchSessionPresetName: String? = nil,
        runHookCommand: String? = nil
    ) {
        self.repository = repository
        self.source = source
        self.worktreePath = worktreePath
        self.pathTemplate = pathTemplate
        self.copySessionData = copySessionData
        self.launchSessionPresetName = launchSessionPresetName
        self.runHookCommand = runHookCommand
    }
}
