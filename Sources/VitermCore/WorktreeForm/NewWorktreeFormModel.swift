import Foundation

/// UI-independent form state for the new-worktree dialog (docs/ui-mock.html Screen 03).
/// Responsible for branch name validation, real-time preview of path template expansion,
/// collision detection against existing worktree paths, and building a `NewWorktreeRequest`
/// when submittable. A pure value type that performs no git operations or file I/O.
public struct NewWorktreeFormModel: Sendable, Equatable {
    /// Selection mode for the worktree source. Corresponds to the 3 patterns in docs/requirements.md 3.1.
    public enum SourceMode: Sendable, Equatable {
        /// Create a new branch (the default flow in docs/ui-mock.html Screen 03).
        case newBranch
        /// Check out an existing local branch as-is.
        case existingLocalBranch
        /// Create a new local branch tracking a remote branch.
        case remoteBranch
    }

    // MARK: Context injected from outside (immutable during the form's lifecycle)

    public var repository: Repository
    /// Default template derived from config (`VitermConfig.worktreePathTemplate`).
    public var defaultPathTemplate: WorktreePathTemplate
    /// Options for the "base branch" / "existing branch" dropdowns. Mixed local/remote.
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
    /// Shell command to run as a post-creation hook. `nil`/empty string runs nothing.
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

    /// `newBranch` / `remoteBranch` create a new local ref, so they are subject to the
    /// duplicate check; `existingLocalBranch` reuses an existing ref as-is, so it is exempt.
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

    /// The path template actually used (an in-place override takes precedence).
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

    /// Whether the form is submittable (no branch name error and no path collision).
    public var isValid: Bool {
        branchNameError == nil && !hasPathCollision
    }

    /// Builds and returns the creation request if validation passes; otherwise `nil`.
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
