import Foundation

/// Detector for a plain shell (zsh/bash, etc.).
/// Unlike agent CLIs, arbitrary commands don't declare their state in screen text, so
/// "waiting for confirmation" (waitingInput) can't be detected in a general way.
/// Instead we only check whether the bottom line of the screen ends with a
/// shell-prompt-like symbol: if it ends with a prompt, `.none` (= no command running =
/// idle candidate); otherwise a running command is assumed to be producing output → `.busy`.
public struct GenericShellStateDetector: StateDetector {
    public let toolName: String

    public init(toolName: String = "shell") {
        self.toolName = toolName
    }

    public func detect(screenLines: [String]) -> DetectionSignal {
        guard let lastLine = screenLines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return .none
        }
        return Self.looksLikePrompt(lastLine) ? .none : .busy
    }

    static let promptSuffixes: Set<Character> = ["$", "%", "#", ">", "❯"]

    static func looksLikePrompt(_ line: String) -> Bool {
        guard let last = line.trimmingCharacters(in: .whitespaces).last else { return false }
        return promptSuffixes.contains(last)
    }
}
