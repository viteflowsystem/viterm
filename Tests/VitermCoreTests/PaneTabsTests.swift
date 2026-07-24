import Foundation
import Testing
@testable import VitermCore

@Suite("PaneTabs")
struct PaneTabsTests {
    private let ids = [UUID(), UUID(), UUID(), UUID(), UUID(), UUID(), UUID(), UUID(), UUID(), UUID()]

    @Test("初期化は有効なactive tabを保持し、無効またはnilなら未選択にする")
    func initializationNormalizesSelection() {
        #expect(PaneTabs(tabIDs: ids, activeTabID: ids[2]).activeTabID == ids[2])
        #expect(PaneTabs(tabIDs: ids, activeTabID: UUID()).activeTabID == nil)
        #expect(PaneTabs(tabIDs: ids).activeTabID == nil)
        #expect(PaneTabs(tabIDs: []).activeTabID == nil)
    }

    @Test("直接選択と1-basedショートカットは有効なIDだけを選ぶ")
    func directAndShortcutSelection() {
        var tabs = PaneTabs(tabIDs: ids)
        let selected = tabs.select(ids[3])
        #expect(selected)
        #expect(tabs.activeTabID == ids[3])
        let missing = tabs.select(UUID())
        #expect(!missing)
        let shortcut = tabs.selectShortcut(9)
        #expect(shortcut)
        #expect(tabs.activeTabID == ids[8])
        let shortcutZero = tabs.selectShortcut(0)
        let shortcutTen = tabs.selectShortcut(10)
        #expect(!shortcutZero)
        #expect(!shortcutTen)
    }

    @Test("next/previousは循環し、空配列ではno-op")
    func cyclicSelection() {
        var tabs = PaneTabs(tabIDs: Array(ids.prefix(3)), activeTabID: ids[2])
        tabs.selectNext()
        #expect(tabs.activeTabID == ids[0])
        tabs.selectPrevious()
        #expect(tabs.activeTabID == ids[2])

        var empty = PaneTabs(tabIDs: [])
        empty.selectNext()
        empty.selectPrevious()
        #expect(empty.activeTabID == nil)
    }

    @Test("insert/appendはindexをclampし、挿入タブをactiveにする")
    func insertionAndAppend() {
        var tabs = PaneTabs(tabIDs: [ids[0]])
        tabs.insert(ids[1], at: -10)
        #expect(tabs.tabIDs == [ids[1], ids[0]])
        #expect(tabs.activeTabID == ids[1])
        tabs.append(ids[2])
        #expect(tabs.tabIDs == [ids[1], ids[0], ids[2]])
        #expect(tabs.activeTabID == ids[2])
        tabs.insert(ids[0], at: 99)
        #expect(tabs.tabIDs == [ids[1], ids[2], ids[0]])
    }

    @Test("moveWithinPaneは削除後indexへ移動しactive tabを維持する")
    func moveWithinPane() {
        var tabs = PaneTabs(tabIDs: Array(ids.prefix(4)), activeTabID: ids[1])
        tabs.moveWithinPane(ids[0], to: 3)
        #expect(tabs.tabIDs == [ids[1], ids[2], ids[3], ids[0]])
        #expect(tabs.activeTabID == ids[1])
        let original = tabs
        tabs.moveWithinPane(UUID(), to: 0)
        #expect(tabs == original)
    }

    @Test("active tab削除時は旧indexへshiftしたタブ、末尾なら新末尾を選ぶ")
    func removalUsesBrowserFallback() {
        var tabs = PaneTabs(tabIDs: Array(ids.prefix(4)), activeTabID: ids[1])
        let emptyAfterActiveRemoval = tabs.remove(ids[1])
        #expect(!emptyAfterActiveRemoval)
        #expect(tabs.tabIDs == [ids[0], ids[2], ids[3]])
        #expect(tabs.activeTabID == ids[2])
        let emptyAfterInactiveRemoval = tabs.remove(ids[3])
        #expect(!emptyAfterInactiveRemoval)
        #expect(tabs.activeTabID == ids[2])
        let emptyAfterMissingRemoval = tabs.remove(UUID())
        #expect(!emptyAfterMissingRemoval)

        var single = PaneTabs.single(ids[0])
        let singleBecameEmpty = single.remove(ids[0])
        #expect(singleBecameEmpty)
        #expect(single.isEmpty)
        #expect(single.activeTabID == nil)
    }

    @Test("ショートカット番号は先頭9件だけ")
    func shortcutNumbers() {
        let tabs = PaneTabs(tabIDs: ids)
        #expect(tabs.shortcutNumber(for: ids[0]) == 1)
        #expect(tabs.shortcutNumber(for: ids[8]) == 9)
        #expect(tabs.shortcutNumber(for: ids[9]) == nil)
        #expect(tabs.shortcutNumber(for: UUID()) == nil)
    }

    @Test("Codableで往復できる")
    func codableRoundTrip() throws {
        let tabs = PaneTabs(tabIDs: ids, activeTabID: ids[4])
        let decoded = try JSONDecoder().decode(PaneTabs.self, from: JSONEncoder().encode(tabs))
        #expect(decoded == tabs)
    }
}
