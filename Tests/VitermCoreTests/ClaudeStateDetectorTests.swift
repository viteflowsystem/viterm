import Testing
@testable import VitermCore

/// Fixtures are screen samples from ccmanager (kbwo/ccmanager)'s `src/services/stateDetector/claude.test.ts`
/// (main branch as of 2026-07), restructured for viterm's `StateDetector`
/// (stateless, no previous-state input).
@Suite("ClaudeStateDetector")
struct ClaudeStateDetectorTests {
    let detector = ClaudeStateDetector()

    // MARK: - busy: esc to interrupt / ctrl+c to interrupt

    @Test("esc to interrupt でbusy")
    func escToInterruptIsBusy() {
        let signal = detector.detect(screenLines: ["Processing...", "Press ESC to interrupt"])
        #expect(signal == .busy)
    }

    @Test("ctrl+c to interrupt でもbusy")
    func ctrlCToInterruptIsBusy() {
        let signal = detector.detect(screenLines: ["press ctrl+c to interrupt"])
        #expect(signal == .busy)
    }

    @Test("閉じ括弧の無い ctrl+c to interrupt でもbusy")
    func unclosedParenCtrlCToInterruptIsBusy() {
        // ccmanager fixture: "Googling. (ctrl+c to interrupt"
        let signal = detector.detect(screenLines: [
            "Googling. (ctrl+c to interrupt",
            "Searching for relevant information...",
        ])
        #expect(signal == .busy)
    }

    // MARK: - busy: spinner activity label (`…ing…`)

    @Test("スピナー+ing+三点リーダーでbusy(✽ Tempering…)")
    func spinnerActivityLabelIsBusy() {
        let signal = detector.detect(screenLines: ["✽ Tempering…"])
        #expect(signal == .busy)
    }

    @Test("スピナー活動ラベル+トークン統計が同じ行にあってもbusy")
    func spinnerActivityLabelWithInlineTokenStatsIsBusy() {
        let signal = detector.detect(screenLines: [
            "✳ Simplifying recompute_tangents… (2m 18s · ↓ 4.8k tokens)",
            "  ⎿  ◻ task list items...",
        ])
        #expect(signal == .busy)
    }

    @Test("中黒(·)スピナーでもbusy(· Misting…)")
    func middleDotSpinnerIsBusy() {
        let signal = detector.detect(screenLines: [
            "· Misting…",
            "   ⎿  Tip: Run /terminal-setup to enable convenient terminal integration",
        ])
        #expect(signal == .busy)
    }

    @Test(
        "ccmanagerで実戦検証済みの各スピナー文字でbusy",
        arguments: ["✱", "✲", "✳", "✴", "✵", "✶", "✷", "✸", "✹", "✺", "✻", "✼", "✽", "✾", "✿",
                    "❀", "❁", "❂", "❃", "❇", "❈", "❉", "❊", "❋", "✢", "✣", "✤", "✥", "✦", "✧"]
    )
    func variousSpinnerCharactersAreBusy(char: String) {
        let signal = detector.detect(screenLines: ["\(char) Kneading…"])
        #expect(signal == .busy, "spinner char \(char) should be detected as busy")
    }

    @Test("スピナー文字で始まってもing+三点リーダーが無ければbusyにならない")
    func spinnerWithoutIngSuffixIsNotBusy() {
        let signal = detector.detect(screenLines: ["✽ Some random text"])
        #expect(signal == .none)
    }

    // MARK: - busy: token stats line

    @Test("トークン統計行(分+秒)でbusy")
    func tokenStatsLineWithMinutesIsBusy() {
        let signal = detector.detect(screenLines: ["(2m 14s · ↓ 4.2k tokens)"])
        #expect(signal == .busy)
    }

    @Test("トークン統計行(秒のみ)でもbusy")
    func tokenStatsLineWithSecondsOnlyIsBusy() {
        // ccmanager fixture: "(50s · ↓ 794 tokens)" — verifies we don't depend on the time notation format.
        let signal = detector.detect(screenLines: ["(50s · ↓ 794 tokens)"])
        #expect(signal == .busy)
    }

    // MARK: - waitingInput: confirmation prompt (with options)

    @Test("Do you want + 番号付き選択肢でwaitingInput")
    func doYouWantWithNumberedOptionsIsWaitingInput() {
        let signal = detector.detect(screenLines: [
            "Some previous output",
            "Do you want to make this edit to test.txt?",
            "❯ 1. Yes",
            "2. Yes, allow all edits during this session (shift+tab)",
            "3. No, and tell Claude what to do differently (esc)",
        ])
        #expect(signal == .waitingInput)
    }

    @Test("大文字小文字が混在していてもwaitingInput")
    func caseInsensitiveDoYouWantIsWaitingInput() {
        let signal = detector.detect(screenLines: [
            "Some output",
            "DO YOU WANT to make this edit?",
            "❯ 1. YES",
            "2. NO",
        ])
        #expect(signal == .waitingInput)
    }

    @Test("Would you like + 空行を挟んだ選択肢でもwaitingInput")
    func wouldYouLikeWithBlankLineBeforeOptionsIsWaitingInput() {
        let signal = detector.detect(screenLines: [
            "Some previous output",
            "Would you like to proceed?",
            "",
            "❯ 1. Yes, and auto-accept edits",
            "  2. Yes, and manually approve edits",
            "  3. No, keep planning",
        ])
        #expect(signal == .waitingInput)
    }

    @Test("esc to cancel でwaitingInput")
    func escToCancelIsWaitingInput() {
        let signal = detector.detect(screenLines: ["Enter your message:", "Press esc to cancel"])
        #expect(signal == .waitingInput)
    }

    @Test("busyのシグナルとwaitingInputのシグナルが同時にある場合はwaitingInputを優先")
    func waitingInputTakesPriorityOverBusy() {
        let signal = detector.detect(screenLines: [
            "(2m 14s · ↓ 4.2k tokens)",
            "Do you want to proceed?",
            "❯ 1. Yes",
        ])
        #expect(signal == .waitingInput)
    }

    @Test("esc to cancel が esc to interrupt より優先される")
    func escToCancelTakesPriorityOverEscToInterrupt() {
        let signal = detector.detect(screenLines: [
            "Press esc to interrupt",
            "Some input prompt",
            "Press esc to cancel",
        ])
        #expect(signal == .waitingInput)
    }

    // MARK: - waitingInput: confirmation "phrasing" alone, without options, must not trigger a false positive

    @Test("Do you want / Would you like だけで選択肢が無ければwaitingInputにならない")
    func doYouWantWithoutOptionsIsNotWaitingInput() {
        // Lesson from ccmanager Issue #227: deciding on phrasing alone can misdetect wording inside normal response text.
        let signal = detector.detect(screenLines: ["Would you like to continue?"])
        #expect(signal == .none)
    }

    // MARK: - search prompt (⌕ Search…) takes top priority and counts as idle (none)

    @Test("検索プロンプトはスピナー活動ラベルより優先してnone")
    func searchPromptTakesPriorityOverSpinnerActivity() {
        let signal = detector.detect(screenLines: ["⌕ Search…", "✽ Tempering…"])
        #expect(signal == .none)
    }

    @Test("検索プロンプトはesc to cancelより優先してnone")
    func searchPromptTakesPriorityOverEscToCancel() {
        let signal = detector.detect(screenLines: ["⌕ Search…", "esc to cancel"])
        #expect(signal == .none)
    }

    @Test("検索プロンプトはesc to interruptより優先してnone")
    func searchPromptTakesPriorityOverEscToInterrupt() {
        let signal = detector.detect(screenLines: ["⌕ Search…", "Press esc to interrupt"])
        #expect(signal == .none)
    }

    // MARK: - ctrl+r to toggle (does not change state → approximated as none)

    @Test("ctrl+r to toggle はnone(状態を変化させない近似)")
    func ctrlRToToggleIsNone() {
        let signal = detector.detect(screenLines: [
            "Some output",
            "Press Ctrl+R to toggle history search",
            "More output",
        ])
        #expect(signal == .none)
    }

    // MARK: - none

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
