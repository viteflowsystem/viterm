import Foundation

/// git worktree 1つ分の状態スナップショット。
public struct Worktree: Codable, Sendable, Hashable, Identifiable {
    /// worktree の絶対パス。
    public var path: String
    /// 紐付く `Repository.id`(= リポジトリルートの絶対パス)への参照。
    public var repositoryPath: String
    /// チェックアウト中のブランチ名。
    public var branch: String
    /// 親ブランチに対する ahead コミット数。
    public var ahead: Int
    /// 親ブランチに対する behind コミット数。
    public var behind: Int
    /// ステージ済みの変更があるか(`git status --porcelain` の X カラム)。
    public var hasStagedChanges: Bool
    /// 未ステージの変更(untracked 含む)があるか(同 Y カラム / `??`)。
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

    /// 未コミットの変更(staged / unstaged いずれか)があるかどうか。
    public var isDirty: Bool { hasStagedChanges || hasUnstagedChanges }
}
