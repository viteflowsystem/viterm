import Foundation

/// Ordered tabs owned by one pane, including that pane's active tab.
public struct PaneTabs: Sendable, Equatable, Codable {
    public private(set) var tabIDs: [AgentSession.ID]
    public private(set) var activeTabID: AgentSession.ID?

    public init(tabIDs: [AgentSession.ID], activeTabID: AgentSession.ID? = nil) {
        self.tabIDs = tabIDs
        self.activeTabID = activeTabID.flatMap { tabIDs.contains($0) ? $0 : nil }
    }

    public static func single(_ sessionID: AgentSession.ID) -> PaneTabs {
        PaneTabs(tabIDs: [sessionID], activeTabID: sessionID)
    }

    public var isEmpty: Bool { tabIDs.isEmpty }

    @discardableResult
    public mutating func select(_ id: AgentSession.ID) -> Bool {
        guard tabIDs.contains(id) else { return false }
        activeTabID = id
        return true
    }

    @discardableResult
    public mutating func selectShortcut(_ number: Int) -> Bool {
        guard (1...9).contains(number), tabIDs.indices.contains(number - 1) else {
            return false
        }
        activeTabID = tabIDs[number - 1]
        return true
    }

    public mutating func selectNext() {
        guard !tabIDs.isEmpty else { return }
        guard let activeTabID, let index = tabIDs.firstIndex(of: activeTabID) else {
            self.activeTabID = tabIDs.first
            return
        }
        self.activeTabID = tabIDs[(index + 1) % tabIDs.count]
    }

    public mutating func selectPrevious() {
        guard !tabIDs.isEmpty else { return }
        guard let activeTabID, let index = tabIDs.firstIndex(of: activeTabID) else {
            self.activeTabID = tabIDs.last
            return
        }
        self.activeTabID = tabIDs[(index - 1 + tabIDs.count) % tabIDs.count]
    }

    public mutating func insert(_ id: AgentSession.ID, at index: Int) {
        if let existingIndex = tabIDs.firstIndex(of: id) {
            tabIDs.remove(at: existingIndex)
        }
        tabIDs.insert(id, at: min(max(index, 0), tabIDs.count))
        activeTabID = id
    }

    public mutating func append(_ id: AgentSession.ID) {
        insert(id, at: tabIDs.count)
    }

    public mutating func moveWithinPane(_ id: AgentSession.ID, to index: Int) {
        guard let sourceIndex = tabIDs.firstIndex(of: id) else { return }
        tabIDs.remove(at: sourceIndex)
        tabIDs.insert(id, at: min(max(index, 0), tabIDs.count))
    }

    @discardableResult
    public mutating func remove(_ id: AgentSession.ID) -> Bool {
        guard let index = tabIDs.firstIndex(of: id) else { return isEmpty }
        let wasActive = activeTabID == id
        tabIDs.remove(at: index)
        if tabIDs.isEmpty {
            activeTabID = nil
        } else if wasActive {
            activeTabID = tabIDs[min(index, tabIDs.count - 1)]
        }
        return tabIDs.isEmpty
    }

    public func shortcutNumber(for id: AgentSession.ID) -> Int? {
        guard let index = tabIDs.firstIndex(of: id), index < 9 else { return nil }
        return index + 1
    }
}
