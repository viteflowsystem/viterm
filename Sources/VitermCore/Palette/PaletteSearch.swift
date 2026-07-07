import Foundation

/// Filters and ranks the `PaletteCommand` list by a query.
public enum PaletteSearch {
    /// Exclude commands that don't match `query` and return the rest sorted by score
    /// descending. A stable sort: ties keep the original array order (= the display order
    /// the provider returned). An empty `query` returns the original order with no
    /// filtering or sorting.
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
