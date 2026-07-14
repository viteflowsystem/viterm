import Testing
@testable import VitermCore

@Suite("QuickOpenProvider")
struct QuickOpenProviderTests {
    // viterm: main (no sessions), feat/sidebar (claude, codex). webapp: fix/login (claude).
    func makeTree() -> [RepositoryNode] {
        let viterm = Repository(name: "viterm", path: "/repo/viterm")
        let webapp = Repository(name: "webapp", path: "/repo/webapp")

        let main = Worktree(path: "/repo/viterm", repositoryPath: viterm.path, branch: "main")
        let sidebar = Worktree(path: "/wt/viterm/feat-sidebar", repositoryPath: viterm.path, branch: "feat/sidebar")
        let login = Worktree(path: "/wt/webapp/fix-login", repositoryPath: webapp.path, branch: "fix/login")

        let claude = AgentSession(worktreePath: sidebar.path, presetName: "claude", displayName: "claude #1")
        let codex = AgentSession(worktreePath: sidebar.path, presetName: "codex", displayName: "codex #1")
        let webClaude = AgentSession(worktreePath: login.path, presetName: "claude", displayName: "claude #1")

        return [
            RepositoryNode(repository: viterm, worktrees: [
                WorktreeNode(worktree: main, sessions: []),
                WorktreeNode(worktree: sidebar, sessions: [
                    SessionNode(session: claude, shortcutNumber: nil),
                    SessionNode(session: codex, shortcutNumber: nil),
                ]),
            ]),
            RepositoryNode(repository: webapp, worktrees: [
                WorktreeNode(worktree: login, sessions: [
                    SessionNode(session: webClaude, shortcutNumber: nil),
                ]),
            ]),
        ]
    }

    @Test("全セッションと全worktreeがコマンド化される(セッションが先)")
    func buildsSessionAndWorktreeCommands() {
        let commands = QuickOpenProvider.commands(repositories: makeTree())

        let sessions = commands.filter { $0.category == .session }
        let worktrees = commands.filter { $0.category == .worktree }
        #expect(sessions.count == 3)
        #expect(worktrees.count == 3)
        // Sessions come first so they rank ahead on an empty query.
        #expect(commands.prefix(3).allSatisfy { $0.category == .session })
    }

    @Test("セッションのタイトルは repo · branch · session 名")
    func sessionTitleIncludesRepoBranchSession() {
        let commands = QuickOpenProvider.commands(repositories: makeTree())
        let titles = commands.filter { $0.category == .session }.map(\.title)
        #expect(titles.contains("viterm · feat/sidebar · claude #1"))
        #expect(titles.contains("viterm · feat/sidebar · codex #1"))
        #expect(titles.contains("webapp · fix/login · claude #1"))
    }

    @Test("セッション選択は switchToSession、worktree選択は switchToWorktree")
    func actionsRouteToSessionOrWorktree() {
        let commands = QuickOpenProvider.commands(repositories: makeTree())

        let session = commands.first { $0.category == .session && $0.title.contains("codex") }
        if case .switchToSession = session?.action {} else {
            Issue.record("expected .switchToSession, got \(String(describing: session?.action))")
        }

        let worktree = commands.first { $0.category == .worktree && $0.title == "viterm · main" }
        #expect(worktree?.action == .switchToWorktree(worktreeID: "/repo/viterm"))
    }

    @Test("セッションの無いworktreeもジャンプ対象に含まれる")
    func worktreeWithoutSessionsIsIncluded() {
        let commands = QuickOpenProvider.commands(repositories: makeTree())
        #expect(commands.contains { $0.category == .worktree && $0.title == "viterm · main" })
    }

    @Test("空ツリーは空配列を返す")
    func emptyTreeYieldsNoCommands() {
        #expect(QuickOpenProvider.commands(repositories: []).isEmpty)
    }
}
