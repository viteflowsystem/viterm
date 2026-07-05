import Foundation

/// コマンドパレットのファジー検索アルゴリズム。
/// クエリの各文字が対象文字列に(連続していなくてもよい)部分列として現れればマッチとみなし、
/// 以下の観点でスコアリングする(値が大きいほど上位表示):
/// - 先頭一致: クエリの最初の文字が対象文字列の先頭にマッチした
/// - 単語境界: マッチ位置の直前が区切り文字(空白・記号など)または文字列先頭
/// - 連続一致: 直前のマッチ位置のすぐ次にマッチした(連続する部分文字列としてマッチした)
///
/// 大文字小文字は区別しない。日本語などの非ASCII文字は通常の文字として扱われ、
/// 特別な処理をせずそのまま部分一致の対象になる。
public enum FuzzyMatcher {
    /// `query` が `target` にファジーマッチするかを判定し、マッチしていればスコアを返す。
    /// マッチしなければ `nil`。空文字列のクエリは(スコア0で)常にマッチする。
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

    /// 単語境界とみなす区切り文字。ASCII の空白・記号に加え、日本語の読点・句点なども含む。
    private static let boundarySeparators: Set<Character> = [
        " ", "\t", "-", "_", "/", "(", ")", "…", ":", "・", "、", "。", "「", "」",
    ]

    private static func isWordBoundary(before index: Int, in chars: [Character]) -> Bool {
        guard index > 0 else { return true }
        return boundarySeparators.contains(chars[index - 1])
    }
}
