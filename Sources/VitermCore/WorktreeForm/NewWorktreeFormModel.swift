import Foundation

/// UI-independent form state of the new-worktree dialog (docs/ui-mock.html Screen 03).
/// Handles branch name validation, real-time preview of path template expansion,
/// collision detection against existing worktree paths, and building the
/// `NewWorktreeRequest` when submittable. A pure value type doing no git operations or
/// file I/O.
public struct NewWorktreeFormModel: Sendable, Equatable {
    /// Selection mode for the worktree source. Corresponds to the three patterns in docs/requirements.md 3.1.
    public enum SourceMode: Sendable, Equatable {
        /// Create a new branch (the default flow of docs/ui-mock.html Screen 03).
        case newBranch
        /// Check out an existing local branch as-is.
        case existingLocalBranch
        /// Create a new local branch tracking a remote branch.
        case remoteBranch
    }

    // MARK: Context injected from outside (immutable for the form's lifecycle)

    public var repository: Repository
    /// Default template from the config (`VitermConfig.worktreePathTemplate`).
    public var defaultPathTemplate: WorktreePathTemplate
    /// Options for the "base branch" / "existing branch" dropdowns. Local and remote mixed.
    public var availableBranches: [AvailableBranch]
    /// Absolute paths of existing worktrees, used for collision detection.
    public var existingWorktreePaths: [String]
    /// Home directory used for `~` expansion (injectable for tests).
    public var homeDirectory: String

    // MARK: User input

    public var branchName: String
    public var sourceMode: SourceMode
    /// Base branch (start point) in `newBranch` mode. `nil` branches from the current HEAD.
    public var baseBranchName: String?
    /// Remote name to track in `remoteBranch` mode (e.g. `"origin"`).
    public var remoteName: String?
    /// In-place override of the path template. `nil` uses `defaultPathTemplate`.
    public var pathTemplateOverride: String?
    public var copySessionData: Bool
    /// Session preset name to launch after creation. `nil` launches nothing.
    public var launchSessionPresetName: String?
    /// Shell command run as the post-creation hook. Not run if `nil`/empty.
    public var runHookCommand: String?

    public init(
        repository: Repository,
        defaultPathTemplate: WorktreePathTemplate,
        availableBranches: [AvailableBranch] = [],
        existingWorktreePaths: [String] = [],
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        branchName: String = "",
        sourceMode: SourceMode = .newBranch,
        baseBranchName: String? = nil,
        remoteName: String? = nil,
        pathTemplateOverride: String? = nil,
        copySessionData: Bool = false,
        launchSessionPresetName: String? = nil,
        runHookCommand: String? = nil
    ) {
        self.repository = repository
        self.defaultPathTemplate = defaultPathTemplate
        self.availableBranches = availableBranches
        self.existingWorktreePaths = existingWorktreePaths
        self.homeDirectory = homeDirectory
        self.branchName = branchName
        self.sourceMode = sourceMode
        self.baseBranchName = baseBranchName
        self.remoteName = remoteName
        self.pathTemplateOverride = pathTemplateOverride
        self.copySessionData = copySessionData
        self.launchSessionPresetName = launchSessionPresetName
        self.runHookCommand = runHookCommand
    }

    /// Names of existing local branches (extracted from `availableBranches`).
    public var existingLocalBranchNames: [String] {
        availableBranches.filter { $0.kind == .local }.map(\.name)
    }

    /// `newBranch` / `remoteBranch` create a new local ref and therefore get the duplicate
    /// check; `existingLocalBranch` uses an existing ref as-is and is exempt.
    private var shouldCheckDuplicateBranchName: Bool {
        sourceMode != .existingLocalBranch
    }

    /// Branch name validation error. `nil` if there is no problem.
    public var branchNameError: BranchNameValidationError? {
        BranchNameValidator.validate(
            branchName,
            existingLocalBranchNames: existingLocalBranchNames,
            checkDuplicate: shouldCheckDuplicateBranchName
        )
    }

    /// The path template actually used (the in-place override wins if present).
    public var effectivePathTemplate: WorktreePathTemplate {
        pathTemplateOverride.map(WorktreePathTemplate.init) ?? defaultPathTemplate
    }

    /// Preview path from expanding the template with the current input. `nil` if the branch name is empty.
    public var pathPreview: String? {
        guard !branchName.isEmpty else { return nil }
        let context = WorktreePathTemplate.Context(
            projectName: repository.name,
            branch: branchName,
            repositoryRoot: repository.path
        )
        return effectivePathTemplate.expand(context: context, homeDirectory: homeDirectory)
    }

    /// Whether the preview path collides with an existing worktree.
    public var hasPathCollision: Bool {
        guard let pathPreview else { return false }
        return existingWorktreePaths.contains(pathPreview)
    }

    /// Whether the form is submittable (no branch name error, no path collision).
    public var isValid: Bool {
        branchNameError == nil && !hasPathCollision
    }

    /// Build and return the creation request if validation passes; `nil` otherwise.
    public func buildRequest() -> NewWorktreeRequest? {
        guard isValid, let pathPreview else { return nil }

        let source: NewWorktreeSource
        switch sourceMode {
        case .newBranch:
            source = .newBranch(name: branchName, startPoint: baseBranchName)
        case .existingLocalBranch:
            source = .existingLocalBranch(name: branchName)
        case .remoteBranch:
            source = .remoteBranch(remote: remoteName ?? "origin", name: branchName, newLocalName: nil)
        }

        return NewWorktreeRequest(
            repository: repository,
            source: source,
            worktreePath: pathPreview,
            pathTemplate: effectivePathTemplate,
            copySessionData: copySessionData,
            launchSessionPresetName: launchSessionPresetName,
            runHookCommand: runHookCommand
        )
    }
}
