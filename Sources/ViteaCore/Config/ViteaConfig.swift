import Foundation

/// 設定ファイル(グローバル `~/.config/vitea/config.json` / プロジェクト別 `.vitea.json`)の
/// 生のデコード結果。全フィールドは省略可能で、省略時は上位設定にフォールバックする。
public struct ViteaConfigFile: Codable, Sendable, Equatable {
    public var worktreePathTemplate: String?
    public var presets: [SessionPreset]?
    public var defaultPreset: String?
    public var repositories: [Repository]?
    public var copySessionDataByDefault: Bool?

    public init(
        worktreePathTemplate: String? = nil,
        presets: [SessionPreset]? = nil,
        defaultPreset: String? = nil,
        repositories: [Repository]? = nil,
        copySessionDataByDefault: Bool? = nil
    ) {
        self.worktreePathTemplate = worktreePathTemplate
        self.presets = presets
        self.defaultPreset = defaultPreset
        self.repositories = repositories
        self.copySessionDataByDefault = copySessionDataByDefault
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

    public init(
        worktreePathTemplate: String,
        presets: [SessionPreset],
        defaultPreset: String?,
        repositories: [Repository],
        copySessionDataByDefault: Bool
    ) {
        self.worktreePathTemplate = worktreePathTemplate
        self.presets = presets
        self.defaultPreset = defaultPreset
        self.repositories = repositories
        self.copySessionDataByDefault = copySessionDataByDefault
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
        copySessionDataByDefault: false
    )

    /// グローバル設定・プロジェクト設定(両方 optional)を、既定値をベースにマージする。
    /// スカラー値はプロジェクト側が優先(nil ならグローバル、それも nil なら既定値)。
    /// リスト値(`presets` / `repositories`)は名前をキーに merge し、
    /// 同名エントリはプロジェクト側の内容で上書きする。
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
            copySessionDataByDefault: copySessionDataByDefault
        )
    }

    /// 3段階(既定値 → グローバル → プロジェクト)を、キーごとに後勝ちで重ね合わせる。
    /// 既存キーは値を上書き、新規キーは末尾に追加する形で順序を保つ。
    private static func mergeKeyed<T, Key: Hashable>(
        base: [T],
        global: [T]?,
        project: [T]?,
        key: (T) -> Key
    ) -> [T] {
        // グローバル/プロジェクトのどちらかが明示的に指定された時点で、
        // 既定プリセット・既定リポジトリ一覧はそれらの内容で構成し直す。
        // (グローバルにもプロジェクトにも指定が無い場合のみ既定値をそのまま使う)
        var order: [Key] = []
        var map: [Key: T] = [:]

        func apply(_ items: [T]) {
            for item in items {
                let k = key(item)
                if map[k] == nil { order.append(k) }
                map[k] = item
            }
        }

        if global == nil && project == nil {
            apply(base)
        } else {
            apply(global ?? [])
            apply(project ?? [])
        }

        return order.compactMap { map[$0] }
    }
}
