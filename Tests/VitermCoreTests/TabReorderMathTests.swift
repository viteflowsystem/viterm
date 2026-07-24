import CoreGraphics
import Testing
@testable import VitermCore

@Suite("TabReorderMath")
struct TabReorderMathTests {
    @Test("空配列では先頭スロットを返す")
    func emptyMidpoints() {
        #expect(TabReorderMath.insertionSlot(forDragX: 10, tabMidXs: []) == 0)
    }

    @Test("先頭より前と末尾より後のスロットを返す")
    func outerSlots() {
        let midpoints: [CGFloat] = [10, 20, 30]
        #expect(TabReorderMath.insertionSlot(forDragX: 0, tabMidXs: midpoints) == 0)
        #expect(TabReorderMath.insertionSlot(forDragX: 40, tabMidXs: midpoints) == 3)
    }

    @Test("タブ間とmidX境界のスロットを返す")
    func betweenAndExactBoundary() {
        let midpoints: [CGFloat] = [10, 20, 30]
        #expect(TabReorderMath.insertionSlot(forDragX: 15, tabMidXs: midpoints) == 1)
        #expect(TabReorderMath.insertionSlot(forDragX: 20, tabMidXs: midpoints) == 1)
        #expect(TabReorderMath.insertionSlot(forDragX: 21, tabMidXs: midpoints) == 2)
    }

    @Test("同じmidXがあってもstrict less-thanで安定する")
    func equalMidpoints() {
        #expect(TabReorderMath.insertionSlot(forDragX: 10, tabMidXs: [10, 10, 20]) == 0)
        #expect(TabReorderMath.insertionSlot(forDragX: 11, tabMidXs: [10, 10, 20]) == 2)
    }
}
