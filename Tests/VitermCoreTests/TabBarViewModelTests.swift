import Foundation
import Testing
@testable import VitermCore

@Suite("TabBarViewModel")
struct TabBarViewModelTests {
    private func makeSessions(count: Int) -> [AgentSession] {
        (1...count).map {
            AgentSession(worktreePath: "/wt/viterm/feat", presetName: "claude", displayName: "s\($0)")
        }
    }

    @Test("paneのtab順序でsessionをdisplay projectionする")
    func projectsPaneOrder() {
        let sessions = makeSessions(count: 3)
        let paneTabs = PaneTabs(
            tabIDs: [sessions[2].id, sessions[0].id, sessions[1].id],
            activeTabID: sessions[0].id
        )
        let viewModel = TabBarViewModel(paneTabs: paneTabs, sessions: sessions)

        #expect(viewModel.tabs.map(\.id) == [sessions[2].id, sessions[0].id, sessions[1].id])
        #expect(viewModel.activeTabID == sessions[0].id)
        #expect(viewModel.activeTab?.session == sessions[0])
    }

    @Test("shortcut番号はPaneTabsのslotから投影する")
    func projectsShortcutNumbers() {
        let sessions = makeSessions(count: 11)
        let paneTabs = PaneTabs(tabIDs: sessions.map(\.id), activeTabID: sessions[9].id)
        let viewModel = TabBarViewModel(paneTabs: paneTabs, sessions: sessions.reversed())

        #expect(viewModel.tabs.prefix(9).map(\.shortcutNumber) == Array(1...9))
        #expect(viewModel.tabs[9].shortcutNumber == nil)
        #expect(viewModel.tabs[10].shortcutNumber == nil)
    }

    @Test("存在しないsession IDは表示から除外するがactive IDはpane stateを保持する")
    func missingSessionValuesAreOmitted() {
        let sessions = makeSessions(count: 2)
        let missing = UUID()
        let paneTabs = PaneTabs(tabIDs: [sessions[0].id, missing], activeTabID: missing)
        let viewModel = TabBarViewModel(paneTabs: paneTabs, sessions: sessions)

        #expect(viewModel.tabs.map(\.id) == [sessions[0].id])
        #expect(viewModel.activeTabID == missing)
        #expect(viewModel.activeTab == nil)
    }
}
