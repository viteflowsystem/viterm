import Testing
@testable import VitermCore

// Smoke test. For detailed tests see WorktreePathTemplateTests / VitermConfigTests /
// ConfigLoaderTests / ModelsTests.
@Test func scaffoldBuilds() {
    #expect(VitermConfig.default.defaultPreset == "shell")
}
