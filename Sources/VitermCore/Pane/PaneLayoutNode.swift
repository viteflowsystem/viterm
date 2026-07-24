import Foundation

public struct PaneID: Hashable, Sendable, Codable {
    public let raw: UUID

    public init(_ raw: UUID = UUID()) {
        self.raw = raw
    }
}

public struct SplitID: Hashable, Sendable, Codable {
    public let raw: UUID

    public init(_ raw: UUID = UUID()) {
        self.raw = raw
    }
}

public enum SplitOrientation: Sendable, Equatable, Codable {
    case sideBySide
    case stacked
}

public indirect enum PaneLayoutNode: Sendable, Equatable, Codable {
    case pane(id: PaneID, tabs: PaneTabs)
    case split(Split)

    public struct Split: Sendable, Equatable, Codable {
        public var id: SplitID
        public var orientation: SplitOrientation
        public var dividerPosition: Double
        public var first: PaneLayoutNode
        public var second: PaneLayoutNode

        public init(
            id: SplitID = SplitID(),
            orientation: SplitOrientation,
            dividerPosition: Double,
            first: PaneLayoutNode,
            second: PaneLayoutNode
        ) {
            self.id = id
            self.orientation = orientation
            self.dividerPosition = dividerPosition
            self.first = first
            self.second = second
        }
    }
}

/// Structure-only signature used to decide whether a pane renderer needs rebuilding.
public struct PaneTopology: Sendable, Equatable {
    public indirect enum Node: Sendable, Equatable {
        case pane(PaneID)
        case split(
            id: SplitID,
            orientation: SplitOrientation,
            first: Node,
            second: Node
        )
    }

    public var root: Node?

    public init(root: Node?) {
        self.root = root
    }
}
