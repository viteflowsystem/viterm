import Foundation
import GitKit

/// merge/rebase → worktree 削除 → ローカルブランチ削除、を順に行うリクエスト。
public struct MergeCleanupRequest: Sendable {
    /// 取り込む側のブランチ(例: フィーチャーブランチ)。
    public var source: String
    /// 取り込まれる側のブランチ(例: main)。
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

/// `MergeCleanupCoordinator` の各ステップ。
public enum MergeCleanupStep: String, Sendable {
    case merge
    case removeWorktree
    case deleteBranch
}

/// 1ステップの結果。`error == nil` が成功。
public struct MergeCleanupStepResult: Sendable {
    public var step: MergeCleanupStep
    public var error: String?

    public init(step: MergeCleanupStep, error: String? = nil) {
        self.step = step
        self.error = error
    }

    public var isSuccess: Bool { error == nil }
}

/// `mergeAndCleanUp` 全体の結果。実行されたステップのみが `steps` に含まれる
/// (前段が失敗した場合、後続ステップは記録されず実行もされない)。
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

/// マージ(または rebase)後の後始末を1つのフローとしてまとめる。
/// merge が失敗した場合はその時点で停止する(未マージの状態で worktree/ブランチを消すと
/// 変更を失うため)。worktree 削除が失敗した場合もブランチ削除は行わない
/// (force 未指定の dirty 検出等、安全のため人手の確認を挟むべきケース)。
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
