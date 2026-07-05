import Foundation
import GitKit
import VitermCore

/// 登録リポジトリ群の worktree 一覧・ahead/behind・diffstat・dirty を収集し、
/// サイドバー表示用の `VitermCore.Worktree` に変換する。
///
/// `GitKit.Worktree` と `VitermCore.Worktree` は同名のため、このファイル内では常にモジュール修飾で区別する。
public struct WorktreeStatusScanner: Sendable {
    public var gitService: GitService

    public init(gitService: GitService = GitService()) {
        self.gitService = gitService
    }

    /// 登録済みリポジトリ群すべてをスキャンする。個々のリポジトリでの失敗
    /// (パスが存在しない・git リポジトリでない等)は無視して結果から除外し、他のリポジトリには影響しない。
    public func scan(repositories: [VitermCore.Repository]) async -> [VitermCore.Worktree] {
        var result: [VitermCore.Worktree] = []
        for repository in repositories {
            if let worktrees = try? await scan(repository: repository) {
                result.append(contentsOf: worktrees)
            }
        }
        return result
    }

    /// 単一リポジトリの worktree 一覧をスキャンする。
    public func scan(repository: VitermCore.Repository) async throws -> [VitermCore.Worktree] {
        let repositoryURL = URL(fileURLWithPath: repository.path)
        let gitWorktrees = try await gitService.worktrees(in: repositoryURL)
        let defaultBranch = try? await gitService.defaultBranch(in: repositoryURL)

        var results: [VitermCore.Worktree] = []
        for gitWorktree: GitKit.Worktree in gitWorktrees {
            // detached HEAD の worktree はブランチを持たずサイドバー表示の対象外とする。
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
