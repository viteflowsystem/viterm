import Foundation

/// worktree 新規作成ダイアログ(docs/ui-mock.html Screen 03)の UI 非依存なフォーム状態。
/// ブランチ名バリデーション、パステンプレート展開のリアルタイムプレビュー、
/// 既存 worktree パスとの衝突検出、送信可能時の `NewWorktreeRequest` 組み立てを担う。
/// git 操作・ファイルI/O は一切行わない純粋な値型。
public struct NewWorktreeFormModel: Sendable, Equatable {
    /// worktree 作成元の選択モード。docs/requirements.md 3.1 の3パターンに対応。
    public enum SourceMode: Sendable, Equatable {
        /// 新規ブランチを作成する(docs/ui-mock.html Screen 03 の既定フロー)。
        case newBranch
        /// 既存のローカルブランチをそのままチェックアウトする。
        case existingLocalBranch
        /// リモートブランチを追跡する新規ローカルブランチを作る。
        case remoteBranch
    }

    // MARK: 外部から注入される文脈(フォームのライフサイクル中は不変)

    public var repository: Repository
    /// 設定(`VitermConfig.worktreePathTemplate`)由来の既定テンプレート。
    public var defaultPathTemplate: WorktreePathTemplate
    /// 「ベースブランチ」「既存ブランチ」ドロップダウンの選択肢。ローカル/リモート混在。
    public var availableBranches: [AvailableBranch]
    /// 衝突検出に使う、既存 worktree の絶対パス一覧。
    public var existingWorktreePaths: [String]
    /// `~` 展開に使うホームディレクトリ(テスト用に注入可能)。
    public var homeDirectory: String

    // MARK: ユーザー入力

    public var branchName: String
    public var sourceMode: SourceMode
    /// `newBranch` モードでのベースブランチ(起点)。`nil` なら現在の HEAD から分岐する。
    public var baseBranchName: String?
    /// `remoteBranch` モードで追跡するリモート名(例: `"origin"`)。
    public var remoteName: String?
    /// パステンプレートのその場上書き。`nil` なら `defaultPathTemplate` を使う。
    public var pathTemplateOverride: String?
    public var copySessionData: Bool
    /// 作成後に起動するセッションプリセット名。`nil` なら起動しない。
    public var launchSessionPresetName: String?
    /// post-creation hook として実行するシェルコマンド。`nil`/空文字なら実行しない。
    public var runHookCommand: String?

    public init(
        repository: Repository,
        defaultPathTemplate: WorktreePathTemplate,
        availableBranches: [AvailableBranch] = [],
        existingWorktreePaths: [String] = [],
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        branchName: String = "",
        sourceMode: SourceMode = .newBranch,
        baseBranchName: String? = nil,
        remoteName: String? = nil,
        pathTemplateOverride: String? = nil,
        copySessionData: Bool = false,
        launchSessionPresetName: String? = nil,
        runHookCommand: String? = nil
    ) {
        self.repository = repository
        self.defaultPathTemplate = defaultPathTemplate
        self.availableBranches = availableBranches
        self.existingWorktreePaths = existingWorktreePaths
        self.homeDirectory = homeDirectory
        self.branchName = branchName
        self.sourceMode = sourceMode
        self.baseBranchName = baseBranchName
        self.remoteName = remoteName
        self.pathTemplateOverride = pathTemplateOverride
        self.copySessionData = copySessionData
        self.launchSessionPresetName = launchSessionPresetName
        self.runHookCommand = runHookCommand
    }

    /// 既存のローカルブランチ名一覧(`availableBranches` から抽出)。
    public var existingLocalBranchNames: [String] {
        availableBranches.filter { $0.kind == .local }.map(\.name)
    }

    /// `newBranch` / `remoteBranch` は新しいローカル ref を作るため重複チェック対象になるが、
    /// `existingLocalBranch` は既存 ref をそのまま使うため対象外。
    private var shouldCheckDuplicateBranchName: Bool {
        sourceMode != .existingLocalBranch
    }

    /// ブランチ名のバリデーションエラー。問題無ければ `nil`。
    public var branchNameError: BranchNameValidationError? {
        BranchNameValidator.validate(
            branchName,
            existingLocalBranchNames: existingLocalBranchNames,
            checkDuplicate: shouldCheckDuplicateBranchName
        )
    }

    /// 実際に使われるパステンプレート(その場上書きがあればそれを優先)。
    public var effectivePathTemplate: WorktreePathTemplate {
        pathTemplateOverride.map(WorktreePathTemplate.init) ?? defaultPathTemplate
    }

    /// 現在の入力値をテンプレートに展開したプレビューパス。ブランチ名が空なら `nil`。
    public var pathPreview: String? {
        guard !branchName.isEmpty else { return nil }
        let context = WorktreePathTemplate.Context(
            projectName: repository.name,
            branch: branchName,
            repositoryRoot: repository.path
        )
        return effectivePathTemplate.expand(context: context, homeDirectory: homeDirectory)
    }

    /// プレビューパスが既存の worktree と衝突しているか。
    public var hasPathCollision: Bool {
        guard let pathPreview else { return false }
        return existingWorktreePaths.contains(pathPreview)
    }

    /// 送信可能な状態かどうか(ブランチ名エラー無し・パス衝突無し)。
    public var isValid: Bool {
        branchNameError == nil && !hasPathCollision
    }

    /// バリデーションを通過していれば作成リクエストを組み立てて返す。通過していなければ `nil`。
    public func buildRequest() -> NewWorktreeRequest? {
        guard isValid, let pathPreview else { return nil }

        let source: NewWorktreeSource
        switch sourceMode {
        case .newBranch:
            source = .newBranch(name: branchName, startPoint: baseBranchName)
        case .existingLocalBranch:
            source = .existingLocalBranch(name: branchName)
        case .remoteBranch:
            source = .remoteBranch(remote: remoteName ?? "origin", name: branchName, newLocalName: nil)
        }

        return NewWorktreeRequest(
            repository: repository,
            source: source,
            worktreePath: pathPreview,
            pathTemplate: effectivePathTemplate,
            copySessionData: copySessionData,
            launchSessionPresetName: launchSessionPresetName,
            runHookCommand: runHookCommand
        )
    }
}
