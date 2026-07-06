import Foundation

/// Detector for Claude Code.
/// The detection signals are ported from ccmanager (kbwo/ccmanager)'s
/// `src/services/stateDetector/claude.ts` (main branch as of 2026-07) as a starting point.
/// ccmanager has a prior incident (Issue #227) where this kind of detection was completely
/// broken once by a Claude Code UI change, and the post-fix implementation is currently
/// the most battle-tested pattern set available.
///
/// - waitingInput (checked before busy):
///   - A confirmation prompt where `Do you want` / `Would you like` is followed, after a
///     newline, by options (`yes` / `❯`). Deciding on the phrase alone could false-positive
///     on those phrasings appearing in normal response text, so the presence of options is required.
///   - `esc to cancel`
/// - busy:
///   - `esc to interrupt` / `ctrl+c to interrupt` / `ctrl-c to interrupt`
///   - A line consisting of a spinner character + a word (containing `…ing`) + a trailing
///     ellipsis (`…`)
///     (e.g. `✽ Tempering…`, `✳ Simplifying recompute_tangents… (2m 18s · ↓ 4.8k tokens)`).
///     Lines that start with a spinner character but do not end with `…ing` (e.g. `✽ Some random text`) are excluded.
///   - A stats line with digits and `tokens` inside parentheses (e.g. `(2m 14s · ↓ 4.2k tokens)`, `(50s · ↓ 794 tokens)`)
/// - `⌕ Search…` (the search prompt) returns `.none` (the idle-debounce side) with priority over every other signal.
/// - `ctrl+r to toggle` (the transcript-view toggle hint) returns `.none`. Upstream ccmanager
///   keeps the previous state in this case, but since `StateDetector` is designed to be
///   stateless we approximate it with `.none` here. Thanks to `SessionStateMachine`'s idle
///   debounce (default 1.5s), there is no practical harm if a busy/waitingInput signal is
///   re-detected on the next tick.
///
/// ccmanager's logic of "only consider content above the prompt box (`─` rule line) for busy
/// detection" is a workaround for stale redraw fragments from the previous turn lingering in
/// the xterm buffer; libghostty's `ghostty_surface_read_text` (returns the current viewport
/// as-is; see `docs/ghostty-integration.md` for details) has no such problem, so it was not ported.
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

    /// Spinner character at line start + a space + a word ending in "…ing" + trailing ellipsis (`…`).
    private static let spinnerActivityPattern =
        "(?m)^[" + String(TextSignals.spinnerCharacters) + "] \\S+ing.*…"
}
