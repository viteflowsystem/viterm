import Foundation

/// Fuzzy search algorithm for the command palette.
/// A match means every query character appears in the target string as a (not
/// necessarily contiguous) subsequence, scored on these criteria (higher ranks first):
/// - Prefix match: the first query character matched at the start of the target
/// - Word boundary: the position right before a match is a separator (space, symbol, etc.) or the string start
/// - Consecutive match: matched immediately after the previous match position (matched as a contiguous substring)
///
/// Case-insensitive. Non-ASCII characters such as Japanese are treated as ordinary
/// characters and participate in matching without any special handling.
public enum FuzzyMatcher {
    /// Determine whether `query` fuzzy-matches `target`, returning the score if it does.
    /// `nil` if it doesn't. An empty query always matches (with score 0).
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

    /// Separators treated as word boundaries. ASCII whitespace/symbols plus Japanese commas, periods, etc.
    private static let boundarySeparators: Set<Character> = [
        " ", "\t", "-", "_", "/", "(", ")", "…", ":", "・", "、", "。", "「", "」",
    ]

    private static func isWordBoundary(before index: Int, in chars: [Character]) -> Bool {
        guard index > 0 else { return true }
        return boundarySeparators.contains(chars[index - 1])
    }
}
