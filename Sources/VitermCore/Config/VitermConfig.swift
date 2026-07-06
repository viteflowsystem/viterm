import Foundation

/// Command configuration for session state-change hooks. Holds one command per new state
/// reached (busy/waitingInput/idle). Same shape as `VitermServices.StatusChangeHookConfig`,
/// but defined independently here because VitermCore does not depend on VitermServices.
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

/// Raw decoding result of a config file (global `~/.config/viterm/config.json` /
/// per-project `.viterm.json`). All fields are optional; omitted fields fall back to the higher-level config.
public struct VitermConfigFile: Codable, Sendable, Equatable {
    public var worktreePathTemplate: String?
    public var presets: [SessionPreset]?
    public var defaultPreset: String?
    public var repositories: [Repository]?
    public var copySessionDataByDefault: Bool?
    /// Shell command for the post-creation hook run after a worktree is created.
    public var postCreationHook: String?
    /// Session state-change hooks.
    public var statusHooks: StatusHooksFile?
    /// Root directories scanned by repository auto-discovery (`RepositoryDiscovery`).
    /// Merging uses only the global config's value (writing it in `.viterm.json` currently has no effect; see §merge).
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

/// The effective configuration values, merged from the global and project configs.
/// Even when no files exist, operation proceeds with the defaults given by `VitermConfig.default`.
public struct VitermConfig: Sendable, Equatable {
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

    /// The current worktree path template setting as a `WorktreePathTemplate`.
    public var pathTemplate: WorktreePathTemplate {
        WorktreePathTemplate(worktreePathTemplate)
    }

    public static let defaultPresets: [SessionPreset] = [
        SessionPreset(name: "claude", command: "claude"),
        SessionPreset(name: "codex", command: "codex"),
        SessionPreset(name: "shell", command: "/bin/zsh"),
    ]

    public static let `default` = VitermConfig(
        worktreePathTemplate: "~/worktrees/{project}/{branch}",
        presets: defaultPresets,
        // Default is a shell. Agents (claude etc.) are expected to be launched by the user inside the shell.
        // To always open claude, change defaultPreset in Settings (⌘,).
        defaultPreset: "shell",
        repositories: [],
        copySessionDataByDefault: false,
        postCreationHook: nil,
        statusHooks: StatusHooksFile(),
        discoveryRoots: []
    )

    /// Merges the global and project configs (both optional) on top of the defaults.
    /// Scalar values: the project side wins (falling back to global if nil, then to the default).
    /// List values (`presets` / `repositories`) are merged keyed by name, and entries with the
    /// same name are overwritten by the project side's content. The built-in default presets are
    /// always applied as the base, so specifying even one `presets` entry never wipes out the
    /// default presets wholesale.
    /// `discoveryRoots` uses only the global config's value (the `.viterm.json` side is ignored;
    /// as roots scanned across multiple repositories, holding them per project makes little sense).
    public static func merge(global: VitermConfigFile?, project: VitermConfigFile?) -> VitermConfig {
        let base = VitermConfig.default

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

        return VitermConfig(
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

    /// Layers defaults → global → project, last-writer-wins per key.
    /// The defaults are always applied as the base, so global/project specifying even one entry
    /// never wipes out the defaults wholesale (only entries with the same key are overwritten).
    /// Existing keys have their value replaced entirely (not a field-by-field merge); new keys
    /// are appended at the end, preserving order.
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
