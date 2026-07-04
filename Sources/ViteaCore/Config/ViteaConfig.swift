import Foundation

/// セッション状態変化 hook のコマンド設定。到達した新状態(busy/waitingInput/idle)ごとに
/// 1つずつコマンドを持つ(`ViteaServices.StatusChangeHookConfig` と同じ形だが、
/// ViteaCore は ViteaServices に依存しないためここに独立して定義する)。
public struct StatusHooksFile: Codable, Sendable, Equatable {
    public var onBusy: String?
    public var onWaitingInput: String?
    public var onIdle: String?

    public init(onBusy: String? = nil, onWaitingInput: String? = nil, onIdle: String? = nil) {
        self.onBusy = onBusy
        self.onWaitingInput = onWaitingInput
        self.onIdle = onIdle
    }
}

/// 設定ファイル(グローバル `~/.config/vitea/config.json` / プロジェクト別 `.vitea.json`)の
/// 生のデコード結果。全フィールドは省略可能で、省略時は上位設定にフォールバックする。
public struct ViteaConfigFile: Codable, Sendable, Equatable {
    public var worktreePathTemplate: String?
    public var presets: [SessionPreset]?
    public var defaultPreset: String?
    public var repositories: [Repository]?
    public var copySessionDataByDefault: Bool?
    /// worktree 作成後に実行する post-creation hook のシェルコマンド。
    public var postCreationHook: String?
    /// セッション状態変化 hook。
    public var statusHooks: StatusHooksFile?
    /// リポジトリ自動検出(`RepositoryDiscovery`)の走査ルートディレクトリ一覧。
    /// マージ時はグローバル設定の値のみを使う(`.vitea.json` に書いても現状は反映されない。§merge 参照)。
    public var discoveryRoots: [String]?

    public init(
        worktreePathTemplate: String? = nil,
        presets: [SessionPreset]? = nil,
        defaultPreset: String? = nil,
        repositories: [Repository]? = nil,
        copySessionDataByDefault: Bool? = nil,
        postCreationHook: String? = nil,
        statusHooks: StatusHooksFile? = nil,
        discoveryRoots: [String]? = nil
    ) {
        self.worktreePathTemplate = worktreePathTemplate
        self.presets = presets
        self.defaultPreset = defaultPreset
        self.repositories = repositories
        self.copySessionDataByDefault = copySessionDataByDefault
        self.postCreationHook = postCreationHook
        self.statusHooks = statusHooks
        self.discoveryRoots = discoveryRoots
    }
}

/// グローバル設定とプロジェクト設定をマージした、実際に使用する設定値。
/// ファイルが存在しない場合でも `ViteaConfig.default` が示す既定値で動作する。
public struct ViteaConfig: Sendable, Equatable {
    public var worktreePathTemplate: String
    public var presets: [SessionPreset]
    public var defaultPreset: String?
    public var repositories: [Repository]
    public var copySessionDataByDefault: Bool
    public var postCreationHook: String?
    public var statusHooks: StatusHooksFile
    public var discoveryRoots: [String]

    public init(
        worktreePathTemplate: String,
        presets: [SessionPreset],
        defaultPreset: String?,
        repositories: [Repository],
        copySessionDataByDefault: Bool,
        postCreationHook: String? = nil,
        statusHooks: StatusHooksFile = StatusHooksFile(),
        discoveryRoots: [String] = []
    ) {
        self.worktreePathTemplate = worktreePathTemplate
        self.presets = presets
        self.defaultPreset = defaultPreset
        self.repositories = repositories
        self.copySessionDataByDefault = copySessionDataByDefault
        self.postCreationHook = postCreationHook
        self.statusHooks = statusHooks
        self.discoveryRoots = discoveryRoots
    }

    /// 現在の worktree パステンプレート設定を表す `WorktreePathTemplate`。
    public var pathTemplate: WorktreePathTemplate {
        WorktreePathTemplate(worktreePathTemplate)
    }

    public static let defaultPresets: [SessionPreset] = [
        SessionPreset(name: "claude", command: "claude"),
        SessionPreset(name: "codex", command: "codex"),
        SessionPreset(name: "shell", command: "/bin/zsh"),
    ]

    public static let `default` = ViteaConfig(
        worktreePathTemplate: "~/worktrees/{project}/{branch}",
        presets: defaultPresets,
        defaultPreset: "claude",
        repositories: [],
        copySessionDataByDefault: false,
        postCreationHook: nil,
        statusHooks: StatusHooksFile(),
        discoveryRoots: []
    )

    /// グローバル設定・プロジェクト設定(両方 optional)を、既定値をベースにマージする。
    /// スカラー値はプロジェクト側が優先(nil ならグローバル、それも nil なら既定値)。
    /// リスト値(`presets` / `repositories`)は名前をキーに merge し、
    /// 同名エントリはプロジェクト側の内容で上書きする。組み込み既定プリセットは常にベースとして
    /// 適用されるため、`presets` を1件でも指定すると既定プリセットが丸ごと消える、ということはない。
    /// `discoveryRoots` はグローバル設定の値のみを使う(`.vitea.json` 側は無視する。複数リポジトリ
    /// 横断でスキャンするルートという性質上、プロジェクト単位で持つ意味が薄いため)。
    public static func merge(global: ViteaConfigFile?, project: ViteaConfigFile?) -> ViteaConfig {
        let base = ViteaConfig.default

        let worktreePathTemplate = project?.worktreePathTemplate
            ?? global?.worktreePathTemplate
            ?? base.worktreePathTemplate
        let defaultPreset = project?.defaultPreset
            ?? global?.defaultPreset
            ?? base.defaultPreset
        let copySessionDataByDefault = project?.copySessionDataByDefault
            ?? global?.copySessionDataByDefault
            ?? base.copySessionDataByDefault
        let postCreationHook = project?.postCreationHook
            ?? global?.postCreationHook
            ?? base.postCreationHook

        let statusHooks = StatusHooksFile(
            onBusy: project?.statusHooks?.onBusy ?? global?.statusHooks?.onBusy ?? base.statusHooks.onBusy,
            onWaitingInput: project?.statusHooks?.onWaitingInput
                ?? global?.statusHooks?.onWaitingInput
                ?? base.statusHooks.onWaitingInput,
            onIdle: project?.statusHooks?.onIdle ?? global?.statusHooks?.onIdle ?? base.statusHooks.onIdle
        )

        let discoveryRoots = global?.discoveryRoots ?? base.discoveryRoots

        let presets = mergeKeyed(
            base: base.presets,
            global: global?.presets,
            project: project?.presets,
            key: \.name
        )
        let repositories = mergeKeyed(
            base: base.repositories,
            global: global?.repositories,
            project: project?.repositories,
            key: \.id
        )

        return ViteaConfig(
            worktreePathTemplate: worktreePathTemplate,
            presets: presets,
            defaultPreset: defaultPreset,
            repositories: repositories,
            copySessionDataByDefault: copySessionDataByDefault,
            postCreationHook: postCreationHook,
            statusHooks: statusHooks,
            discoveryRoots: discoveryRoots
        )
    }

    /// 既定値 → グローバル → プロジェクトの順に、キーごとに後勝ちで重ね合わせる。
    /// 既定値は常にベースとして適用されるため、グローバル/プロジェクトが1件でも指定したからといって
    /// 既定値が丸ごと消えることはない(同じキーのエントリだけが上書きされる)。
    /// 既存キーは値を丸ごと上書き(フィールド単位のマージではない)、新規キーは末尾に追加する形で
    /// 順序を保つ。
    private static func mergeKeyed<T, Key: Hashable>(
        base: [T],
        global: [T]?,
        project: [T]?,
        key: (T) -> Key
    ) -> [T] {
        var order: [Key] = []
        var map: [Key: T] = [:]

        func apply(_ items: [T]) {
            for item in items {
                let k = key(item)
                if map[k] == nil { order.append(k) }
                map[k] = item
            }
        }

        apply(base)
        apply(global ?? [])
        apply(project ?? [])

        return order.compactMap { map[$0] }
    }
}
