import Foundation

/// アプリに登録されたリポジトリ(サイドバー最上位階層)。
/// ディスク上のリポジトリ自体には手を加えない、単なる参照情報。
public struct Repository: Codable, Sendable, Hashable, Identifiable {
    /// サイドバー表示名。`WorktreePathTemplate` の `{project}` プレースホルダにも使われる。
    public var name: String
    /// リポジトリルートの絶対パス。
    public var path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }

    public var id: String { path }
}
