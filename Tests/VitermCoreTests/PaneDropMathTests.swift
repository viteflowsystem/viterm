import CoreGraphics
import Testing
@testable import VitermCore

@Suite("PaneDropMath")
struct PaneDropMathTests {
    private let rect = CGRect(x: 10, y: 20, width: 100, height: 80)

    @Test("各辺に近い点は対応する方向になる")
    func nearestEdges() {
        #expect(PaneDropMath.edge(for: CGPoint(x: 11, y: 60), in: rect) == .left)
        #expect(PaneDropMath.edge(for: CGPoint(x: 109, y: 60), in: rect) == .right)
        #expect(PaneDropMath.edge(for: CGPoint(x: 60, y: 99), in: rect) == .up)
        #expect(PaneDropMath.edge(for: CGPoint(x: 60, y: 21), in: rect) == .down)
    }

    @Test("中心の同距離は候補順のleftになる")
    func centerTieBreaksLeft() {
        let square = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(PaneDropMath.edge(for: CGPoint(x: 50, y: 50), in: square) == .left)
    }

    @Test("退化した矩形は方向を返さない")
    func degenerateRect() {
        #expect(PaneDropMath.edge(for: .zero, in: CGRect(x: 0, y: 0, width: 0, height: 10)) == nil)
        #expect(PaneDropMath.edge(for: .zero, in: CGRect(x: 0, y: 0, width: 10, height: 0)) == nil)
    }

    @Test("各方向は矩形の対応する半分を返す")
    func halfRects() {
        #expect(PaneDropMath.halfRect(for: .left, in: rect) == CGRect(x: 10, y: 20, width: 50, height: 80))
        #expect(PaneDropMath.halfRect(for: .right, in: rect) == CGRect(x: 60, y: 20, width: 50, height: 80))
        #expect(PaneDropMath.halfRect(for: .up, in: rect) == CGRect(x: 10, y: 60, width: 100, height: 40))
        #expect(PaneDropMath.halfRect(for: .down, in: rect) == CGRect(x: 10, y: 20, width: 100, height: 40))
    }

    @Test("oppositeは各方向の反対側を返す")
    func oppositeEdges() {
        #expect(PaneDropMath.Edge.left.opposite == .right)
        #expect(PaneDropMath.Edge.right.opposite == .left)
        #expect(PaneDropMath.Edge.up.opposite == .down)
        #expect(PaneDropMath.Edge.down.opposite == .up)
    }

    @Test("境界付近では現在方向を維持し明確に近い辺へは切り替える")
    func edgeHysteresis() {
        let square = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(PaneDropMath.edge(
            for: CGPoint(x: 46, y: 50),
            in: square,
            current: .down
        ) == .down)
        #expect(PaneDropMath.edge(
            for: CGPoint(x: 20, y: 50),
            in: square,
            current: .down
        ) == .left)
    }

    @Test("nearestIndexは空・同距離・完全一致を扱う")
    func nearestIndices() {
        #expect(PaneDropMath.nearestIndex(to: 2, in: []) == nil)
        #expect(PaneDropMath.nearestIndex(to: 2, in: [1, 3]) == 3)
        #expect(PaneDropMath.nearestIndex(to: 2, in: [0, 2, 4]) == 2)
    }
}
