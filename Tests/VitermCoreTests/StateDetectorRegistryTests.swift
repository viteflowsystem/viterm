import Testing
@testable import VitermCore

@Suite("StateDetectorRegistry")
struct StateDetectorRegistryTests {
    @Test("claude/codex は専用detector、その他は汎用シェルにフォールバック")
    func resolvesKnownToolsAndFallsBack() {
        #expect(StateDetectorRegistry.detector(forToolName: "claude") is ClaudeStateDetector)
        #expect(StateDetectorRegistry.detector(forToolName: "Claude") is ClaudeStateDetector)
        #expect(StateDetectorRegistry.detector(forToolName: "codex") is CodexStateDetector)

        let fallback = StateDetectorRegistry.detector(forToolName: "gemini")
        #expect(fallback is GenericShellStateDetector)
        #expect(fallback.toolName == "gemini")
    }
}
