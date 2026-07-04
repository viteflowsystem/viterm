import Foundation

/// worktree 作成元の3パターン。`GitKit.WorktreeSource` と同じ形だが、
/// `ViteaCore` は GitKit に依存しないためここに独立して定義する
/// (呼び出し側が `GitKit.WorktreeSource` へ1:1で変換する想定)。
public enum NewWorktreeSource: Sendable, Equatable {
    /// 新規ブランチを作成して worktree を追加する。`startPoint` を省略すると現在の HEAD から分岐する。
    case newBranch(name: String, startPoint: String?)
    /// 既存のローカルブランチをそのままチェックアウトする。
    case existingLocalBranch(name: String)
    /// リモートブランチを追跡する新規ローカルブランチを作って worktree を追加する。
    /// `newLocalName` を省略するとリモートと同名のローカルブランチになる。
    case remoteBranch(remote: String, name: String, newLocalName: String?)
}

/// `NewWorktreeFormModel.buildRequest()` がバリデーション通過時に返す、
/// worktree 作成に必要な値一式。`ViteaServices.WorktreeCreationRequest` へ変換して
/// `WorktreeProvisioner` に渡すことを想定しているが、この型自体は ViteaServices に依存しない。
public struct NewWorktreeRequest: Sendable, Equatable {
    public var repository: Repository
    public var source: NewWorktreeSource
    /// テンプレート展開済みの実際の作成先パス。
    public var worktreePath: String
    /// 展開に使ったパステンプレート(その場上書きがあればそれ、無ければ既定値)。
    public var pathTemplate: WorktreePathTemplate
    public var copySessionData: Bool
    /// 作成後に起動するセッションプリセット名。`nil` なら作成後にセッションを起動しない。
    public var launchSessionPresetName: String?
    /// post-creation hook として実行するシェルコマンド。`nil`/空文字なら実行しない。
    public var runHookCommand: String?

    public init(
        repository: Repository,
        source: NewWorktreeSource,
        worktreePath: String,
        pathTemplate: WorktreePathTemplate,
        copySessionData: Bool = false,
        launchSessionPresetName: String? = nil,
        runHookCommand: String? = nil
    ) {
        self.repository = repository
        self.source = source
        self.worktreePath = worktreePath
        self.pathTemplate = pathTemplate
        self.copySessionData = copySessionData
        self.launchSessionPresetName = launchSessionPresetName
        self.runHookCommand = runHookCommand
    }
}
