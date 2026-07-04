import Testing
@testable import ViteaCore

@Suite("CodexStateDetector")
struct CodexStateDetectorTests {
    let detector = CodexStateDetector()

    @Test("esc to interrupt でbusy")
    func escToInterruptIsBusy() {
        #expect(detector.detect(screenLines: ["esc to interrupt"]) == .busy)
    }

    @Test("スピナー+ing表現でbusy")
    func spinnerWithIngIsBusy() {
        #expect(detector.detect(screenLines: ["⠋ Generating…"]) == .busy)
    }

    @Test("コマンド実行確認でwaitingInput")
    func allowCommandIsWaitingInput() {
        #expect(detector.detect(screenLines: ["Allow command `rm -rf tmp` to run?", "(y/n)"]) == .waitingInput)
    }

    @Test("[y/n] 形式のプロンプトでwaitingInput")
    func yesNoBracketIsWaitingInput() {
        #expect(detector.detect(screenLines: ["Proceed? [y/n]"]) == .waitingInput)
    }

    @Test("明確なシグナルが無ければnone")
    func plainOutputIsNone() {
        #expect(detector.detect(screenLines: ["build succeeded"]) == .none)
    }

    @Test("toolName は codex")
    func toolNameIsCodex() {
        #expect(detector.toolName == "codex")
    }
}
