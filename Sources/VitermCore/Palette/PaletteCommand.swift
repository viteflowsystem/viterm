import Foundation

/// コマンドパレット(⌘K)に列挙される1コマンド。
/// docs/ui-mock.html の Screen 02(コマンドパレット)が表示仕様。
public struct PaletteCommand: Sendable, Equatable, Hashable, Identifiable {
    /// パレット上のカテゴリ見出し。
    public enum Category: Sendable, Equatable, Hashable, CaseIterable {
        case worktree
        case session
        case repository

        /// パレットに表示するカテゴリ見出し文字列(docs/ui-mock.html 準拠)。
        public var displayName: String {
            switch self {
            case .worktree: return "Worktree"
            case .session: return "Session"
            case .repository: return "Repo"
            }
        }
    }

    /// 一意な安定コマンドID(同一コンテキストなら再生成しても変わらない)。
    public var id: String
    public var category: Category
    public var title: String
    /// 右側に表示する補助情報(ahead/behind の `↑3 ↓1` 等)。無ければ `nil`。
    public var subtitle: String?
    /// 右端に表示するキーボードヒント(`⌘N` 等)。無ければ `nil`。
    public var keyboardHint: String?
    /// UI 側が switch して実行するアクション。
    public var action: PaletteAction

    public init(
        id: String,
        category: Category,
        title: String,
        subtitle: String? = nil,
        keyboardHint: String? = nil,
        action: PaletteAction
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.subtitle = subtitle
        self.keyboardHint = keyboardHint
        self.action = action
    }

    /// ファジー検索の対象になるテキスト。カテゴリ名を先頭に含めることで、
    /// カテゴリ名に対するクエリ(例: "wt")がそのカテゴリのコマンドを優先的に浮かび上がらせる。
    public var searchableText: String {
        "\(category.displayName) \(title)"
    }
}

/// `PaletteCommand` が実行する操作。UI 側がこれを switch して実際の処理(GitService 呼び出し・
/// ダイアログ表示・SessionManager 起動 等)にディスパッチする。ここには実行ロジックは含まない。
public enum PaletteAction: Sendable, Equatable, Hashable {
    /// worktree 新規作成ダイアログを開く。
    case createWorktree
    /// 指定した worktree に切り替える。
    case switchToWorktree(worktreeID: String)
    /// 指定した worktree のブランチをマージする(merge / rebase の選択は UI 側)。
    case mergeWorktree(worktreeID: String)
    /// 指定した worktree を削除する(確認ダイアログは UI 側)。
    case removeWorktree(worktreeID: String)
    /// 指定した worktree で、指定プリセットのセッションを起動する。
    case startSession(worktreeID: String, presetName: String)
    /// リポジトリ追加ダイアログ(ディレクトリ選択)を開く。
    case addRepository
}
