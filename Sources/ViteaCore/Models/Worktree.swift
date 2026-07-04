import Foundation

/// git worktree 1つ分の状態スナップショット。
public struct Worktree: Codable, Sendable, Hashable, Identifiable {
    /// worktree の絶対パス。
    public var path: String
    /// チェックアウト中のブランチ名。
    public var branch: String
    /// 親ブランチに対する ahead コミット数。
    public var ahead: Int
    /// 親ブランチに対する behind コミット数。
    public var behind: Int
    /// 差分行数の要約。
    public var diffStat: DiffStat
    /// 未コミットの変更があるかどうか。
    public var isDirty: Bool

    public init(
        path: String,
        branch: String,
        ahead: Int = 0,
        behind: Int = 0,
        diffStat: DiffStat = DiffStat(),
        isDirty: Bool = false
    ) {
        self.path = path
        self.branch = branch
        self.ahead = ahead
        self.behind = behind
        self.diffStat = diffStat
        self.isDirty = isDirty
    }

    public var id: String { path }

    /// `git diff --shortstat` 相当の追加/削除行数。
    public struct DiffStat: Codable, Sendable, Hashable {
        public var added: Int
        public var removed: Int

        public init(added: Int = 0, removed: Int = 0) {
            self.added = added
            self.removed = removed
        }
    }
}
