import Foundation
import GitKit

/// Request to run, in order: merge/rebase → worktree removal → local branch deletion.
public struct MergeCleanupRequest: Sendable {
    /// The branch being merged in (e.g. a feature branch).
    public var source: String
    /// The branch being merged into (e.g. main).
    public var target: String
    public var sourceWorktree: URL
    public var targetWorktree: URL
    public var strategy: MergeStrategy
    public var removeWorktreeAfterMerge: Bool
    public var forceRemoveWorktree: Bool
    public var deleteLocalBranchAfterMerge: Bool

    public init(
        source: String,
        target: String,
        sourceWorktree: URL,
        targetWorktree: URL,
        strategy: MergeStrategy = .merge(),
        removeWorktreeAfterMerge: Bool = true,
        forceRemoveWorktree: Bool = false,
        deleteLocalBranchAfterMerge: Bool = true
    ) {
        self.source = source
        self.target = target
        self.sourceWorktree = sourceWorktree
        self.targetWorktree = targetWorktree
        self.strategy = strategy
        self.removeWorktreeAfterMerge = removeWorktreeAfterMerge
        self.forceRemoveWorktree = forceRemoveWorktree
        self.deleteLocalBranchAfterMerge = deleteLocalBranchAfterMerge
    }
}

/// The individual steps of `MergeCleanupCoordinator`.
public enum MergeCleanupStep: String, Sendable {
    case merge
    case removeWorktree
    case deleteBranch
}

/// Result of a single step. `error == nil` means success.
public struct MergeCleanupStepResult: Sendable {
    public var step: MergeCleanupStep
    public var error: String?

    public init(step: MergeCleanupStep, error: String? = nil) {
        self.step = step
        self.error = error
    }

    public var isSuccess: Bool { error == nil }
}

/// The overall result of `mergeAndCleanUp`. Only steps that were executed appear in `steps`
/// (if an earlier step failed, subsequent steps are neither recorded nor executed).
public struct MergeCleanupResult: Sendable {
    public var steps: [MergeCleanupStepResult]

    public init(steps: [MergeCleanupStepResult]) {
        self.steps = steps
    }

    public var isFullySuccessful: Bool { steps.allSatisfy(\.isSuccess) }

    public func result(for step: MergeCleanupStep) -> MergeCleanupStepResult? {
        steps.first { $0.step == step }
    }
}

/// Bundles post-merge (or post-rebase) cleanup into a single flow.
/// If the merge fails, stops right there (deleting the worktree/branch while unmerged
/// would lose changes). If the worktree removal fails, the branch deletion is also skipped
/// (cases like a dirty tree detected without force — safety demands human confirmation).
public struct MergeCleanupCoordinator: Sendable {
    public var gitService: GitService

    public init(gitService: GitService = GitService()) {
        self.gitService = gitService
    }

    public func mergeAndCleanUp(_ request: MergeCleanupRequest) async -> MergeCleanupResult {
        var steps: [MergeCleanupStepResult] = []

        do {
            try await gitService.merge(
                source: request.source,
                target: request.target,
                sourceWorktree: request.sourceWorktree,
                targetWorktree: request.targetWorktree,
                strategy: request.strategy
            )
            steps.append(MergeCleanupStepResult(step: .merge))
        } catch {
            steps.append(MergeCleanupStepResult(step: .merge, error: "\(error)"))
            return MergeCleanupResult(steps: steps)
        }

        if request.removeWorktreeAfterMerge {
            do {
                try await gitService.removeWorktree(
                    at: request.sourceWorktree,
                    in: request.targetWorktree,
                    force: request.forceRemoveWorktree
                )
                steps.append(MergeCleanupStepResult(step: .removeWorktree))
            } catch {
                steps.append(MergeCleanupStepResult(step: .removeWorktree, error: "\(error)"))
                return MergeCleanupResult(steps: steps)
            }
        }

        if request.deleteLocalBranchAfterMerge {
            do {
                try await gitService.runner.run(["branch", "-d", request.source], in: request.targetWorktree)
                steps.append(MergeCleanupStepResult(step: .deleteBranch))
            } catch {
                steps.append(MergeCleanupStepResult(step: .deleteBranch, error: "\(error)"))
            }
        }

        return MergeCleanupResult(steps: steps)
    }
}
