import Testing
@testable import ViteaCore

@Suite("GenericShellStateDetector")
struct GenericShellStateDetectorTests {
    let detector = GenericShellStateDetector()

    @Test("プロンプト記号で終わる行はnone(idle候補)")
    func promptSuffixesAreNone() {
        for suffix in ["$", "%", "#", ">", "❯"] {
            let signal = detector.detect(screenLines: ["user@host:~/repo\(suffix)"])
            #expect(signal == .none, "suffix \(suffix) should be idle candidate")
        }
    }

    @Test("プロンプト以外の出力行はbusy")
    func nonPromptLineIsBusy() {
        let signal = detector.detect(screenLines: ["user@host:~/repo$ ", "Running tests...", "42 passed"])
        #expect(signal == .busy)
    }

    @Test("空行は無視して最後の非空行を見る")
    func trailingBlankLinesAreIgnored() {
        let signal = detector.detect(screenLines: ["user@host:~/repo$ ls", "file1 file2", "", "   "])
        #expect(signal == .busy)
    }

    @Test("画面が全て空ならnone")
    func emptyScreenIsNone() {
        #expect(detector.detect(screenLines: ["", "  "]) == .none)
        #expect(detector.detect(screenLines: []) == .none)
    }

    @Test("toolName はカスタマイズ可能で既定値はshell")
    func customToolName() {
        #expect(GenericShellStateDetector().toolName == "shell")
        #expect(GenericShellStateDetector(toolName: "bash").toolName == "bash")
    }
}
