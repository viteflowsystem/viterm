import Foundation

/// worktree 作成フォームの「ベースブランチ」等の選択肢1件。
/// ローカル/リモートのブランチ一覧は呼び出し側(GitKit 経由の問い合わせ)から注入する想定で、
/// `ViteaCore` 自体は git 操作を一切行わない。
public struct AvailableBranch: Sendable, Equatable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Equatable, Hashable {
        case local
        case remote
    }

    /// local は短縮ブランチ名(例: `main`)、remote は `<remote>/<branch>` 形式(例: `origin/main`)。
    public var name: String
    public var kind: Kind

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }

    public var id: String { "\(kind.rawValue):\(name)" }
}
