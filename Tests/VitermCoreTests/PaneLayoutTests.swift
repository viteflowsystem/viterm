import Foundation
import Testing
@testable import VitermCore

@Suite("PaneLayout")
struct PaneLayoutTests {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()
    private let d = UUID()

    private func twoPaneLayout() -> (PaneLayout, PaneID, PaneID, SplitID) {
        let left = PaneID()
        let right = PaneID()
        let split = SplitID()
        let root = PaneLayoutNode.split(.init(
            id: split,
            orientation: .sideBySide,
            dividerPosition: 0.4,
            first: .pane(id: left, tabs: PaneTabs(tabIDs: [a, b], activeTabID: b)),
            second: .pane(id: right, tabs: PaneTabs.single(c))
        ))
        return (PaneLayout(root: root, focusedPaneID: left), left, right, split)
    }

    @Test("singlePaneとnewTabはroot/focus/active tabを構築する")
    func creationAndNewTabs() {
        var empty = PaneLayout()
        #expect(empty.isEmpty)
        #expect(empty.topology == PaneTopology(root: nil))
        empty.newTab(a)
        let pane = empty.paneIDs[0]
        #expect(empty.focusedPaneID == pane)
        #expect(empty.tabs(of: pane) == .single(a))

        empty.newTab(b)
        #expect(empty.tabs(of: pane)?.tabIDs == [a, b])
        #expect(empty.focusedTabs?.activeTabID == b)
    }

    @Test("depth-first pane/split IDsとstructure-only topologyを返す")
    func traversalAndTopology() {
        let (layout, left, right, split) = twoPaneLayout()
        #expect(layout.paneIDs == [left, right])
        #expect(layout.splitIDs == [split])
        #expect(layout.topology == PaneTopology(root: .split(
            id: split,
            orientation: .sideBySide,
            first: .pane(left),
            second: .pane(right)
        )))
        #expect(layout.paneID(containing: b) == left)
        #expect(layout.paneID(containing: c) == right)
        #expect(layout.activeTabIDs == [b, c])
    }

    @Test("focusSession/focusPane/focusNextPaneはpane単位で選択する")
    func focusOperations() {
        var (layout, left, right, _) = twoPaneLayout()
        let focused = layout.focusSession(a)
        #expect(focused)
        #expect(layout.focusedPaneID == left)
        #expect(layout.focusedTabs?.activeTabID == a)
        let missing = layout.focusSession(UUID())
        #expect(!missing)
        layout.focusPane(right)
        #expect(layout.focusedPaneID == right)
        layout.focusNextPane()
        #expect(layout.focusedPaneID == left)
        layout.focusPane(PaneID())
        #expect(layout.focusedPaneID == left)
    }

    @Test("closeTabは空paneをcollapseしpromoted siblingへfocusする")
    func closingCollapsesEmptyPane() {
        var (layout, left, right, _) = twoPaneLayout()
        layout.focusPane(right)
        let becameEmpty = layout.closeTab(c)
        #expect(!becameEmpty)
        #expect(layout.paneIDs == [left])
        #expect(layout.splitIDs.isEmpty)
        #expect(layout.focusedPaneID == left)
        #expect(layout.tabs(of: left)?.tabIDs == [a, b])
        let missingBecameEmpty = layout.closeTab(UUID())
        #expect(!missingBecameEmpty)
    }

    @Test("最後のtabを閉じるとlayoutが空になる")
    func closingLastTabEmptiesLayout() {
        var layout = PaneLayout.singlePane(tabIDs: [a], activeTabID: a)
        let becameEmpty = layout.closeTab(a)
        #expect(becameEmpty)
        #expect(layout.root == nil)
        #expect(layout.focusedPaneID == nil)
    }

    @Test("dividerは0.05...0.95へclampしunknown splitを無視する")
    func dividerPosition() {
        var (layout, _, _, split) = twoPaneLayout()
        layout.setDividerPosition(-1, forSplit: split)
        guard case .split(let low) = layout.root else {
            Issue.record("Expected split root")
            return
        }
        #expect(low.dividerPosition == 0.05)
        layout.setDividerPosition(2, forSplit: split)
        guard case .split(let high) = layout.root else {
            Issue.record("Expected split root")
            return
        }
        #expect(high.dividerPosition == 0.95)
        let before = layout
        layout.setDividerPosition(0.2, forSplit: SplitID())
        #expect(layout == before)
    }

    @Test("splitPaneはedgeに対応するorientation/orderで0.5分割する")
    func splitDirections() {
        for (edge, orientation, newFirst) in [
            (PaneDropMath.Edge.left, SplitOrientation.sideBySide, true),
            (.right, .sideBySide, false),
            (.up, .stacked, true),
            (.down, .stacked, false),
        ] {
            var layout = PaneLayout.singlePane(tabIDs: [a], activeTabID: a)
            let originalPane = layout.paneIDs[0]
            let newPane = layout.splitPane(originalPane, edge: edge, with: b)
            guard case .split(let split) = layout.root else {
                Issue.record("Expected split root")
                continue
            }
            #expect(split.orientation == orientation)
            #expect(split.dividerPosition == 0.5)
            #expect(layout.paneIDs == (newFirst ? [newPane, originalPane] : [originalPane, newPane]))
            #expect(layout.focusedPaneID == newPane)
            #expect(layout.tabs(of: newPane) == .single(b))
        }
    }

    @Test("dropTabはpane間移動/reorder/center appendを統一する")
    func dropTargets() {
        var (layout, left, right, _) = twoPaneLayout()
        layout.dropTab(a, on: .tabBar(paneID: right, insertIndex: 0))
        #expect(layout.tabs(of: left)?.tabIDs == [b])
        #expect(layout.tabs(of: right)?.tabIDs == [a, c])
        #expect(layout.focusedPaneID == right)
        #expect(layout.focusedTabs?.activeTabID == a)

        layout.dropTab(a, on: .paneBody(paneID: left, zone: .center))
        #expect(layout.tabs(of: left)?.tabIDs == [b, a])
        #expect(layout.tabs(of: right)?.tabIDs == [c])
        #expect(layout.focusedPaneID == left)
    }

    @Test("同一paneのbackground tab並べ替えはactive tabとpane focusを維持する")
    func samePaneReorderPreservesActivationAndFocus() {
        var (layout, left, right, _) = twoPaneLayout()
        layout.focusPane(right)

        layout.dropTab(a, on: .tabBar(paneID: left, insertIndex: 1))

        #expect(layout.tabs(of: left)?.tabIDs == [b, a])
        #expect(layout.tabs(of: left)?.activeTabID == b)
        #expect(layout.focusedPaneID == right)
    }

    @Test("pane間tab dropは移動tabをactivateして移動先paneをfocusする")
    func crossPaneDropActivatesMovedTabAndDestination() {
        var (layout, left, right, _) = twoPaneLayout()

        layout.dropTab(a, on: .tabBar(paneID: right, insertIndex: 0))

        #expect(layout.tabs(of: left)?.tabIDs == [b])
        #expect(layout.tabs(of: right)?.tabIDs == [a, c])
        #expect(layout.tabs(of: right)?.activeTabID == a)
        #expect(layout.focusedPaneID == right)
    }

    @Test("dropの往復で元のlayoutへ完全に戻る")
    func dropRoundTripIsReversible() {
        var (layout, left, right, _) = twoPaneLayout()
        let focused = layout.focusSession(a)
        #expect(focused)
        let original = layout
        layout.dropTab(a, on: .tabBar(paneID: right, insertIndex: 0))
        layout.dropTab(a, on: .tabBar(paneID: left, insertIndex: 0))
        #expect(layout == original)
    }

    @Test("sole tabのself-dropは全zone/slotでlayoutを完全に保持する")
    func soleTabSelfDropIsExactNoOp() {
        let layout = PaneLayout.singlePane(tabIDs: [a], activeTabID: a)
        let pane = layout.paneIDs[0]
        let targets: [PaneDropTarget] = [
            .tabBar(paneID: pane, insertIndex: 0),
            .paneBody(paneID: pane, zone: .center),
            .paneBody(paneID: pane, zone: .edge(.left)),
            .paneBody(paneID: pane, zone: .edge(.right)),
            .paneBody(paneID: pane, zone: .edge(.up)),
            .paneBody(paneID: pane, zone: .edge(.down)),
        ]
        for target in targets {
            var candidate = layout
            candidate.dropTab(a, on: target)
            #expect(candidate == layout)
        }
    }

    @Test("detachでtarget paneが消えるdropとinvalid targetは元を完全復元する")
    func vanishedAndInvalidTargetsRestoreOriginal() {
        var (layout, _, right, _) = twoPaneLayout()
        let original = layout
        layout.dropTab(c, on: .paneBody(paneID: right, zone: .edge(.left)))
        #expect(layout == original)
        layout.dropTab(a, on: .tabBar(paneID: PaneID(), insertIndex: 0))
        #expect(layout == original)
    }

    @Test("edge dropはsourceをdetach/collapseしてtargetをsplitする")
    func edgeDropCollapsesAndSplits() {
        var (layout, left, right, _) = twoPaneLayout()
        layout.dropTab(c, on: .paneBody(paneID: left, zone: .edge(.up)))
        #expect(layout.paneIDs.count == 2)
        #expect(layout.paneID(containing: c) != right)
        #expect(layout.focusedTabs == .single(c))
        guard case .split(let split) = layout.root else {
            Issue.record("Expected split root")
            return
        }
        #expect(split.orientation == .stacked)
        #expect(split.dividerPosition == 0.5)
    }

    @Test("fresh session dropと空layout splitを扱う")
    func freshSessions() {
        var (layout, _, right, _) = twoPaneLayout()
        layout.dropTab(d, on: .paneBody(paneID: right, zone: .center))
        #expect(layout.tabs(of: right)?.tabIDs == [c, d])

        var empty = PaneLayout()
        let pane = empty.splitPane(edge: .right, with: a)
        #expect(empty.paneIDs == [pane])
        #expect(empty.tabs(of: pane) == .single(a))
    }

    @Test("PaneLayout/NodeはCodableで往復できる")
    func codableRoundTrip() throws {
        let (layout, _, _, _) = twoPaneLayout()
        let decoded = try JSONDecoder().decode(PaneLayout.self, from: JSONEncoder().encode(layout))
        #expect(decoded == layout)
    }
}
