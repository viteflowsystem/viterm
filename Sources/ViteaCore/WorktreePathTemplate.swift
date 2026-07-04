import Foundation

/// worktree 作成先パスのテンプレート展開。
///
/// 例: `~/worktrees/{project}/{branch}_suffix`
/// プレースホルダ:
/// - `{project}`: リポジトリ名
/// - `{branch}`: ブランチ名(`/` は `-` に正規化。例: `feat/x` → `feat-x`)
/// - `{branch_raw}`: ブランチ名そのまま(`feat/x` はサブディレクトリになる)
///
/// `~` 始まりはホームディレクトリ基準、`/` 始まりは絶対パスとしてそのまま、
/// それ以外は `repositoryRoot` 基準の相対パスとして解決する。
public struct WorktreePathTemplate: Sendable, Equatable {
    public var raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    /// 展開に必要な文脈情報。
    public struct Context: Sendable, Equatable {
        /// `{project}` に埋め込むリポジトリ名。
        public var projectName: String
        /// `{branch}` / `{branch_raw}` に埋め込むブランチ名(生の形、`/` を含みうる)。
        public var branch: String
        /// 相対パステンプレートを解決する基準となるリポジトリルートの絶対パス。
        public var repositoryRoot: String

        public init(projectName: String, branch: String, repositoryRoot: String) {
            self.projectName = projectName
            self.branch = branch
            self.repositoryRoot = repositoryRoot
        }
    }

    /// テンプレートを実際のパス文字列に展開する。
    /// - Parameters:
    ///   - context: プレースホルダ・相対パス解決に使う情報。
    ///   - homeDirectory: `~` 展開に使うホームディレクトリ(テスト用に注入可能。既定は実際のホーム)。
    public func expand(
        context: Context,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        let normalizedBranch = context.branch.replacingOccurrences(of: "/", with: "-")
        let substituted = raw
            .replacingOccurrences(of: "{branch_raw}", with: context.branch)
            .replacingOccurrences(of: "{branch}", with: normalizedBranch)
            .replacingOccurrences(of: "{project}", with: context.projectName)

        if substituted == "~" {
            return homeDirectory
        }
        if substituted.hasPrefix("~/") {
            return homeDirectory + substituted.dropFirst(1)
        }
        if substituted.hasPrefix("/") {
            return substituted
        }
        // 相対パス: リポジトリルート基準で解決する。
        let trimmedRoot = context.repositoryRoot.hasSuffix("/")
            ? String(context.repositoryRoot.dropLast())
            : context.repositoryRoot
        return trimmedRoot + "/" + substituted
    }
}
