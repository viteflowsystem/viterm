import Testing
@testable import VitermCore

// スモークテスト。詳細なテストは WorktreePathTemplateTests / VitermConfigTests /
// ConfigLoaderTests / ModelsTests を参照。
@Test func scaffoldBuilds() {
    #expect(VitermConfig.default.defaultPreset == "shell")
}
