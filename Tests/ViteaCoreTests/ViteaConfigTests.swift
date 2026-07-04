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

    @Test("グローバルが presets を指定すると既定プリセットは使われず置き換わる")
    func globalPresetsReplaceDefaults() {
        let global = ViteaConfigFile(presets: [SessionPreset(name: "gemini", command: "gemini")])
        let config = ViteaConfig.merge(global: global, project: nil)
        #expect(config.presets == [SessionPreset(name: "gemini", command: "gemini")])
    }

    @Test("プロジェクトは同名プリセットをその場で上書きできる(位置は保持)")
    func projectOverridesPresetInPlace() {
        let global = ViteaConfigFile(presets: [
            SessionPreset(name: "claude", command: "claude", arguments: ["--old"]),
            SessionPreset(name: "codex", command: "codex"),
        ])
        let project = ViteaConfigFile(presets: [
            SessionPreset(name: "claude", command: "claude", arguments: ["--new"]),
        ])
        let config = ViteaConfig.merge(global: global, project: project)
        #expect(config.presets.map(\.name) == ["claude", "codex"])
        #expect(config.presets.first { $0.name == "claude" }?.arguments == ["--new"])
    }

    @Test("プロジェクトが新規プリセットを追加すると末尾に追加される")
    func projectAddsNewPreset() {
        let global = ViteaConfigFile(presets: [SessionPreset(name: "claude", command: "claude")])
        let project = ViteaConfigFile(presets: [SessionPreset(name: "gemini", command: "gemini")])
        let config = ViteaConfig.merge(global: global, project: project)
        #expect(config.presets.map(\.name) == ["claude", "gemini"])
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
}
