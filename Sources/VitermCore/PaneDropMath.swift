import CoreGraphics

/// Pure geometry helpers for directional pane drops.
public enum PaneDropMath {
    public enum Edge: Sendable, Equatable, CaseIterable {
        case left
        case right
        case up
        case down

        /// The edge opposite this edge.
        public var opposite: Edge {
            switch self {
            case .left: .right
            case .right: .left
            case .up: .down
            case .down: .up
            }
        }
    }

    public enum DropZone: Sendable, Equatable {
        case center
        case edge(Edge)
    }

    /// Width of the directional edge band used by pane-body drops.
    public static func edgeBandWidth(in rect: CGRect) -> CGFloat {
        max(80, 0.25 * min(rect.width, rect.height))
    }

    /// Returns one of four edge zones or the center zone for a point inside `rect`.
    public static func zone(
        for point: CGPoint,
        in rect: CGRect,
        current: DropZone? = nil
    ) -> DropZone? {
        guard rect.width > 0, rect.height > 0, rect.contains(point) else { return nil }
        let distances: [(Edge, CGFloat)] = [
            (.left, point.x - rect.minX),
            (.right, rect.maxX - point.x),
            (.up, rect.maxY - point.y),
            (.down, point.y - rect.minY),
        ]
        let band = edgeBandWidth(in: rect)
        let hysteresis = max(8, 0.05 * min(rect.width, rect.height))
        if case .edge(let edge) = current,
           let distance = distances.first(where: { $0.0 == edge })?.1,
           distance <= band + hysteresis {
            return .edge(edge)
        }
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 <= band else {
            return .center
        }
        return .edge(nearest.0)
    }

    /// Returns the nearest edge, retaining `current` within a small hysteresis zone.
    public static func edge(
        for point: CGPoint,
        in rect: CGRect,
        current: Edge? = nil
    ) -> Edge? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let candidates: [(Edge, CGFloat)] = [
            (.left, point.x - rect.minX),
            (.right, rect.maxX - point.x),
            (.up, rect.maxY - point.y),
            (.down, point.y - rect.minY),
        ]
        guard let nearest = candidates.min(by: { $0.1 < $1.1 }) else { return nil }
        if let current,
           let currentDistance = candidates.first(where: { $0.0 == current })?.1 {
            let hysteresis = max(8, 0.05 * min(rect.width, rect.height))
            if currentDistance <= nearest.1 + hysteresis {
                return current
            }
        }
        return nearest.0
    }

    /// Returns the candidate index nearest to `source`; ties prefer the larger index.
    public static func nearestIndex(to source: Int, in candidates: [Int]) -> Int? {
        candidates.reduce(nil as Int?) { best, candidate in
            guard let best else { return candidate }
            let candidateDistance = abs(candidate - source)
            let bestDistance = abs(best - source)
            if candidateDistance < bestDistance ||
                (candidateDistance == bestDistance && candidate > best) {
                return candidate
            }
            return best
        }
    }

    /// Returns the half of a pane occupied by a drop on the specified edge.
    public static func halfRect(for edge: Edge, in rect: CGRect) -> CGRect {
        switch edge {
        case .left:
            return CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .right:
            return CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .up:
            return CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
        case .down:
            return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
        }
    }
}
