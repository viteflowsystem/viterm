import Testing
@testable import VitermCore

@Suite("PaletteSearch")
struct PaletteSearchTests {
    func makeCommands() -> [PaletteCommand] {
        [
            PaletteCommand(id: "worktree.create", category: .worktree, title: "新規作成…", action: .createWorktree),
            PaletteCommand(
                id: "worktree.switch.a", category: .worktree, title: "feat/sidebar に切替",
                action: .switchToWorktree(worktreeID: "a")
            ),
            PaletteCommand(
                id: "session.start.a.claude", category: .session, title: "claude を起動(この worktree)",
                action: .startSession(worktreeID: "a", presetName: "claude")
            ),
            PaletteCommand(id: "repo.add", category: .repository, title: "リポジトリを追加…(ディレクトリ選択)", action: .addRepository),
        ]
    }

    @Test("空クエリは元の順序のまま全件返す")
    func emptyQueryReturnsAllUnfiltered() {
        let commands = makeCommands()
        #expect(PaletteSearch.search(commands, query: "") == commands)
    }

    @Test("マッチしないコマンドは除外される")
    func nonMatchingCommandsAreExcluded() {
        let commands = makeCommands()
        let results = PaletteSearch.search(commands, query: "リポジトリ")
        #expect(results.map(\.id) == ["repo.add"])
    }

    @Test("wt クエリでWorktree系がSession/Repoより上位になる")
    func wtQueryRanksWorktreeCategoryFirst() {
        let commands = makeCommands()
        let results = PaletteSearch.search(commands, query: "wt")

        // The two Worktree-category entries (category name "Worktree" prefix-matches) rank
        // above the one Session entry that merely contains "worktree" in its body.
        // The Repo entry contains no "w" and doesn't match.
        #expect(results.count == 3)
        #expect(Set(results.prefix(2).map(\.id)) == ["worktree.create", "worktree.switch.a"])
        #expect(results.last?.id == "session.start.a.claude")
        #expect(!results.map(\.id).contains("repo.add"))
    }

    @Test("スコア同点は元の配列順を保つ安定ソート")
    func tiesPreserveOriginalOrder() {
        let commands = [
            PaletteCommand(id: "c1", category: .worktree, title: "aaa", action: .createWorktree),
            PaletteCommand(id: "c2", category: .worktree, title: "aaa", action: .createWorktree),
        ]
        let results = PaletteSearch.search(commands, query: "aaa")
        #expect(results.map(\.id) == ["c1", "c2"])
    }
}
