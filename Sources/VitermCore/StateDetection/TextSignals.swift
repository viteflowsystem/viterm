import Foundation

/// Small text-pattern-matching helpers shared between detector implementations.
enum TextSignals {
    /// Spinner/decoration characters that CLIs like Claude Code / Codex use to express
    /// "working". The braille spinners (⠋⠙…) are the original set aimed at Codex and
    /// friends. The floral/geometric symbols (✱✲…○●) are ported from the battle-tested
    /// set in ccmanager's (kbwo/ccmanager) claude.ts (main as of 2026-07).
    static let spinnerCharacters: Set<Character> = Set(
        "⠋⠙⠸⠼⠴⠦⠧⠇⠏⠹"
            + "✱✲✳✴✵✶✷✸✹✺✻✼✽✾✿❀❁❂❃❇❈❉❊❋✢✣✤✥✦✧✨⊛⊕⊙◉◎◍⁂⁕※⍟☼★☆·•⏺▸▹∙⋅○●"
    )

    /// Whether any of the substrings is contained, case-insensitively.
    static func containsAny(_ line: String, of needles: [String]) -> Bool {
        let lower = line.lowercased()
        return needles.contains { lower.contains($0) }
    }

    /// Regular-expression (ICU) match check.
    static func matchesRegex(_ line: String, pattern: String) -> Bool {
        line.range(of: pattern, options: .regularExpression) != nil
    }

    /// Whether the line (ignoring surrounding whitespace) starts with a spinner character.
    static func startsWithSpinner(_ line: String) -> Bool {
        guard let first = line.trimmingCharacters(in: .whitespaces).first else { return false }
        return spinnerCharacters.contains(first)
    }
}
