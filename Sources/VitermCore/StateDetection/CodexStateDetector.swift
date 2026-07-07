import Foundation

/// Detector for the Codex CLI.
/// Its behavior is less settled than Claude's, so this is a provisional implementation
/// using signals common to similar CLIs (spinner-style progress display, y/n command
/// confirmation). Verification against real screen output happens in T13b (integration),
/// with adjustments here as needed.
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
