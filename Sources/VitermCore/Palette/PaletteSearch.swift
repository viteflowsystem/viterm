import Foundation

/// Filters and ranks the `PaletteCommand` list by a query.
public enum PaletteSearch {
    /// Excludes commands not matching `query` and returns them sorted by score, descending.
    /// Ties are broken by a stable sort preserving the original array order (= display order returned by the provider).
    /// If `query` is an empty string, returns the original order without filtering or sorting.
    public static func search(_ commands: [PaletteCommand], query: String) -> [PaletteCommand] {
        guard !query.isEmpty else { return commands }

        let scored = commands.enumerated().compactMap { offset, command -> (offset: Int, command: PaletteCommand, score: Int)? in
            guard let score = FuzzyMatcher.score(query: query, target: command.searchableText) else { return nil }
            return (offset, command, score)
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.offset < rhs.offset
            }
            .map(\.command)
    }
}
