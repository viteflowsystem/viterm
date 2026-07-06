import Foundation
import Testing
@testable import VitermCore

@Suite("TabBarViewModel")
struct TabBarViewModelTests {
    func makeSessions(count: Int, worktreePath: String = "/wt/viterm/feat") -> [AgentSession] {
        (1...count).map {
            AgentSession(worktreePath: worktreePath, presetName: "claude", displayName: "s\($0)")
        }
    }

    @Test("タブ局所のショートカット番号は先頭9件にのみ振られる")
    func shortcutNumbersAssignedToFirstNine() {
        let sessions = makeSessions(count: 11)
        let viewModel = TabBarViewModel(sessions: sessions)

        #expect(viewModel.tabs.count == 11)
        #expect(viewModel.tabs.prefix(9).map(\.shortcutNumber) == (1...9).map { $0 })
        #expect(viewModel.tabs[9].shortcutNumber == nil)
        #expect(viewModel.tabs[10].shortcutNumber == nil)
    }

    @Test("selectTabで直接選択でき、存在しないIDならactiveTabはnil")
    func selectTabAndActiveTab() {
        let sessions = makeSessions(count: 3)
        var viewModel = TabBarViewModel(sessions: sessions)
        let target = viewModel.tabs[1]

        viewModel.selectTab(target.id)
        #expect(viewModel.activeTab?.id == target.id)

        viewModel.selectTab(UUID())
        #expect(viewModel.activeTab == nil)
    }

    @Test("selectShortcutは対応する番号のタブを選択する")
    func selectShortcutSelectsCorrectTab() {
        let sessions = makeSessions(count: 5)
        var viewModel = TabBarViewModel(sessions: sessions)

        let ok = viewModel.selectShortcut(3)
        #expect(ok == true)
        #expect(viewModel.activeTabID == viewModel.tabs[2].id)

        let notFound = viewModel.selectShortcut(9)
        #expect(notFound == false, "5タブしかないので9番は存在しない")
    }

    @Test("selectNext/selectPreviousはworktree内で循環する")
    func selectNextAndPreviousWrapAround() {
        let sessions = makeSessions(count: 3)
        var viewModel = TabBarViewModel(sessions: sessions)
        let tabs = viewModel.tabs

        viewModel.selectTab(tabs[0].id)
        viewModel.selectNext()
        #expect(viewModel.activeTabID == tabs[1].id)

        viewModel.selectTab(tabs.last!.id)
        viewModel.selectNext()
        #expect(viewModel.activeTabID == tabs[0].id, "末尾から次へ進むと先頭に循環する")

        viewModel.selectTab(tabs[0].id)
        viewModel.selectPrevious()
        #expect(viewModel.activeTabID == tabs.last!.id, "先頭から前へ戻ると末尾に循環する")
    }

    @Test("タブが1件だけの場合、selectNext/selectPreviousは自分自身に循環する")
    func selectNextAndPreviousWithSingleTabStaysOnSelf() {
        let sessions = makeSessions(count: 1)
        var viewModel = TabBarViewModel(sessions: sessions)
        let onlyTab = viewModel.tabs[0]
        viewModel.selectTab(onlyTab.id)

        viewModel.selectNext()
        #expect(viewModel.activeTabID == onlyTab.id, "タブが1件だけなら次へ進んでも自分自身に留まる")

        viewModel.selectPrevious()
        #expect(viewModel.activeTabID == onlyTab.id, "タブが1件だけなら前へ戻っても自分自身に留まる")
    }

    @Test("選択が無い状態でselectNextを呼ぶと先頭が選ばれる")
    func selectNextWithNoSelectionPicksFirst() {
        let sessions = makeSessions(count: 3)
        var viewModel = TabBarViewModel(sessions: sessions)
        viewModel.selectNext()
        #expect(viewModel.activeTabID == viewModel.tabs.first?.id)
    }

    @Test("選択が無い状態でselectPreviousを呼ぶと末尾が選ばれる")
    func selectPreviousWithNoSelectionPicksLast() {
        let sessions = makeSessions(count: 3)
        var viewModel = TabBarViewModel(sessions: sessions)
        viewModel.selectPrevious()
        #expect(viewModel.activeTabID == viewModel.tabs.last?.id)
    }

    @Test("現在の選択がタブ列に無い場合、selectNextは先頭に、selectPreviousは末尾に飛ぶ")
    func selectNextAndPreviousRecoverFromStaleSelection() {
        let sessions = makeSessions(count: 3)
        var viewModel = TabBarViewModel(sessions: sessions, activeTabID: UUID())

        viewModel.selectNext()
        #expect(viewModel.activeTabID == viewModel.tabs.first?.id)

        viewModel.selectTab(UUID())
        viewModel.selectPrevious()
        #expect(viewModel.activeTabID == viewModel.tabs.last?.id)
    }

    @Test("タブが1件も無くてもselectNext/selectPrevious/selectShortcutはクラッシュしない")
    func emptyTabsIsNoOp() {
        var viewModel = TabBarViewModel(sessions: [])
        viewModel.selectNext()
        viewModel.selectPrevious()
        #expect(viewModel.selectShortcut(1) == false)
        #expect(viewModel.activeTabID == nil)
        #expect(viewModel.activeTab == nil)
    }
}
