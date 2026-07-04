import Foundation

/// Codex CLI 向けの detector。
/// Claude ほど仕様が固まっていないため、同種のCLI(スピナー付き進捗表示・
/// y/n 形式のコマンド実行確認)に共通しやすいシグナルで暫定実装している。
/// 実際の画面出力での検証は T13b(統合)側で行い、必要に応じてここを調整する想定。
public struct CodexStateDetector: StateDetector {
    public let toolName = "codex"

    public init() {}

    public func detect(screenLines: [String]) -> DetectionSignal {
        for line in screenLines.reversed() where Self.matchesWaitingInput(line) {
            return .waitingInput
        }
        for line in screenLines.reversed() where Self.matchesBusy(line) {
            return .busy
        }
        return .none
    }

    static func matchesWaitingInput(_ line: String) -> Bool {
        TextSignals.containsAny(line, of: [
            "do you want", "would you like", "allow command", "proceed?",
            "(y/n)", "[y/n]", "press enter to",
        ])
    }

    static func matchesBusy(_ line: String) -> Bool {
        if TextSignals.containsAny(line, of: ["esc to interrupt", "ctrl+c to interrupt", "ctrl-c to interrupt"]) {
            return true
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if TextSignals.startsWithSpinner(trimmed), trimmed.lowercased().contains("ing") {
            return true
        }
        return false
    }
}
