import Foundation

/// Fuzzy-search algorithm for the command palette.
/// A match means each character of the query appears in the target string as a
/// (not necessarily contiguous) subsequence, scored on these criteria (higher = ranked higher):
/// - Prefix match: the first query character matched at the start of the target string
/// - Word boundary: the position just before the match is a separator (whitespace, symbols, etc.) or the string start
/// - Consecutive match: matched immediately after the previous match position (matched as a contiguous substring)
///
/// Case-insensitive. Non-ASCII characters such as Japanese are treated as ordinary
/// characters and participate in substring matching without special handling.
public enum FuzzyMatcher {
    /// Determines whether `query` fuzzy-matches `target`, returning the score if it does.
    /// Returns `nil` on no match. An empty query always matches (with score 0).
    public static func score(query: String, target: String) -> Int? {
        guard !query.isEmpty else { return 0 }

        let queryChars = Array(query.lowercased())
        let targetChars = Array(target.lowercased())
        guard !targetChars.isEmpty else { return nil }

        var score = 0
        var searchFrom = 0
        var previousMatchIndex: Int?

        for (queryIndex, queryChar) in queryChars.enumerated() {
            guard let matchIndex = firstIndex(of: queryChar, in: targetChars, from: searchFrom) else {
                return nil
            }

            if queryIndex == 0, matchIndex == 0 {
                score += 100
            }
            if isWordBoundary(before: matchIndex, in: targetChars) {
                score += 10
            }
            if let previous = previousMatchIndex, matchIndex == previous + 1 {
                score += 5
            } else {
                score += 1
            }

            previousMatchIndex = matchIndex
            searchFrom = matchIndex + 1
        }

        return score
    }

    private static func firstIndex(of char: Character, in chars: [Character], from startIndex: Int) -> Int? {
        var index = startIndex
        while index < chars.count {
            if chars[index] == char { return index }
            index += 1
        }
        return nil
    }

    /// Separator characters treated as word boundaries. Besides ASCII whitespace and symbols,
    /// this includes Japanese commas, periods, and the like.
    private static let boundarySeparators: Set<Character> = [
        " ", "\t", "-", "_", "/", "(", ")", "…", ":", "・", "、", "。", "「", "」",
    ]

    private static func isWordBoundary(before index: Int, in chars: [Character]) -> Bool {
        guard index > 0 else { return true }
        return boundarySeparators.contains(chars[index - 1])
    }
}
