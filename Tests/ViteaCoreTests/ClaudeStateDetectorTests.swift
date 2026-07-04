import Testing
@testable import ViteaCore

@Suite("ClaudeStateDetector")
struct ClaudeStateDetectorTests {
    let detector = ClaudeStateDetector()

    @Test("スピナー+ing表現でbusy")
    func spinnerWithIngIsBusy() {
        let signal = detector.detect(screenLines: ["✻ Thinking… (offline)"])
        #expect(signal == .busy)
    }

    @Test("esc to interrupt でbusy")
    func escToInterruptIsBusy() {
        let signal = detector.detect(screenLines: ["some header", "esc to interrupt"])
        #expect(signal == .busy)
    }

    @Test("ctrl+c to interrupt でもbusy")
    func ctrlCToInterruptIsBusy() {
        let signal = detector.detect(screenLines: ["press ctrl+c to interrupt"])
        #expect(signal == .busy)
    }

    @Test("トークン統計行でbusy")
    func tokenStatsLineIsBusy() {
        let signal = detector.detect(screenLines: ["(2m 14s · ↓ 4.2k tokens)"])
        #expect(signal == .busy)
    }

    @Test("Do you want の確認プロンプトでwaitingInput")
    func doYouWantIsWaitingInput() {
        let signal = detector.detect(screenLines: [
            "Do you want to make this edit?",
            "❯ 1. Yes",
            "  2. No",
        ])
        #expect(signal == .waitingInput)
    }

    @Test("Would you like でもwaitingInput")
    func wouldYouLikeIsWaitingInput() {
        let signal = detector.detect(screenLines: ["Would you like to continue?"])
        #expect(signal == .waitingInput)
    }

    @Test("esc to cancel でwaitingInput")
    func escToCancelIsWaitingInput() {
        let signal = detector.detect(screenLines: ["esc to cancel"])
        #expect(signal == .waitingInput)
    }

    @Test("busyのシグナルとwaitingInputのシグナルが同時にある場合はwaitingInputを優先")
    func waitingInputTakesPriorityOverBusy() {
        let signal = detector.detect(screenLines: [
            "(2m 14s · ↓ 4.2k tokens)",
            "Do you want to proceed?",
        ])
        #expect(signal == .waitingInput)
    }

    @Test("明確なシグナルが無ければnone")
    func plainPromptIsNone() {
        let signal = detector.detect(screenLines: ["> ", "some previous output"])
        #expect(signal == .none)
    }

    @Test("空の画面はnone")
    func emptyScreenIsNone() {
        #expect(detector.detect(screenLines: []) == .none)
    }

    @Test("toolName は claude")
    func toolNameIsClaude() {
        #expect(detector.toolName == "claude")
    }
}
