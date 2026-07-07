import Foundation
import GitKit
import VitermCore

/// Collects worktree lists, ahead/behind, diffstat, and dirty flags for the registered
/// repositories and converts them into `VitermCore.Worktree` for sidebar display.
///
/// `GitKit.Worktree` and `VitermCore.Worktree` share a name, so within this file they are
/// always distinguished with module qualification.
public struct WorktreeStatusScanner: Sendable {
    public var gitService: GitService

    public init(gitService: GitService = GitService()) {
        self.gitService = gitService
    }

    /// Scan all registered repositories. Failures in an individual repository (path
    /// missing, not a git repository, etc.) are ignored and excluded from the result,
    /// without affecting other repositories.
    public func scan(repositories: [VitermCore.Repository]) async -> [VitermCore.Worktree] {
        var result: [VitermCore.Worktree] = []
        for repository in repositories {
            if let worktrees = try? await scan(repository: repository) {
                result.append(contentsOf: worktrees)
            }
        }
        return result
    }

    /// Scan the worktree list of a single repository.
    public func scan(repository: VitermCore.Repository) async throws -> [VitermCore.Worktree] {
        let repositoryURL = URL(fileURLWithPath: repository.path)
        let gitWorktrees = try await gitService.worktrees(in: repositoryURL)
        let defaultBranch = try? await gitService.defaultBranch(in: repositoryURL)

        var results: [VitermCore.Worktree] = []
        for gitWorktree: GitKit.Worktree in gitWorktrees {
            // A detached-HEAD worktree has no branch and is excluded from sidebar display.
            guard let branch = gitWorktree.branch else { continue }
            results.append(
                await status(for: gitWorktree, branch: branch, repository: repository, defaultBranch: defaultBranch)
            )
        }
        return results
    }

    private func status(
        for gitWorktree: GitKit.Worktree,
        branch: String,
        repository: VitermCore.Repository,
        defaultBranch: String?
    ) async -> VitermCore.Worktree {
        let comparisonBranch = (defaultBranch != nil && defaultBranch != branch) ? defaultBranch : nil

        var ahead = 0
        var behind = 0
        if let comparisonBranch,
           let counts = try? await gitService.aheadBehind(branch: branch, upstream: comparisonBranch, in: gitWorktree.path) {
            ahead = counts.ahead
            behind = counts.behind
        }

        let workingState = try? await gitService.workingState(at: gitWorktree.path)

        return VitermCore.Worktree(
            path: gitWorktree.path.path,
            repositoryPath: repository.path,
            branch: branch,
            ahead: ahead,
            behind: behind,
            hasStagedChanges: workingState?.hasStagedChanges ?? false,
            hasUnstagedChanges: workingState?.hasUnstagedChanges ?? false
        )
    }
}
