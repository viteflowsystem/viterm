import Testing
@testable import VitermCore

// Smoke tests. See WorktreePathTemplateTests / VitermConfigTests / ConfigLoaderTests /
// ModelsTests for the detailed tests.
@Test func scaffoldBuilds() {
    #expect(VitermConfig.default.defaultPreset == "shell")
}
