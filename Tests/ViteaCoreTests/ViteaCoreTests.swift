import Testing
@testable import ViteaCore

// スモークテスト。詳細なテストは WorktreePathTemplateTests / ViteaConfigTests /
// ConfigLoaderTests / ModelsTests を参照。
@Test func scaffoldBuilds() {
    #expect(ViteaConfig.default.defaultPreset == "shell")
}
