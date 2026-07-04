import Testing
@testable import ViteaCore

@Suite("ViteaConfig merge")
struct ViteaConfigTests {
    @Test("両方 nil の場合は既定値になる")
    func bothNilUsesDefault() {
        let config = ViteaConfig.merge(global: nil, project: nil)
        #expect(config == ViteaConfig.default)
    }

    @Test("グローバルのみ指定されたスカラー値が使われる")
    func globalOnlyScalar() {
        let global = ViteaConfigFile(worktreePathTemplate: "~/g/{project}/{branch}")
        let config = ViteaConfig.merge(global: global, project: nil)
        #expect(config.worktreePathTemplate == "~/g/{project}/{branch}")
    }

    @Test("プロジェクト側のスカラー値がグローバルより優先される")
    func projectScalarOverridesGlobal() {
        let global = ViteaConfigFile(worktreePathTemplate: "~/g/{branch}", copySessionDataByDefault: false)
        let project = ViteaConfigFile(worktreePathTemplate: "~/p/{branch}")
        let config = ViteaConfig.merge(global: global, project: project)
        #expect(config.worktreePathTemplate == "~/p/{branch}")
        // project 側が触れていないフィールドはグローバルにフォールバック
        #expect(config.copySessionDataByDefault == false)
    }

    @Test("defaultPreset はプロジェクト未指定ならグローバル値を使う")
    func defaultPresetFallsBackToGlobal() {
        let global = ViteaConfigFile(defaultPreset: "codex")
        let config = ViteaConfig.merge(global: global, project: ViteaConfigFile())
        #expect(config.defaultPreset == "codex")
    }

    @Test("presets 未指定時は組み込みの既定プリセット一覧になる")
    func presetsDefaultWhenUnspecified() {
        let config = ViteaConfig.merge(global: nil, project: nil)
        #expect(config.presets == ViteaConfig.defaultPresets)
    }

    @Test("グローバルが presets を指定しても組み込み既定プリセットは残り、新規分が末尾に追加される")
    func globalPresetsAddToDefaults() {
        let global = ViteaConfigFile(presets: [SessionPreset(name: "gemini", command: "gemini")])
        let config = ViteaConfig.merge(global: global, project: nil)
        #expect(config.presets.map(\.name) == ["claude", "codex", "shell", "gemini"])
    }

    @Test("グローバルが組み込みプリセットと同名のプリセットを指定するとその場で上書きされる(既定は消えない)")
    func globalPresetOverridesBuiltinInPlace() {
        let global = ViteaConfigFile(presets: [SessionPreset(name: "claude", command: "claude", arguments: ["--override"])])
        let config = ViteaConfig.merge(global: global, project: nil)
        #expect(config.presets.map(\.name) == ["claude", "codex", "shell"])
        #expect(config.presets.first { $0.name == "claude" }?.arguments == ["--override"])
    }

    @Test("プロジェクトは同名プリセットをその場で上書きできる(位置は保持、組み込み既定は残る)")
    func projectOverridesPresetInPlace() {
        let global = ViteaConfigFile(presets: [
            SessionPreset(name: "claude", command: "claude", arguments: ["--old"]),
            SessionPreset(name: "codex", command: "codex"),
        ])
        let project = ViteaConfigFile(presets: [
            SessionPreset(name: "claude", command: "claude", arguments: ["--new"]),
        ])
        let config = ViteaConfig.merge(global: global, project: project)
        #expect(config.presets.map(\.name) == ["claude", "codex", "shell"])
        #expect(config.presets.first { $0.name == "claude" }?.arguments == ["--new"])
    }

    @Test("プロジェクトが新規プリセットを追加すると末尾に追加される(組み込み既定は残る)")
    func projectAddsNewPreset() {
        let global = ViteaConfigFile(presets: [SessionPreset(name: "claude", command: "claude")])
        let project = ViteaConfigFile(presets: [SessionPreset(name: "gemini", command: "gemini")])
        let config = ViteaConfig.merge(global: global, project: project)
        #expect(config.presets.map(\.name) == ["claude", "codex", "shell", "gemini"])
    }

    @Test("repositories は path をキーにマージされる")
    func repositoriesMergeByPath() {
        let global = ViteaConfigFile(repositories: [
            Repository(name: "vitea", path: "/repo/vitea"),
            Repository(name: "other", path: "/repo/other"),
        ])
        let project = ViteaConfigFile(repositories: [
            Repository(name: "vitea-renamed", path: "/repo/vitea"),
        ])
        let config = ViteaConfig.merge(global: global, project: project)
        #expect(config.repositories.map(\.path) == ["/repo/vitea", "/repo/other"])
        #expect(config.repositories.first { $0.path == "/repo/vitea" }?.name == "vitea-renamed")
    }

    @Test("copySessionDataByDefault はプロジェクトが明示的に上書きできる")
    func copySessionDataOverride() {
        let global = ViteaConfigFile(copySessionDataByDefault: false)
        let project = ViteaConfigFile(copySessionDataByDefault: true)
        let config = ViteaConfig.merge(global: global, project: project)
        #expect(config.copySessionDataByDefault == true)
    }

    @Test("pathTemplate は worktreePathTemplate から生成される")
    func pathTemplateComputedProperty() {
        let config = ViteaConfig.merge(
            global: ViteaConfigFile(worktreePathTemplate: "~/x/{project}"),
            project: nil
        )
        #expect(config.pathTemplate == WorktreePathTemplate("~/x/{project}"))
    }

    @Test("postCreationHook は未指定なら nil、プロジェクトが優先される")
    func postCreationHookMerge() {
        #expect(ViteaConfig.merge(global: nil, project: nil).postCreationHook == nil)

        let global = ViteaConfigFile(postCreationHook: "echo global")
        #expect(ViteaConfig.merge(global: global, project: nil).postCreationHook == "echo global")

        let project = ViteaConfigFile(postCreationHook: "echo project")
        #expect(ViteaConfig.merge(global: global, project: project).postCreationHook == "echo project")
    }

    @Test("statusHooks はフィールド単位でプロジェクトがグローバルより優先される")
    func statusHooksFieldLevelMerge() {
        #expect(ViteaConfig.merge(global: nil, project: nil).statusHooks == StatusHooksFile())

        let global = ViteaConfigFile(statusHooks: StatusHooksFile(onBusy: "g-busy", onIdle: "g-idle"))
        let project = ViteaConfigFile(statusHooks: StatusHooksFile(onBusy: "p-busy"))
        let config = ViteaConfig.merge(global: global, project: project)

        // onBusy はプロジェクトが上書き、onIdle はプロジェクトが触れていないのでグローバルにフォールバック、
        // onWaitingInput はどちらも未指定なので nil のまま。
        #expect(config.statusHooks.onBusy == "p-busy")
        #expect(config.statusHooks.onIdle == "g-idle")
        #expect(config.statusHooks.onWaitingInput == nil)
    }

    @Test("discoveryRoots はグローバル設定のみが使われ、プロジェクト側は無視される")
    func discoveryRootsUsesGlobalOnly() {
        #expect(ViteaConfig.merge(global: nil, project: nil).discoveryRoots == [])

        let global = ViteaConfigFile(discoveryRoots: ["~/dev", "~/work"])
        #expect(ViteaConfig.merge(global: global, project: nil).discoveryRoots == ["~/dev", "~/work"])

        // プロジェクト側に discoveryRoots があってもグローバルの値がそのまま使われる。
        let project = ViteaConfigFile(discoveryRoots: ["~/project-only"])
        #expect(ViteaConfig.merge(global: global, project: project).discoveryRoots == ["~/dev", "~/work"])
    }
}
