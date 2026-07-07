import Testing
@testable import VitermCore

@Suite("VitermConfig merge")
struct VitermConfigTests {
    @Test("両方 nil の場合は既定値になる")
    func bothNilUsesDefault() {
        let config = VitermConfig.merge(global: nil, project: nil)
        #expect(config == VitermConfig.default)
    }

    @Test("グローバルのみ指定されたスカラー値が使われる")
    func globalOnlyScalar() {
        let global = VitermConfigFile(worktreePathTemplate: "~/g/{project}/{branch}")
        let config = VitermConfig.merge(global: global, project: nil)
        #expect(config.worktreePathTemplate == "~/g/{project}/{branch}")
    }

    @Test("プロジェクト側のスカラー値がグローバルより優先される")
    func projectScalarOverridesGlobal() {
        let global = VitermConfigFile(worktreePathTemplate: "~/g/{branch}", copySessionDataByDefault: false)
        let project = VitermConfigFile(worktreePathTemplate: "~/p/{branch}")
        let config = VitermConfig.merge(global: global, project: project)
        #expect(config.worktreePathTemplate == "~/p/{branch}")
        // Fields the project side doesn't touch fall back to the global config
        #expect(config.copySessionDataByDefault == false)
    }

    @Test("defaultPreset はプロジェクト未指定ならグローバル値を使う")
    func defaultPresetFallsBackToGlobal() {
        let global = VitermConfigFile(defaultPreset: "codex")
        let config = VitermConfig.merge(global: global, project: VitermConfigFile())
        #expect(config.defaultPreset == "codex")
    }

    @Test("presets 未指定時は組み込みの既定プリセット一覧になる")
    func presetsDefaultWhenUnspecified() {
        let config = VitermConfig.merge(global: nil, project: nil)
        #expect(config.presets == VitermConfig.defaultPresets)
    }

    @Test("グローバルが presets を指定しても組み込み既定プリセットは残り、新規分が末尾に追加される")
    func globalPresetsAddToDefaults() {
        let global = VitermConfigFile(presets: [SessionPreset(name: "gemini", command: "gemini")])
        let config = VitermConfig.merge(global: global, project: nil)
        #expect(config.presets.map(\.name) == ["claude", "codex", "shell", "gemini"])
    }

    @Test("グローバルが組み込みプリセットと同名のプリセットを指定するとその場で上書きされる(既定は消えない)")
    func globalPresetOverridesBuiltinInPlace() {
        let global = VitermConfigFile(presets: [SessionPreset(name: "claude", command: "claude", arguments: ["--override"])])
        let config = VitermConfig.merge(global: global, project: nil)
        #expect(config.presets.map(\.name) == ["claude", "codex", "shell"])
        #expect(config.presets.first { $0.name == "claude" }?.arguments == ["--override"])
    }

    @Test("プロジェクトは同名プリセットをその場で上書きできる(位置は保持、組み込み既定は残る)")
    func projectOverridesPresetInPlace() {
        let global = VitermConfigFile(presets: [
            SessionPreset(name: "claude", command: "claude", arguments: ["--old"]),
            SessionPreset(name: "codex", command: "codex"),
        ])
        let project = VitermConfigFile(presets: [
            SessionPreset(name: "claude", command: "claude", arguments: ["--new"]),
        ])
        let config = VitermConfig.merge(global: global, project: project)
        #expect(config.presets.map(\.name) == ["claude", "codex", "shell"])
        #expect(config.presets.first { $0.name == "claude" }?.arguments == ["--new"])
    }

    @Test("プロジェクトが新規プリセットを追加すると末尾に追加される(組み込み既定は残る)")
    func projectAddsNewPreset() {
        let global = VitermConfigFile(presets: [SessionPreset(name: "claude", command: "claude")])
        let project = VitermConfigFile(presets: [SessionPreset(name: "gemini", command: "gemini")])
        let config = VitermConfig.merge(global: global, project: project)
        #expect(config.presets.map(\.name) == ["claude", "codex", "shell", "gemini"])
    }

    @Test("repositories は path をキーにマージされる")
    func repositoriesMergeByPath() {
        let global = VitermConfigFile(repositories: [
            Repository(name: "viterm", path: "/repo/viterm"),
            Repository(name: "other", path: "/repo/other"),
        ])
        let project = VitermConfigFile(repositories: [
            Repository(name: "viterm-renamed", path: "/repo/viterm"),
        ])
        let config = VitermConfig.merge(global: global, project: project)
        #expect(config.repositories.map(\.path) == ["/repo/viterm", "/repo/other"])
        #expect(config.repositories.first { $0.path == "/repo/viterm" }?.name == "viterm-renamed")
    }

    @Test("copySessionDataByDefault はプロジェクトが明示的に上書きできる")
    func copySessionDataOverride() {
        let global = VitermConfigFile(copySessionDataByDefault: false)
        let project = VitermConfigFile(copySessionDataByDefault: true)
        let config = VitermConfig.merge(global: global, project: project)
        #expect(config.copySessionDataByDefault == true)
    }

    @Test("pathTemplate は worktreePathTemplate から生成される")
    func pathTemplateComputedProperty() {
        let config = VitermConfig.merge(
            global: VitermConfigFile(worktreePathTemplate: "~/x/{project}"),
            project: nil
        )
        #expect(config.pathTemplate == WorktreePathTemplate("~/x/{project}"))
    }

    @Test("postCreationHook は未指定なら nil、プロジェクトが優先される")
    func postCreationHookMerge() {
        #expect(VitermConfig.merge(global: nil, project: nil).postCreationHook == nil)

        let global = VitermConfigFile(postCreationHook: "echo global")
        #expect(VitermConfig.merge(global: global, project: nil).postCreationHook == "echo global")

        let project = VitermConfigFile(postCreationHook: "echo project")
        #expect(VitermConfig.merge(global: global, project: project).postCreationHook == "echo project")
    }

    @Test("statusHooks はフィールド単位でプロジェクトがグローバルより優先される")
    func statusHooksFieldLevelMerge() {
        #expect(VitermConfig.merge(global: nil, project: nil).statusHooks == StatusHooksFile())

        let global = VitermConfigFile(statusHooks: StatusHooksFile(onBusy: "g-busy", onIdle: "g-idle"))
        let project = VitermConfigFile(statusHooks: StatusHooksFile(onBusy: "p-busy"))
        let config = VitermConfig.merge(global: global, project: project)

        // onBusy is overridden by the project; onIdle is untouched by the project so it
        // falls back to global; onWaitingInput is unspecified in both, so it stays nil.
        #expect(config.statusHooks.onBusy == "p-busy")
        #expect(config.statusHooks.onIdle == "g-idle")
        #expect(config.statusHooks.onWaitingInput == nil)
    }

    @Test("discoveryRoots はグローバル設定のみが使われ、プロジェクト側は無視される")
    func discoveryRootsUsesGlobalOnly() {
        #expect(VitermConfig.merge(global: nil, project: nil).discoveryRoots == [])

        let global = VitermConfigFile(discoveryRoots: ["~/dev", "~/work"])
        #expect(VitermConfig.merge(global: global, project: nil).discoveryRoots == ["~/dev", "~/work"])

        // Even with discoveryRoots on the project side, the global value is used as-is.
        let project = VitermConfigFile(discoveryRoots: ["~/project-only"])
        #expect(VitermConfig.merge(global: global, project: project).discoveryRoots == ["~/dev", "~/work"])
    }
}
