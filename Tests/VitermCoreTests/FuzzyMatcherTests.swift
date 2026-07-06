import Testing
@testable import VitermCore

@Suite("FuzzyMatcher")
struct FuzzyMatcherTests {
    @Test("部分列としてマッチしない場合はnil")
    func nonSubsequenceReturnsNil() {
        #expect(FuzzyMatcher.score(query: "xyz", target: "worktree") == nil)
    }

    @Test("文字の順序が入れ替わっているとマッチしない")
    func outOfOrderCharactersDoNotMatch() {
        #expect(FuzzyMatcher.score(query: "tw", target: "worktree") == nil)
    }

    @Test("空クエリは常にスコア0でマッチする")
    func emptyQueryAlwaysMatches() {
        #expect(FuzzyMatcher.score(query: "", target: "worktree") == 0)
        #expect(FuzzyMatcher.score(query: "", target: "") == 0)
    }

    @Test("空の対象文字列は(空クエリ以外)マッチしない")
    func emptyTargetDoesNotMatchNonEmptyQuery() {
        #expect(FuzzyMatcher.score(query: "a", target: "") == nil)
    }

    @Test("大文字小文字を区別しない")
    func caseInsensitive() {
        let lower = FuzzyMatcher.score(query: "wt", target: "worktree")
        let upperQuery = FuzzyMatcher.score(query: "WT", target: "worktree")
        let upperTarget = FuzzyMatcher.score(query: "wt", target: "WORKTREE")
        #expect(lower != nil)
        #expect(lower == upperQuery)
        #expect(lower == upperTarget)
    }

    @Test("日本語もそのまま部分列マッチする")
    func japaneseSubsequenceMatches() {
        #expect(FuzzyMatcher.score(query: "作成", target: "新規作成…") != nil)
        #expect(FuzzyMatcher.score(query: "regex", target: "新規作成…") == nil)
    }

    @Test("先頭一致は先頭以外の一致よりスコアが高い")
    func prefixMatchScoresHigherThanMidStringMatch() {
        let prefixScore = FuzzyMatcher.score(query: "wo", target: "worktree list")!
        let midScore = FuzzyMatcher.score(query: "re", target: "worktree list")!
        #expect(prefixScore > midScore)
    }

    @Test("連続一致は飛び飛びの一致よりスコアが高い")
    func contiguousMatchScoresHigherThanScatteredMatch() {
        // "wo" is the first 2 chars of worktree (contiguous); "wt" is scattered at w(0), t(4).
        let contiguous = FuzzyMatcher.score(query: "wo", target: "xworktree")!
        let scattered = FuzzyMatcher.score(query: "wt", target: "xworktree")!
        #expect(contiguous > scattered)
    }

    @Test("単語境界(空白の直後)にマッチすると境界ボーナスが付く")
    func wordBoundaryBonus() {
        // "wt" scores higher in " worktree" (right after a space) than in "aworktree" (no boundary).
        let atBoundary = FuzzyMatcher.score(query: "wt", target: "a worktree")!
        let notAtBoundary = FuzzyMatcher.score(query: "wt", target: "aaworktree")!
        #expect(atBoundary > notAtBoundary)
    }

    @Test("クエリ長より短い対象文字列はマッチしない")
    func queryLongerThanTargetDoesNotMatch() {
        #expect(FuzzyMatcher.score(query: "worktree", target: "wt") == nil)
    }
}
