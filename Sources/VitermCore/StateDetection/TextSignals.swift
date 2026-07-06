import Foundation

/// Small collection of text-pattern-matching helpers shared across detector implementations.
enum TextSignals {
    /// Spinner/decoration symbols that CLIs such as Claude Code / Codex use to indicate "working".
    /// The braille spinners (⠋⠙…) are the original set for Codex and the like. The asterisk/geometric
    /// symbols (✱✲…○●) are ported from the battle-tested set in ccmanager (kbwo/ccmanager)'s claude.ts (main as of 2026-07).
    static let spinnerCharacters: Set<Character> = Set(
        "⠋⠙⠸⠼⠴⠦⠧⠇⠏⠹"
            + "✱✲✳✴✵✶✷✸✹✺✻✼✽✾✿❀❁❂❃❇❈❉❊❋✢✣✤✥✦✧✨⊛⊕⊙◉◎◍⁂⁕※⍟☼★☆·•⏺▸▹∙⋅○●"
    )

    /// Whether the line contains any of the substrings, case-insensitively.
    static func containsAny(_ line: String, of needles: [String]) -> Bool {
        let lower = line.lowercased()
        return needles.contains { lower.contains($0) }
    }

    /// Regular-expression (ICU) match check.
    static func matchesRegex(_ line: String, pattern: String) -> Bool {
        line.range(of: pattern, options: .regularExpression) != nil
    }

    /// Whether the line starts (ignoring surrounding whitespace) with a spinner character.
    static func startsWithSpinner(_ line: String) -> Bool {
        guard let first = line.trimmingCharacters(in: .whitespaces).first else { return false }
        return spinnerCharacters.contains(first)
    }
}
