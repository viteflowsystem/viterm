import Foundation
import Testing
@testable import VitermCore

@Suite("SidebarViewModel")
struct SidebarViewModelTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // viterm repository: main worktree (zsh) + feat/sidebar worktree (claude #1 busy, claude #2 waiting, codex #1 idle)
    // webapp repository: fix/login worktree (claude #1 busy)
    // A setup equivalent to Screen 01 of docs/ui-mock.html.
    func makeFixture() -> (repos: [Repository], worktrees: [Worktree], sessions: [AgentSession]) {
        let viterm = Repository(name: "viterm", path: "/repo/viterm")
        let webapp = Repository(name: "webapp", path: "/repo/webapp")

        let main = Worktree(path: "/repo/viterm", repositoryPath: viterm.path, branch: "main")
        let sidebar = Worktree(path: "/wt/viterm/feat-sidebar", repositoryPath: viterm.path, branch: "feat/sidebar")
        let login = Worktree(path: "/wt/webapp/fix-login", repositoryPath: webapp.path, branch: "fix/login")

        let zsh = AgentSession(worktreePath: main.path, presetName: "shell", displayName: "zsh", state: .idle)
        let claude1 = AgentSession(worktreePath: sidebar.path, presetName: "claude", displayName: "claude #1", state: .busy)
        let claude2 = AgentSession(
            worktreePath: sidebar.path,
            presetName: "claude",
            displayName: "claude #2",
            state: .waitingInput,
            stateChangedAt: t0
        )
        let codex1 = AgentSession(worktreePath: sidebar.path, presetName: "codex", displayName: "codex #1", state: .idle)
        let claudeWebapp = AgentSession(worktreePath: login.path, presetName: "claude", displayName: "claude #1", state: .busy)

        return (
            repos: [viterm, webapp],
            worktrees: [main, sidebar, login],
            sessions: [zsh, claude1, claude2, codex1, claudeWebapp]
        )
    }

    @Test("3階層ツリーが正しく構築される")
    func buildsThreeLevelTree() {
        let fixture = makeFixture()
        let viewModel = SidebarViewModel(repositories: fixture.repos, worktrees: fixture.worktrees, sessions: fixture.sessions)

        #expect(viewModel.repositories.map(\.repository.name) == ["viterm", "webapp"])

        let vitermNode = viewModel.repositories[0]
        #expect(vitermNode.worktrees.map(\.worktree.branch) == ["main", "feat/sidebar"])
        #expect(vitermNode.worktrees[0].sessions.map(\.session.displayName) == ["zsh"])
        #expect(vitermNode.worktrees[1].sessions.map(\.session.displayName) == ["claude #1", "claude #2", "codex #1"])

        let webappNode = viewModel.repositories[1]
        #expect(webappNode.worktrees.map(\.worktree.branch) == ["fix/login"])
        #expect(webappNode.worktrees[0].sessions.map(\.session.displayName) == ["claude #1"])
    }

    @Test("どのリポジトリ・worktreeにも一致しないエントリはツリーから除外される")
    func orphansAreExcluded() {
        let viterm = Repository(name: "viterm", path: "/repo/viterm")
        let orphanWorktree = Worktree(path: "/wt/unknown", repositoryPath: "/repo/does-not-exist", branch: "x")
        let matchedWorktree = Worktree(path: "/repo/viterm", repositoryPath: viterm.path, branch: "main")
        let orphanSession = AgentSession(worktreePath: "/wt/unknown-worktree", presetName: "claude", displayName: "orphan")

        let viewModel = SidebarViewModel(
            repositories: [viterm],
            worktrees: [orphanWorktree, matchedWorktree],
            sessions: [orphanSession]
        )

        #expect(viewModel.repositories.count == 1)
        #expect(viewModel.repositories[0].worktrees.map(\.worktree.branch) == ["main"])
        #expect(viewModel.flattenedSessions.isEmpty)
    }

    @Test("⌘1..9はタブ局所(TabBarViewModel)の役割なのでshortcutNumberは振らない")
    func shortcutNumberIsNeverAssigned() {
        let viterm = Repository(name: "viterm", path: "/repo/viterm")
        let wt = Worktree(path: "/repo/viterm", repositoryPath: viterm.path, branch: "main")
        let sessions = (1...11).map {
            AgentSession(worktreePath: wt.path, presetName: "shell", displayName: "s\($0)")
        }

        let viewModel = SidebarViewModel(repositories: [viterm], worktrees: [wt], sessions: sessions)

        #expect(viewModel.flattenedSessions.allSatisfy { $0.shortcutNumber == nil })
    }

    @Test("リポジトリ折りたたみ用のwaitingセッション数はworktree横断で集計される")
    func waitingSessionCountAggregatesAcrossWorktrees() {
        let fixture = makeFixture()
        let viewModel = SidebarViewModel(repositories: fixture.repos, worktrees: fixture.worktrees, sessions: fixture.sessions)

        #expect(viewModel.repositories[0].waitingSessionCount == 1)
        #expect(viewModel.repositories[1].waitingSessionCount == 0)
    }

    @Test("状態集計はリポジトリ横断でbusy/waiting/idleを数える")
    func stateSummaryAggregatesAcrossRepositories() {
        let fixture = makeFixture()
        let viewModel = SidebarViewModel(repositories: fixture.repos, worktrees: fixture.worktrees, sessions: fixture.sessions)

        let summary = viewModel.stateSummary
        #expect(summary.busy == 2)
        #expect(summary.waitingInput == 1)
        #expect(summary.idle == 2)
        #expect(summary.total == 5)
    }

    @Test("selectで直接選択でき、存在しないIDならselectedSessionはnil")
    func selectAndSelectedSession() {
        let fixture = makeFixture()
        var viewModel = SidebarViewModel(repositories: fixture.repos, worktrees: fixture.worktrees, sessions: fixture.sessions)
        let target = viewModel.flattenedSessions[1]

        viewModel.select(sessionID: target.id)
        #expect(viewModel.selectedSession?.id == target.id)

        viewModel.select(sessionID: UUID())
        #expect(viewModel.selectedSession == nil)
    }

    @Test("selectNext/selectPreviousは表示順で循環する")
    func selectNextAndPreviousWrapAround() {
        let fixture = makeFixture()
        var viewModel = SidebarViewModel(repositories: fixture.repos, worktrees: fixture.worktrees, sessions: fixture.sessions)
        let flat = viewModel.flattenedSessions

        viewModel.select(sessionID: flat[0].id)
        viewModel.selectNext()
        #expect(viewModel.selectedSessionID == flat[1].id)

        viewModel.select(sessionID: flat.last!.id)
        viewModel.selectNext()
        #expect(viewModel.selectedSessionID == flat[0].id, "末尾から次へ進むと先頭に循環する")

        viewModel.select(sessionID: flat[0].id)
        viewModel.selectPrevious()
        #expect(viewModel.selectedSessionID == flat.last!.id, "先頭から前へ戻ると末尾に循環する")
    }

    @Test("選択が無い状態でselectNextを呼ぶと先頭が選ばれる")
    func selectNextWithNoSelectionPicksFirst() {
        let fixture = makeFixture()
        var viewModel = SidebarViewModel(repositories: fixture.repos, worktrees: fixture.worktrees, sessions: fixture.sessions)
        viewModel.selectNext()
        #expect(viewModel.selectedSessionID == viewModel.flattenedSessions.first?.id)
    }

    @Test("選択が無い状態でselectPreviousを呼ぶと末尾が選ばれる")
    func selectPreviousWithNoSelectionPicksLast() {
        let fixture = makeFixture()
        var viewModel = SidebarViewModel(repositories: fixture.repos, worktrees: fixture.worktrees, sessions: fixture.sessions)
        viewModel.selectPrevious()
        #expect(viewModel.selectedSessionID == viewModel.flattenedSessions.last?.id)
    }

    @Test("jumpToLatestWaitingはstateChangedAtが最も新しいwaitingInputを選ぶ")
    func jumpToLatestWaitingPicksMostRecent() {
        let viterm = Repository(name: "viterm", path: "/repo/viterm")
        let wt = Worktree(path: "/repo/viterm", repositoryPath: viterm.path, branch: "main")
        let older = AgentSession(
            worktreePath: wt.path, presetName: "claude", displayName: "older",
            state: .waitingInput, stateChangedAt: t0
        )
        let newer = AgentSession(
            worktreePath: wt.path, presetName: "claude", displayName: "newer",
            state: .waitingInput, stateChangedAt: t0.addingTimeInterval(60)
        )
        let busy = AgentSession(worktreePath: wt.path, presetName: "claude", displayName: "busy", state: .busy)

        var viewModel = SidebarViewModel(repositories: [viterm], worktrees: [wt], sessions: [older, newer, busy])
        let jumped = viewModel.jumpToLatestWaiting()

        #expect(jumped == true)
        #expect(viewModel.selectedSession?.session.displayName == "newer")
    }

    @Test("stateChangedAtが同値/nilの場合は表示順で後ろを優先する")
    func jumpToLatestWaitingTieBreaksByDisplayOrder() {
        let viterm = Repository(name: "viterm", path: "/repo/viterm")
        let wt = Worktree(path: "/repo/viterm", repositoryPath: viterm.path, branch: "main")
        let first = AgentSession(worktreePath: wt.path, presetName: "claude", displayName: "first", state: .waitingInput)
        let second = AgentSession(worktreePath: wt.path, presetName: "claude", displayName: "second", state: .waitingInput)

        var viewModel = SidebarViewModel(repositories: [viterm], worktrees: [wt], sessions: [first, second])
        #expect(viewModel.jumpToLatestWaiting() == true)
        #expect(viewModel.selectedSession?.session.displayName == "second")
    }

    @Test("waitingInputが無ければjumpToLatestWaitingは何もせずfalseを返す")
    func jumpToLatestWaitingReturnsFalseWhenNoneWaiting() {
        let fixture = makeFixture()
        var viewModel = SidebarViewModel(repositories: fixture.repos, worktrees: fixture.worktrees, sessions: [fixture.sessions[0]])
        #expect(viewModel.jumpToLatestWaiting() == false)
        #expect(viewModel.selectedSessionID == nil)
    }

    @Test("セッションが1件も無くてもselectNext/selectPreviousはクラッシュしない")
    func emptyTreeSelectionIsNoOp() {
        var viewModel = SidebarViewModel(repositories: [], worktrees: [], sessions: [])
        viewModel.selectNext()
        viewModel.selectPrevious()
        #expect(viewModel.selectedSessionID == nil)
        #expect(viewModel.stateSummary == SessionStateSummary())
    }

    // MARK: - Worktree selection

    @Test("selectはselectedWorktreePathとactiveSessionByWorktreeも更新する")
    func selectSyncsWorktreeSelection() {
        let fixture = makeFixture()
        var viewModel = SidebarViewModel(repositories: fixture.repos, worktrees: fixture.worktrees, sessions: fixture.sessions)
        let target = viewModel.repositories[0].worktrees[1].sessions[1] // claude #2 (feat/sidebar)

        viewModel.select(sessionID: target.id)

        #expect(viewModel.selectedWorktreePath == "/wt/viterm/feat-sidebar")
        #expect(viewModel.activeSessionByWorktree["/wt/viterm/feat-sidebar"] == target.id)
    }

    @Test("worktree Aを選択中にworktree Bのセッションをselectすると選択中worktreeがBに切り替わる")
    func selectSwitchesActiveWorktreeAcrossWorktrees() {
        let fixture = makeFixture()
        var viewModel = SidebarViewModel(repositories: fixture.repos, worktrees: fixture.worktrees, sessions: fixture.sessions)

        // Set up a state where worktree A (main, zsh) is selected.
        viewModel.selectWorktree("/repo/viterm")
        #expect(viewModel.selectedWorktreePath == "/repo/viterm")

        // Directly select a known session belonging to worktree B (feat/sidebar).
        let sessionInWorktreeB = fixture.sessions.first { $0.displayName == "claude #1" && $0.worktreePath == "/wt/viterm/feat-sidebar" }!
        viewModel.select(sessionID: sessionInWorktreeB.id)

        #expect(viewModel.selectedWorktreePath == "/wt/viterm/feat-sidebar", "selectしたセッションが属するworktree Bに切り替わる")
        #expect(viewModel.selectedSessionID == sessionInWorktreeB.id)
        #expect(viewModel.activeSessionByWorktree["/wt/viterm/feat-sidebar"] == sessionInWorktreeB.id)
    }

    @Test("存在しないセッションIDをselectしてもselectedWorktreePathは変化しない")
    func selectWithUnknownSessionIDDoesNotTouchWorktree() {
        let fixture = makeFixture()
        var viewModel = SidebarViewModel(
            repositories: fixture.repos, worktrees: fixture.worktrees, sessions: fixture.sessions,
            selectedWorktreePath: "/repo/viterm"
        )

        viewModel.select(sessionID: UUID())

        #expect(viewModel.selectedSessionID != nil)
        #expect(viewModel.selectedSession == nil)
        #expect(viewModel.selectedWorktreePath == "/repo/viterm", "紐付く worktree が特定できないので既存の選択を保つ")
    }

    @Test("selectWorktreeは記憶があればそのセッションに復帰する")
    func selectWorktreeRestoresRememberedSession() {
        let fixture = makeFixture()
        let sidebarWorktree = fixture.worktrees[1] // feat/sidebar
        let claude2 = fixture.sessions.first { $0.displayName == "claude #2" }!

        var viewModel = SidebarViewModel(
            repositories: fixture.repos, worktrees: fixture.worktrees, sessions: fixture.sessions,
            activeSessionByWorktree: [sidebarWorktree.path: claude2.id]
        )

        viewModel.selectWorktree(sidebarWorktree.path)

        #expect(viewModel.selectedWorktreePath == sidebarWorktree.path)
        #expect(viewModel.selectedSessionID == claude2.id, "worktree を離れて戻ったとき同じタブに復帰する")
    }

    @Test("selectWorktreeは記憶が無ければ先頭セッションを選ぶ")
    func selectWorktreePicksFirstSessionWhenNoMemory() {
        let fixture = makeFixture()
        let sidebarWorktree = fixture.worktrees[1] // feat/sidebar

        var viewModel = SidebarViewModel(repositories: fixture.repos, worktrees: fixture.worktrees, sessions: fixture.sessions)
        viewModel.selectWorktree(sidebarWorktree.path)

        #expect(viewModel.selectedSessionID == viewModel.repositories[0].worktrees[1].sessions.first?.id)
        #expect(viewModel.activeSessionByWorktree[sidebarWorktree.path] == viewModel.selectedSessionID)
    }

    @Test("selectWorktreeは記憶が無効(そのworktreeに存在しないセッション)なら先頭セッションを選ぶ")
    func selectWorktreeIgnoresStaleMemory() {
        let fixture = makeFixture()
        let sidebarWorktree = fixture.worktrees[1] // feat/sidebar
        let webappSession = fixture.sessions.first { $0.displayName == "claude #1" && $0.worktreePath == "/wt/webapp/fix-login" }!

        var viewModel = SidebarViewModel(
            repositories: fixture.repos, worktrees: fixture.worktrees, sessions: fixture.sessions,
            activeSessionByWorktree: [sidebarWorktree.path: webappSession.id]
        )
        viewModel.selectWorktree(sidebarWorktree.path)

        #expect(viewModel.selectedSessionID == viewModel.repositories[0].worktrees[1].sessions.first?.id)
    }

    @Test("空worktreeをselectWorktreeするとセッション選択は解除される")
    func selectWorktreeWithEmptyWorktreeClearsSessionSelection() {
        let viterm = Repository(name: "viterm", path: "/repo/viterm")
        let empty = Worktree(path: "/wt/viterm/empty", repositoryPath: viterm.path, branch: "empty")

        var viewModel = SidebarViewModel(repositories: [viterm], worktrees: [empty], sessions: [])
        viewModel.selectWorktree(empty.path)

        #expect(viewModel.selectedWorktreePath == empty.path)
        #expect(viewModel.selectedSessionID == nil)
    }

    @Test("存在しないworktreeパスをselectWorktreeするとセッション選択は解除される")
    func selectWorktreeWithUnknownPathClearsSessionSelection() {
        let fixture = makeFixture()
        var viewModel = SidebarViewModel(repositories: fixture.repos, worktrees: fixture.worktrees, sessions: fixture.sessions)

        viewModel.selectWorktree("/does/not/exist")

        #expect(viewModel.selectedWorktreePath == "/does/not/exist")
        #expect(viewModel.selectedSessionID == nil)
    }

    @Test("nilをselectWorktreeするとworktree・セッションの両方が解除される")
    func selectWorktreeWithNilClearsBoth() {
        let fixture = makeFixture()
        var viewModel = SidebarViewModel(repositories: fixture.repos, worktrees: fixture.worktrees, sessions: fixture.sessions)
        viewModel.selectWorktree(fixture.worktrees[0].path)

        viewModel.selectWorktree(nil)

        #expect(viewModel.selectedWorktreePath == nil)
        #expect(viewModel.selectedSessionID == nil)
    }

    @Test("selectNextWorktree/selectPreviousWorktreeは表示順で循環する")
    func selectNextAndPreviousWorktreeWrapAround() {
        let fixture = makeFixture()
        var viewModel = SidebarViewModel(repositories: fixture.repos, worktrees: fixture.worktrees, sessions: fixture.sessions)
        let flat = viewModel.flattenedWorktrees

        viewModel.selectWorktree(flat[0].id)
        viewModel.selectNextWorktree()
        #expect(viewModel.selectedWorktreePath == flat[1].id)

        viewModel.selectWorktree(flat.last!.id)
        viewModel.selectNextWorktree()
        #expect(viewModel.selectedWorktreePath == flat[0].id, "末尾から次へ進むと先頭に循環する")

        viewModel.selectWorktree(flat[0].id)
        viewModel.selectPreviousWorktree()
        #expect(viewModel.selectedWorktreePath == flat.last!.id, "先頭から前へ戻ると末尾に循環する")
    }

    @Test("worktreeが1件だけの場合、selectNextWorktree/selectPreviousWorktreeは自分自身に循環する")
    func selectNextAndPreviousWorktreeWithSingleWorktreeStaysOnSelf() {
        let viterm = Repository(name: "viterm", path: "/repo/viterm")
        let wt = Worktree(path: "/repo/viterm", repositoryPath: viterm.path, branch: "main")

        var viewModel = SidebarViewModel(repositories: [viterm], worktrees: [wt], sessions: [])
        viewModel.selectWorktree(wt.path)

        viewModel.selectNextWorktree()
        #expect(viewModel.selectedWorktreePath == wt.path, "worktreeが1件だけなら次へ進んでも自分自身に留まる")

        viewModel.selectPreviousWorktree()
        #expect(viewModel.selectedWorktreePath == wt.path, "worktreeが1件だけなら前へ戻っても自分自身に留まる")
    }

    @Test("選択が無い状態でselectNextWorktreeを呼ぶと先頭が選ばれる")
    func selectNextWorktreeWithNoSelectionPicksFirst() {
        let fixture = makeFixture()
        var viewModel = SidebarViewModel(repositories: fixture.repos, worktrees: fixture.worktrees, sessions: fixture.sessions)
        viewModel.selectNextWorktree()
        #expect(viewModel.selectedWorktreePath == viewModel.flattenedWorktrees.first?.id)
    }

    @Test("選択が無い状態でselectPreviousWorktreeを呼ぶと末尾が選ばれる")
    func selectPreviousWorktreeWithNoSelectionPicksLast() {
        let fixture = makeFixture()
        var viewModel = SidebarViewModel(repositories: fixture.repos, worktrees: fixture.worktrees, sessions: fixture.sessions)
        viewModel.selectPreviousWorktree()
        #expect(viewModel.selectedWorktreePath == viewModel.flattenedWorktrees.last?.id)
    }

    @Test("worktreeが1件も無くてもselectNextWorktree/selectPreviousWorktreeはクラッシュしない")
    func emptyWorktreeListSelectionIsNoOp() {
        var viewModel = SidebarViewModel(repositories: [], worktrees: [], sessions: [])
        viewModel.selectNextWorktree()
        viewModel.selectPreviousWorktree()
        #expect(viewModel.selectedWorktreePath == nil)
    }

    @Test("jumpToLatestWaitingはworktree選択も連動して切り替える")
    func jumpToLatestWaitingSyncsWorktreeSelection() {
        let fixture = makeFixture()
        var viewModel = SidebarViewModel(repositories: fixture.repos, worktrees: fixture.worktrees, sessions: fixture.sessions)

        #expect(viewModel.jumpToLatestWaiting() == true)

        #expect(viewModel.selectedWorktreePath == "/wt/viterm/feat-sidebar")
        #expect(viewModel.selectedSession?.session.displayName == "claude #2")
        #expect(viewModel.activeSessionByWorktree["/wt/viterm/feat-sidebar"] == viewModel.selectedSessionID)
    }

    // MARK: - Filtering

    @Test("空フィルタはツリーをそのまま返す")
    func emptyFilterReturnsFullTree() {
        let fixture = makeFixture()
        let viewModel = SidebarViewModel(repositories: fixture.repos, worktrees: fixture.worktrees, sessions: fixture.sessions)

        #expect(viewModel.filteredRepositories == viewModel.repositories)
    }

    @Test("リポジトリ名の一致はworktreeをすべて残す")
    func repositoryMatchKeepsAllWorktrees() {
        let fixture = makeFixture()
        var viewModel = SidebarViewModel(repositories: fixture.repos, worktrees: fixture.worktrees, sessions: fixture.sessions)
        viewModel.setFilterText("viterm")

        let filtered = viewModel.filteredRepositories
        #expect(filtered.map(\.repository.name) == ["viterm"])
        #expect(filtered[0].worktrees.map(\.worktree.branch) == ["main", "feat/sidebar"])
    }

    @Test("ブランチ名の一致は祖先リポジトリを残し、他のworktreeは隠す")
    func branchMatchKeepsAncestorRepository() {
        let fixture = makeFixture()
        var viewModel = SidebarViewModel(repositories: fixture.repos, worktrees: fixture.worktrees, sessions: fixture.sessions)
        viewModel.setFilterText("feat/side")

        let filtered = viewModel.filteredRepositories
        #expect(filtered.map(\.repository.name) == ["viterm"])
        #expect(filtered[0].worktrees.map(\.worktree.branch) == ["feat/sidebar"])
        // Sessions under a matching worktree are all kept.
        #expect(filtered[0].worktrees[0].sessions.count == 3)
    }

    @Test("セッション名の一致は所属worktreeを残す(ツリーにセッション行はなくても可視性を保つ)")
    func sessionMatchKeepsOwningWorktree() {
        let fixture = makeFixture()
        var viewModel = SidebarViewModel(repositories: fixture.repos, worktrees: fixture.worktrees, sessions: fixture.sessions)
        viewModel.setFilterText("codex")

        let filtered = viewModel.filteredRepositories
        #expect(filtered.map(\.repository.name) == ["viterm"])
        #expect(filtered[0].worktrees.map(\.worktree.branch) == ["feat/sidebar"])
    }

    @Test("フィルタは大文字小文字を区別しない")
    func filterIsCaseInsensitive() {
        let fixture = makeFixture()
        var viewModel = SidebarViewModel(repositories: fixture.repos, worktrees: fixture.worktrees, sessions: fixture.sessions)
        viewModel.setFilterText("VITERM")

        #expect(viewModel.filteredRepositories.map(\.repository.name) == ["viterm"])
    }

    @Test("どこにも一致しないフィルタは空配列を返す")
    func noMatchYieldsEmptyArray() {
        let fixture = makeFixture()
        var viewModel = SidebarViewModel(repositories: fixture.repos, worktrees: fixture.worktrees, sessions: fixture.sessions)
        viewModel.setFilterText("zzz-no-match")

        #expect(viewModel.filteredRepositories.isEmpty)
    }

    @Test("フィルタで選択が隠れても選択状態はクリアされない")
    func filteringDoesNotClearSelection() {
        let fixture = makeFixture()
        var viewModel = SidebarViewModel(repositories: fixture.repos, worktrees: fixture.worktrees, sessions: fixture.sessions)
        viewModel.selectWorktree("/wt/viterm/feat-sidebar")
        let selectedSession = viewModel.selectedSessionID

        viewModel.setFilterText("webapp") // hides the selected worktree

        #expect(viewModel.filteredRepositories.map(\.repository.name) == ["webapp"])
        #expect(viewModel.selectedWorktreePath == "/wt/viterm/feat-sidebar")
        #expect(viewModel.selectedSessionID == selectedSession)
    }

    @Test("rebuiltは選択・worktree記憶・フィルタをすべて引き継ぐ")
    func rebuiltCarriesOverAllUIState() {
        let fixture = makeFixture()
        var viewModel = SidebarViewModel(repositories: fixture.repos, worktrees: fixture.worktrees, sessions: fixture.sessions)
        viewModel.selectWorktree("/wt/viterm/feat-sidebar")
        viewModel.setFilterText("claude")

        let rebuilt = viewModel.rebuilt(
            repositories: fixture.repos,
            worktrees: fixture.worktrees,
            sessions: fixture.sessions
        )

        #expect(rebuilt.filterText == "claude")
        #expect(rebuilt.selectedWorktreePath == viewModel.selectedWorktreePath)
        #expect(rebuilt.selectedSessionID == viewModel.selectedSessionID)
        #expect(rebuilt.activeSessionByWorktree == viewModel.activeSessionByWorktree)
    }

    @Test("リポジトリ単位の状態集計はworktree横断で数える")
    func repositoryStateSummaryAggregatesAcrossWorktrees() {
        let fixture = makeFixture()
        let viewModel = SidebarViewModel(repositories: fixture.repos, worktrees: fixture.worktrees, sessions: fixture.sessions)

        let viterm = viewModel.repositories[0].stateSummary
        #expect(viterm.busy == 1)
        #expect(viterm.waitingInput == 1)
        #expect(viterm.idle == 2)

        let webapp = viewModel.repositories[1].stateSummary
        #expect(webapp.busy == 1)
        #expect(webapp.waitingInput == 0)
        #expect(webapp.idle == 0)
    }

    // MARK: - State lanes

    @Test("stateLanesは状態別にセッションをグルーピングし非正規化する")
    func stateLanesGroupSessionsByState() {
        let fixture = makeFixture()
        let viewModel = SidebarViewModel(repositories: fixture.repos, worktrees: fixture.worktrees, sessions: fixture.sessions)

        let lanes = viewModel.stateLanes
        #expect(lanes.waiting.map(\.sessionName) == ["claude #2"])
        #expect(lanes.busy.map(\.sessionName) == ["claude #1", "claude #1"])
        #expect(lanes.idle.map(\.sessionName) == ["zsh", "codex #1"])

        let waiting = lanes.waiting[0]
        #expect(waiting.repositoryName == "viterm")
        #expect(waiting.branch == "feat/sidebar")
        #expect(waiting.state == .waitingInput)
    }

    @Test("レーン内はstateChangedAtの新しい順、nilは最後、同時刻は表示順")
    func laneOrdersByStateChangedAtDescending() {
        let repo = Repository(name: "r", path: "/repo/r")
        let wt = Worktree(path: "/repo/r", repositoryPath: repo.path, branch: "main")
        let old = AgentSession(worktreePath: wt.path, presetName: "claude", displayName: "old", state: .waitingInput, stateChangedAt: t0)
        let new = AgentSession(worktreePath: wt.path, presetName: "claude", displayName: "new", state: .waitingInput, stateChangedAt: t0.addingTimeInterval(60))
        let unknownA = AgentSession(worktreePath: wt.path, presetName: "claude", displayName: "unknownA", state: .waitingInput)
        let unknownB = AgentSession(worktreePath: wt.path, presetName: "claude", displayName: "unknownB", state: .waitingInput)

        let viewModel = SidebarViewModel(repositories: [repo], worktrees: [wt], sessions: [unknownA, old, unknownB, new])

        #expect(viewModel.stateLanes.waiting.map(\.sessionName) == ["new", "old", "unknownA", "unknownB"])
    }

    @Test("stateLanesはフィルタ済みツリーから導出される")
    func stateLanesDeriveFromFilteredTree() {
        let fixture = makeFixture()
        var viewModel = SidebarViewModel(repositories: fixture.repos, worktrees: fixture.worktrees, sessions: fixture.sessions)
        viewModel.setFilterText("webapp")

        let lanes = viewModel.stateLanes
        #expect(lanes.waiting.isEmpty)
        #expect(lanes.busy.map(\.repositoryName) == ["webapp"])
        #expect(lanes.idle.isEmpty)
    }

    @Test("rebuiltはdisplayModeも引き継ぐ")
    func rebuiltCarriesOverDisplayMode() {
        let fixture = makeFixture()
        var viewModel = SidebarViewModel(repositories: fixture.repos, worktrees: fixture.worktrees, sessions: fixture.sessions)
        viewModel.setDisplayMode(.state)

        let rebuilt = viewModel.rebuilt(
            repositories: fixture.repos,
            worktrees: fixture.worktrees,
            sessions: fixture.sessions
        )

        #expect(rebuilt.displayMode == .state)
    }
}
