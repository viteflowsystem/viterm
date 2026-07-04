import Foundation

/// Claude Code 向けの detector。
/// 判定シグナルは docs/research.md の ccmanager 節を出発点にしている:
/// - busy: スピナー文字+「〜ing」、`esc to interrupt` / `ctrl+c to interrupt`、
///   トークン統計行(例: `(2m 14s · ↓ 4.2k tokens)`)
/// - waitingInput: `Do you want` / `Would you like` の確認プロンプト、`esc to cancel`
/// waitingInput はより明確な根拠(明示的な確認待ち文言)を持つため busy より優先して判定する。
public struct ClaudeStateDetector: StateDetector {
    public let toolName = "claude"

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
        TextSignals.containsAny(line, of: ["do you want", "would you like", "esc to cancel"])
    }

    static func matchesBusy(_ line: String) -> Bool {
        if TextSignals.containsAny(line, of: ["esc to interrupt", "ctrl+c to interrupt", "ctrl-c to interrupt"]) {
            return true
        }
        if line.lowercased().contains("token"), TextSignals.matchesRegex(line, pattern: #"\d+\s*[ms]\b"#) {
            return true
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if TextSignals.startsWithSpinner(trimmed), trimmed.lowercased().contains("ing") {
            return true
        }
        return false
    }
}
