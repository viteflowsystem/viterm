import Foundation

public enum PaneDropTarget: Sendable, Equatable {
    case tabBar(paneID: PaneID, insertIndex: Int)
    case paneBody(paneID: PaneID, zone: PaneDropMath.DropZone)
}

/// The pane tree and pane-owned tab state for one worktree.
public struct PaneLayout: Sendable, Equatable, Codable {
    public private(set) var root: PaneLayoutNode?
    public private(set) var focusedPaneID: PaneID?

    public init() {
        root = nil
        focusedPaneID = nil
    }

    public init(root: PaneLayoutNode?, focusedPaneID: PaneID?) {
        self.root = root
        let ids = Self.paneIDs(in: root)
        self.focusedPaneID = focusedPaneID.flatMap { ids.contains($0) ? $0 : nil }
            ?? ids.first
    }

    public static func singlePane(
        tabIDs: [AgentSession.ID],
        activeTabID: AgentSession.ID?
    ) -> PaneLayout {
        guard !tabIDs.isEmpty else { return PaneLayout() }
        let paneID = PaneID()
        return PaneLayout(
            root: .pane(id: paneID, tabs: PaneTabs(tabIDs: tabIDs, activeTabID: activeTabID)),
            focusedPaneID: paneID
        )
    }

    public var isEmpty: Bool { root == nil }
    public var paneIDs: [PaneID] { Self.paneIDs(in: root) }
    public var splitIDs: [SplitID] { Self.splitIDs(in: root) }

    public func tabs(of paneID: PaneID) -> PaneTabs? {
        Self.tabs(of: paneID, in: root)
    }

    public func paneID(containing sessionID: AgentSession.ID) -> PaneID? {
        Self.paneID(containing: sessionID, in: root)
    }

    public var focusedTabs: PaneTabs? {
        focusedPaneID.flatMap { tabs(of: $0) }
    }

    public var activeTabIDs: Set<AgentSession.ID> {
        Set(paneIDs.compactMap { tabs(of: $0)?.activeTabID })
    }

    public var topology: PaneTopology {
        PaneTopology(root: Self.topologyNode(of: root))
    }

    public mutating func newTab(
        _ sessionID: AgentSession.ID,
        in paneID: PaneID? = nil
    ) {
        if root == nil {
            let newPaneID = PaneID()
            root = .pane(id: newPaneID, tabs: .single(sessionID))
            focusedPaneID = newPaneID
            return
        }
        let target = paneID.flatMap { tabs(of: $0) != nil ? $0 : nil }
            ?? focusedPaneID
            ?? paneIDs.first
        guard let target else { return }
        _ = Self.updatePane(target, in: &root) { tabs in
            tabs.append(sessionID)
        }
        focusedPaneID = target
    }

    @discardableResult
    public mutating func closeTab(_ sessionID: AgentSession.ID) -> Bool {
        let oldFocusedPaneID = focusedPaneID
        let result = Self.removing(sessionID, from: root)
        guard result.found else { return isEmpty }
        root = result.node
        let remainingPaneIDs = paneIDs
        if let oldFocusedPaneID, remainingPaneIDs.contains(oldFocusedPaneID) {
            focusedPaneID = oldFocusedPaneID
        } else {
            focusedPaneID = remainingPaneIDs.first
        }
        return isEmpty
    }

    @discardableResult
    public mutating func focusSession(_ sessionID: AgentSession.ID) -> Bool {
        guard let paneID = paneID(containing: sessionID) else { return false }
        _ = Self.updatePane(paneID, in: &root) { tabs in
            tabs.select(sessionID)
        }
        focusedPaneID = paneID
        return true
    }

    public mutating func dropTab(_ sessionID: AgentSession.ID, on target: PaneDropTarget) {
        let original = self
        let sourcePaneID = paneID(containing: sessionID)
        if let sourcePaneID,
           sourcePaneID == target.paneID,
           tabs(of: sourcePaneID)?.tabIDs.count == 1 {
            return
        }

        let removal = Self.removing(sessionID, from: root)
        root = removal.node
        if focusedPaneID.map({ !paneIDs.contains($0) }) == true {
            focusedPaneID = paneIDs.first
        }

        guard tabs(of: target.paneID) != nil else {
            self = original
            return
        }

        switch target {
        case .tabBar(let paneID, let insertIndex):
            _ = Self.updatePane(paneID, in: &root) { tabs in
                tabs.insert(sessionID, at: insertIndex)
            }
            focusedPaneID = paneID
        case .paneBody(let paneID, .center):
            _ = Self.updatePane(paneID, in: &root) { tabs in
                tabs.append(sessionID)
            }
            focusedPaneID = paneID
        case .paneBody(let paneID, .edge(let edge)):
            _ = splitPane(paneID, edge: edge, with: sessionID)
        }
    }

    @discardableResult
    public mutating func splitPane(
        _ paneID: PaneID? = nil,
        edge: PaneDropMath.Edge,
        with newSessionID: AgentSession.ID
    ) -> PaneID {
        if root == nil {
            let newPaneID = PaneID()
            root = .pane(id: newPaneID, tabs: .single(newSessionID))
            focusedPaneID = newPaneID
            return newPaneID
        }

        let targetPaneID = paneID.flatMap { tabs(of: $0) != nil ? $0 : nil }
            ?? focusedPaneID
            ?? paneIDs[0]
        let newPaneID = PaneID()
        let orientation: SplitOrientation
        let newFirst: Bool
        switch edge {
        case .left:
            orientation = .sideBySide
            newFirst = true
        case .right:
            orientation = .sideBySide
            newFirst = false
        case .up:
            orientation = .stacked
            newFirst = true
        case .down:
            orientation = .stacked
            newFirst = false
        }
        let newPane = PaneLayoutNode.pane(id: newPaneID, tabs: .single(newSessionID))
        _ = Self.replacePane(targetPaneID, in: &root) { existing in
            .split(.init(
                orientation: orientation,
                dividerPosition: 0.5,
                first: newFirst ? newPane : existing,
                second: newFirst ? existing : newPane
            ))
        }
        focusedPaneID = newPaneID
        return newPaneID
    }

    public mutating func focusPane(_ paneID: PaneID) {
        guard tabs(of: paneID) != nil else { return }
        focusedPaneID = paneID
    }

    public mutating func focusNextPane() {
        let ids = paneIDs
        guard ids.count > 1 else { return }
        let index = focusedPaneID.flatMap { ids.firstIndex(of: $0) } ?? -1
        focusedPaneID = ids[(index + 1 + ids.count) % ids.count]
    }

    public mutating func setDividerPosition(_ position: Double, forSplit splitID: SplitID) {
        _ = Self.updateSplit(splitID, in: &root) { split in
            split.dividerPosition = min(max(position, 0.05), 0.95)
        }
    }
}

private extension PaneDropTarget {
    var paneID: PaneID {
        switch self {
        case .tabBar(let paneID, _), .paneBody(let paneID, _):
            paneID
        }
    }
}

private extension PaneLayout {
    static func paneIDs(in node: PaneLayoutNode?) -> [PaneID] {
        guard let node else { return [] }
        switch node {
        case .pane(let id, _):
            return [id]
        case .split(let split):
            return paneIDs(in: split.first) + paneIDs(in: split.second)
        }
    }

    static func splitIDs(in node: PaneLayoutNode?) -> [SplitID] {
        guard let node else { return [] }
        switch node {
        case .pane:
            return []
        case .split(let split):
            return [split.id] + splitIDs(in: split.first) + splitIDs(in: split.second)
        }
    }

    static func tabs(of paneID: PaneID, in node: PaneLayoutNode?) -> PaneTabs? {
        guard let node else { return nil }
        switch node {
        case .pane(let id, let tabs):
            return id == paneID ? tabs : nil
        case .split(let split):
            return tabs(of: paneID, in: split.first) ?? tabs(of: paneID, in: split.second)
        }
    }

    static func paneID(
        containing sessionID: AgentSession.ID,
        in node: PaneLayoutNode?
    ) -> PaneID? {
        guard let node else { return nil }
        switch node {
        case .pane(let id, let tabs):
            return tabs.tabIDs.contains(sessionID) ? id : nil
        case .split(let split):
            return paneID(containing: sessionID, in: split.first)
                ?? paneID(containing: sessionID, in: split.second)
        }
    }

    static func topologyNode(of node: PaneLayoutNode?) -> PaneTopology.Node? {
        guard let node else { return nil }
        switch node {
        case .pane(let id, _):
            return .pane(id)
        case .split(let split):
            return .split(
                id: split.id,
                orientation: split.orientation,
                first: topologyNode(of: split.first)!,
                second: topologyNode(of: split.second)!
            )
        }
    }

    static func updatePane(
        _ paneID: PaneID,
        in node: inout PaneLayoutNode?,
        update: (inout PaneTabs) -> Void
    ) -> Bool {
        guard var current = node else { return false }
        let found = updatePane(paneID, in: &current, update: update)
        node = current
        return found
    }

    static func updatePane(
        _ paneID: PaneID,
        in node: inout PaneLayoutNode,
        update: (inout PaneTabs) -> Void
    ) -> Bool {
        switch node {
        case .pane(let id, var tabs):
            guard id == paneID else { return false }
            update(&tabs)
            node = .pane(id: id, tabs: tabs)
            return true
        case .split(var split):
            if updatePane(paneID, in: &split.first, update: update)
                || updatePane(paneID, in: &split.second, update: update) {
                node = .split(split)
                return true
            }
            return false
        }
    }

    static func replacePane(
        _ paneID: PaneID,
        in node: inout PaneLayoutNode?,
        replacement: (PaneLayoutNode) -> PaneLayoutNode
    ) -> Bool {
        guard var current = node else { return false }
        let found = replacePane(paneID, in: &current, replacement: replacement)
        node = current
        return found
    }

    static func replacePane(
        _ paneID: PaneID,
        in node: inout PaneLayoutNode,
        replacement: (PaneLayoutNode) -> PaneLayoutNode
    ) -> Bool {
        switch node {
        case .pane(let id, _):
            guard id == paneID else { return false }
            node = replacement(node)
            return true
        case .split(var split):
            if replacePane(paneID, in: &split.first, replacement: replacement)
                || replacePane(paneID, in: &split.second, replacement: replacement) {
                node = .split(split)
                return true
            }
            return false
        }
    }

    static func updateSplit(
        _ splitID: SplitID,
        in node: inout PaneLayoutNode?,
        update: (inout PaneLayoutNode.Split) -> Void
    ) -> Bool {
        guard var current = node else { return false }
        let found = updateSplit(splitID, in: &current, update: update)
        node = current
        return found
    }

    static func updateSplit(
        _ splitID: SplitID,
        in node: inout PaneLayoutNode,
        update: (inout PaneLayoutNode.Split) -> Void
    ) -> Bool {
        guard case .split(var split) = node else { return false }
        if split.id == splitID {
            update(&split)
            node = .split(split)
            return true
        }
        if updateSplit(splitID, in: &split.first, update: update)
            || updateSplit(splitID, in: &split.second, update: update) {
            node = .split(split)
            return true
        }
        return false
    }

    static func removing(
        _ sessionID: AgentSession.ID,
        from node: PaneLayoutNode?
    ) -> (node: PaneLayoutNode?, found: Bool) {
        guard let node else { return (nil, false) }
        switch node {
        case .pane(let id, var tabs):
            guard tabs.tabIDs.contains(sessionID) else { return (node, false) }
            let empty = tabs.remove(sessionID)
            return (empty ? nil : .pane(id: id, tabs: tabs), true)
        case .split(var split):
            let firstResult = removing(sessionID, from: split.first)
            if firstResult.found {
                guard let first = firstResult.node else { return (split.second, true) }
                split.first = first
                return (.split(split), true)
            }
            let secondResult = removing(sessionID, from: split.second)
            if secondResult.found {
                guard let second = secondResult.node else { return (split.first, true) }
                split.second = second
                return (.split(split), true)
            }
            return (.split(split), false)
        }
    }
}
