import Foundation

/// `PaletteCommand` 一覧をクエリで絞り込み・ランキングする。
public enum PaletteSearch {
    /// `query` でマッチしないコマンドを除外し、スコア降順で並び替えて返す。
    /// 同点の場合は元の配列順(= プロバイダが返した表示順)を保つ安定ソート。
    /// `query` が空文字列の場合は絞り込み・並び替えを行わず元の順序のまま返す。
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
