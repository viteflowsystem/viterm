import CoreGraphics
import Testing
@testable import VitermCore

@Suite("PaneDropMath")
struct PaneDropMathTests {
    private let rect = CGRect(x: 10, y: 20, width: 100, height: 80)

    @Test("edge bandは短辺の25%または80ptの大きい方")
    func edgeBandWidth() {
        #expect(PaneDropMath.edgeBandWidth(in: CGRect(x: 0, y: 0, width: 400, height: 400)) == 100)
        #expect(PaneDropMath.edgeBandWidth(in: CGRect(x: 0, y: 0, width: 200, height: 100)) == 80)
    }

    @Test("5-zone APIはedge bandとcenterを区別する")
    func fiveZones() {
        let large = CGRect(x: 0, y: 0, width: 400, height: 400)
        #expect(PaneDropMath.zone(for: CGPoint(x: 20, y: 200), in: large) == .edge(.left))
        #expect(PaneDropMath.zone(for: CGPoint(x: 380, y: 200), in: large) == .edge(.right))
        #expect(PaneDropMath.zone(for: CGPoint(x: 200, y: 380), in: large) == .edge(.up))
        #expect(PaneDropMath.zone(for: CGPoint(x: 200, y: 20), in: large) == .edge(.down))
        #expect(PaneDropMath.zone(for: CGPoint(x: 200, y: 200), in: large) == .center)
    }

    @Test("zoneは矩形外と退化矩形でnil")
    func invalidZones() {
        #expect(PaneDropMath.zone(for: CGPoint(x: -1, y: 50), in: rect) == nil)
        #expect(PaneDropMath.zone(for: CGPoint(x: 111, y: 50), in: rect) == nil)
        #expect(PaneDropMath.zone(for: .zero, in: CGRect(x: 0, y: 0, width: 0, height: 10)) == nil)
        #expect(PaneDropMath.zone(for: .zero, in: CGRect(x: 0, y: 0, width: 10, height: 0)) == nil)
    }

    @Test("edge/center境界ではcurrent edgeをhysteresis幅まで維持する")
    func zoneHysteresis() {
        let large = CGRect(x: 0, y: 0, width: 400, height: 400)
        #expect(PaneDropMath.zone(
            for: CGPoint(x: 115, y: 200),
            in: large,
            current: .edge(.left)
        ) == .edge(.left))
        #expect(PaneDropMath.zone(
            for: CGPoint(x: 121, y: 200),
            in: large,
            current: .edge(.left)
        ) == .center)
        #expect(PaneDropMath.zone(
            for: CGPoint(x: 101, y: 200),
            in: large,
            current: .center
        ) == .center)
        #expect(PaneDropMath.zone(
            for: CGPoint(x: 99, y: 200),
            in: large,
            current: .center
        ) == .edge(.left))
    }

    @Test("各方向は矩形の対応する半分を返す")
    func halfRects() {
        #expect(PaneDropMath.halfRect(for: .left, in: rect) == CGRect(x: 10, y: 20, width: 50, height: 80))
        #expect(PaneDropMath.halfRect(for: .right, in: rect) == CGRect(x: 60, y: 20, width: 50, height: 80))
        #expect(PaneDropMath.halfRect(for: .up, in: rect) == CGRect(x: 10, y: 60, width: 100, height: 40))
        #expect(PaneDropMath.halfRect(for: .down, in: rect) == CGRect(x: 10, y: 20, width: 100, height: 40))
    }
}
