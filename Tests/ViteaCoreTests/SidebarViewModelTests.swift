import Foundation
import Testing
@testable import ViteaCore

@Suite("SidebarViewModel")
struct SidebarViewModelTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // vitea リポジトリ: main worktree(zsh) + feat/sidebar worktree(claude #1 busy, claude #2 waiting, codex #1 idle)
    // webapp リポジトリ: fix/login worktree(claude #1 busy)
    // docs/ui-mock.html の Screen 01 相当の構成。
    func makeFixture() -> (repos: [Repository], worktrees: [Worktree], sessions: [AgentSession]) {
        let vitea = Repository(name: "vitea", path: "/repo/vitea")
        let webapp = Repository(name: "webapp", path: "/repo/webapp")

        let main = Worktree(path: "/repo/vitea", repositoryPath: vitea.path, branch: "main")
        let sidebar = Worktree(path: "/wt/vitea/feat-sidebar", repositoryPath: vitea.path, branch: "feat/sidebar")
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
            repos: [vitea, webapp],
            worktrees: [main, sidebar, login],
            sessions: [zsh, claude1, claude2, codex1, claudeWebapp]
        )
    }

    @Test("3階層ツリーが正しく構築される")
    func buildsThreeLevelTree() {
        let fixture = makeFixture()
        let viewModel = SidebarViewModel(repositories: fixture.repos, worktrees: fixture.worktrees, sessions: fixture.sessions)

        #expect(viewModel.repositories.map(\.repository.name) == ["vitea", "webapp"])

        let viteaNode = viewModel.repositories[0]
        #expect(viteaNode.worktrees.map(\.worktree.branch) == ["main", "feat/sidebar"])
        #expect(viteaNode.worktrees[0].sessions.map(\.session.displayName) == ["zsh"])
        #expect(viteaNode.worktrees[1].sessions.map(\.session.displayName) == ["claude #1", "claude #2", "codex #1"])

        let webappNode = viewModel.repositories[1]
        #expect(webappNode.worktrees.map(\.worktree.branch) == ["fix/login"])
        #expect(webappNode.worktrees[0].sessions.map(\.session.displayName) == ["claude #1"])
    }

    @Test("どのリポジトリ・worktreeにも一致しないエントリはツリーから除外される")
    func orphansAreExcluded() {
        let vitea = Repository(name: "vitea", path: "/repo/vitea")
        let orphanWorktree = Worktree(path: "/wt/unknown", repositoryPath: "/repo/does-not-exist", branch: "x")
        let matchedWorktree = Worktree(path: "/repo/vitea", repositoryPath: vitea.path, branch: "main")
        let orphanSession = AgentSession(worktreePath: "/wt/unknown-worktree", presetName: "claude", displayName: "orphan")

        let viewModel = SidebarViewModel(
            repositories: [vitea],
            worktrees: [orphanWorktree, matchedWorktree],
            sessions: [orphanSession]
        )

        #expect(viewModel.repositories.count == 1)
        #expect(viewModel.repositories[0].worktrees.map(\.worktree.branch) == ["main"])
        #expect(viewModel.flattenedSessions.isEmpty)
    }

    @Test("⌘1..9のショートカット番号は表示順の先頭9件にのみ振られる")
    func shortcutNumbersAssignedToFirstNine() {
        let vitea = Repository(name: "vitea", path: "/repo/vitea")
        let wt = Worktree(path: "/repo/vitea", repositoryPath: vitea.path, branch: "main")
        let sessions = (1...11).map {
            AgentSession(worktreePath: wt.path, presetName: "shell", displayName: "s\($0)")
        }

        let viewModel = SidebarViewModel(repositories: [vitea], worktrees: [wt], sessions: sessions)
        let flat = viewModel.flattenedSessions

        #expect(flat.count == 11)
        #expect(flat.prefix(9).map(\.shortcutNumber) == (1...9).map { $0 })
        #expect(flat[9].shortcutNumber == nil)
        #expect(flat[10].shortcutNumber == nil)
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

    @Test("selectShortcutは対応する番号のセッションを選択する")
    func selectShortcutSelectsCorrectSession() {
        let fixture = makeFixture()
        var viewModel = SidebarViewModel(repositories: fixture.repos, worktrees: fixture.worktrees, sessions: fixture.sessions)

        let ok = viewModel.selectShortcut(3)
        #expect(ok == true)
        #expect(viewModel.selectedSessionID == viewModel.flattenedSessions[2].id)

        let notFound = viewModel.selectShortcut(9)
        #expect(notFound == false, "5セッションしかないので9番は存在しない")
    }

    @Test("jumpToLatestWaitingはstateChangedAtが最も新しいwaitingInputを選ぶ")
    func jumpToLatestWaitingPicksMostRecent() {
        let vitea = Repository(name: "vitea", path: "/repo/vitea")
        let wt = Worktree(path: "/repo/vitea", repositoryPath: vitea.path, branch: "main")
        let older = AgentSession(
            worktreePath: wt.path, presetName: "claude", displayName: "older",
            state: .waitingInput, stateChangedAt: t0
        )
        let newer = AgentSession(
            worktreePath: wt.path, presetName: "claude", displayName: "newer",
            state: .waitingInput, stateChangedAt: t0.addingTimeInterval(60)
        )
        let busy = AgentSession(worktreePath: wt.path, presetName: "claude", displayName: "busy", state: .busy)

        var viewModel = SidebarViewModel(repositories: [vitea], worktrees: [wt], sessions: [older, newer, busy])
        let jumped = viewModel.jumpToLatestWaiting()

        #expect(jumped == true)
        #expect(viewModel.selectedSession?.session.displayName == "newer")
    }

    @Test("stateChangedAtが同値/nilの場合は表示順で後ろを優先する")
    func jumpToLatestWaitingTieBreaksByDisplayOrder() {
        let vitea = Repository(name: "vitea", path: "/repo/vitea")
        let wt = Worktree(path: "/repo/vitea", repositoryPath: vitea.path, branch: "main")
        let first = AgentSession(worktreePath: wt.path, presetName: "claude", displayName: "first", state: .waitingInput)
        let second = AgentSession(worktreePath: wt.path, presetName: "claude", displayName: "second", state: .waitingInput)

        var viewModel = SidebarViewModel(repositories: [vitea], worktrees: [wt], sessions: [first, second])
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
}
