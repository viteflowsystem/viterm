import Testing
@testable import VitermCore

@Suite("PaletteCommandProvider")
struct PaletteCommandProviderTests {
    func makeTree() -> [RepositoryNode] {
        let repo = Repository(name: "viterm", path: "/repo/viterm")
        let main = Worktree(path: "/repo/viterm", repositoryPath: repo.path, branch: "main")
        let sidebar = Worktree(
            path: "/wt/feat-sidebar", repositoryPath: repo.path, branch: "feat/sidebar",
            ahead: 3, behind: 1
        )
        let resize = Worktree(path: "/wt/fix-resize", repositoryPath: repo.path, branch: "fix/resize", ahead: 1)

        return [
            RepositoryNode(
                repository: repo,
                worktrees: [
                    WorktreeNode(worktree: main, sessions: []),
                    WorktreeNode(worktree: sidebar, sessions: []),
                    WorktreeNode(worktree: resize, sessions: []),
                ]
            ),
        ]
    }

    let presets = [
        SessionPreset(name: "claude", command: "claude"),
        SessionPreset(name: "codex", command: "codex"),
    ]

    @Test("新規作成とリポジトリ追加は常に生成される")
    func alwaysIncludesCreateAndAddRepository() {
        let commands = PaletteCommandProvider.commands(
            repositories: [],
            presets: [],
            defaultPresetName: nil,
            currentWorktreeID: nil
        )
        #expect(commands.contains { $0.action == .createWorktree })
        #expect(commands.contains { $0.action == .addRepository })
        #expect(commands.first { $0.action == .createWorktree }?.keyboardHint == "⌘N")
    }

    @Test("各worktreeごとに切替コマンドが生成され、ahead/behindが部分表示される")
    func generatesSwitchCommandPerWorktreeWithAheadBehind() {
        let commands = PaletteCommandProvider.commands(
            repositories: makeTree(),
            presets: presets,
            defaultPresetName: "claude",
            currentWorktreeID: nil
        )

        let switches = commands.filter {
            if case .switchToWorktree = $0.action { return true }
            return false
        }
        #expect(switches.count == 3)

        let sidebarSwitch = switches.first { $0.title == L("Switch to \("feat/sidebar")") }
        #expect(sidebarSwitch?.subtitle == "↑3 ↓1")

        let resizeSwitch = switches.first { $0.title == L("Switch to \("fix/resize")") }
        #expect(resizeSwitch?.subtitle == "↑1", "behindが0の場合は↓を表示しない")

        let mainSwitch = switches.first { $0.title == L("Switch to \("main")") }
        #expect(mainSwitch?.subtitle == nil, "ahead/behindが両方0ならsubtitleはnil")
    }

    @Test("currentWorktreeIDが無ければマージ・削除・セッション起動コマンドは生成されない")
    func noContextCommandsWithoutCurrentWorktree() {
        let commands = PaletteCommandProvider.commands(
            repositories: makeTree(),
            presets: presets,
            defaultPresetName: "claude",
            currentWorktreeID: nil
        )
        #expect(!commands.contains { if case .mergeWorktree = $0.action { return true }; return false })
        #expect(!commands.contains { if case .removeWorktree = $0.action { return true }; return false })
        #expect(!commands.contains { if case .startSession = $0.action { return true }; return false })
    }

    @Test("currentWorktreeIDがツリーに存在しなければコンテキストコマンドは生成されない")
    func noContextCommandsForUnknownWorktree() {
        let commands = PaletteCommandProvider.commands(
            repositories: makeTree(),
            presets: presets,
            defaultPresetName: "claude",
            currentWorktreeID: "/does/not/exist"
        )
        #expect(!commands.contains { if case .mergeWorktree = $0.action { return true }; return false })
    }

    @Test("currentWorktreeIDがあればマージ・削除・プリセットごとのセッション起動が生成される")
    func generatesContextCommandsForCurrentWorktree() {
        let commands = PaletteCommandProvider.commands(
            repositories: makeTree(),
            presets: presets,
            defaultPresetName: "claude",
            currentWorktreeID: "/wt/feat-sidebar",
            mergeTargetBranch: "main"
        )

        #expect(commands.contains { $0.title == L("Merge into \("main")… (merge / rebase)") })
        #expect(commands.contains { $0.title == L("Remove…") })

        let claudeStart = commands.first { $0.title == L("Start \("claude") (this worktree)") }
        #expect(claudeStart?.action == .startSession(worktreeID: "/wt/feat-sidebar", presetName: "claude"))
        #expect(claudeStart?.keyboardHint == "⌘T", "既定プリセットにのみ⌘Tが付く")

        let codexStart = commands.first { $0.title == L("Start \("codex") (this worktree)") }
        #expect(codexStart?.keyboardHint == nil, "既定プリセット以外は⌘Tを持たない")
    }

    @Test("コマンドIDは重複しない")
    func commandIDsAreUnique() {
        let commands = PaletteCommandProvider.commands(
            repositories: makeTree(),
            presets: presets,
            defaultPresetName: "claude",
            currentWorktreeID: "/wt/feat-sidebar"
        )
        let ids = commands.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}
