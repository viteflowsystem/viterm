import Foundation

/// Detector for Claude Code.
/// The detection signals are ported from ccmanager's (kbwo/ccmanager)
/// `src/services/stateDetector/claude.ts` (main branch as of 2026-07) as the starting
/// point. ccmanager has prior form here: this kind of detection was once completely
/// broken by a Claude Code UI change (Issue #227), and the post-fix implementation is
/// currently the most battle-tested pattern set available.
///
/// - waitingInput (checked before busy):
///   - A confirmation prompt where `Do you want` / `Would you like` is followed, after a
///     newline, by options (`yes` / `❯`). Judging by the wording alone could false-match
///     phrasing inside a normal response, so the presence of options is also required.
///   - `esc to cancel`
/// - busy:
///   - `esc to interrupt` / `ctrl+c to interrupt` / `ctrl-c to interrupt`
///   - A line of spinner char + a word (containing `…ing`) ending with an ellipsis (`…`)
///     (e.g. `✽ Tempering…`, `✳ Simplifying recompute_tangents… (2m 18s · ↓ 4.8k tokens)`).
///     Lines starting with a spinner char but not ending in `…ing` (e.g. `✽ Some random text`) don't count.
///   - A stats line with digits and `tokens` inside parentheses (e.g. `(2m 14s · ↓ 4.2k tokens)`, `(50s · ↓ 794 tokens)`)
/// - `⌕ Search…` (the search prompt) returns `.none` (the idle-debounce side) with priority over every other signal.
/// - `ctrl+r to toggle` (the transcript-toggle hint) returns `.none`. Upstream ccmanager
///   keeps the previous state in this case, but `StateDetector` is stateless by design,
///   so we approximate with `.none` here. Thanks to `SessionStateMachine`'s idle debounce
///   (default 1.5s), there is no real harm if a busy/waitingInput signal is re-detected
///   on the next tick.
///
/// ccmanager's "only consider text above the prompt box (`─` rule) for busy detection"
/// logic addresses stale redraw fragments from the previous turn lingering in the xterm
/// buffer; libghostty's `ghostty_surface_read_text` (returns the current viewport as-is;
/// see `docs/ghostty-integration.md`) has no such problem, so it was not ported.
public struct ClaudeStateDetector: StateDetector {
    public let toolName = "claude"

    public init() {}

    public func detect(screenLines: [String]) -> DetectionSignal {
        let content = screenLines.joined(separator: "\n")

        // The search prompt returns the idle side (none) with priority over every other signal.
        if content.contains("⌕ Search…") {
            return .none
        }

        let lowerContent = content.lowercased()

        if lowerContent.contains("ctrl+r to toggle") {
            return .none
        }

        if Self.matchesWaitingInput(content, lowerContent: lowerContent) {
            return .waitingInput
        }
        if Self.matchesBusy(content, lowerContent: lowerContent) {
            return .busy
        }
        return .none
    }

    static func matchesWaitingInput(_ content: String, lowerContent: String) -> Bool {
        if lowerContent.contains("esc to cancel") {
            return true
        }
        return TextSignals.matchesRegex(
            lowerContent,
            pattern: #"(?:do you want|would you like)[\s\S]+?\n+[\s\S]*?(?:yes|❯)"#
        )
    }

    static func matchesBusy(_ content: String, lowerContent: String) -> Bool {
        if TextSignals.containsAny(lowerContent, of: ["esc to interrupt", "ctrl+c to interrupt", "ctrl-c to interrupt"]) {
            return true
        }
        if TextSignals.matchesRegex(content, pattern: spinnerActivityPattern) {
            return true
        }
        return TextSignals.matchesRegex(lowerContent, pattern: #"\([^)]*\d[^)]*tokens\s*\)"#)
    }

    /// Line-leading spinner char + a space + a word ending in `…ing` + an ellipsis (`…`).
    private static let spinnerActivityPattern =
        "(?m)^[" + String(TextSignals.spinnerCharacters) + "] \\S+ing.*…"
}
