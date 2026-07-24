import Foundation

/// Display-only projection of pane-owned tab state and session values.
public struct TabBarViewModel: Sendable, Equatable {
    public private(set) var tabs: [SessionNode]
    public private(set) var activeTabID: AgentSession.ID?

    public init(paneTabs: PaneTabs, sessions: [AgentSession]) {
        let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        tabs = paneTabs.tabIDs.compactMap { id in
            sessionsByID[id].map {
                SessionNode(session: $0, shortcutNumber: paneTabs.shortcutNumber(for: id))
            }
        }
        activeTabID = paneTabs.activeTabID
    }

    /// - Parameters:
    ///   - sessions: Sessions belonging to the selected worktree. The order of this array is the tab order.
    ///   - activeTabID: The initial active tab. Passing an ID not in `sessions` is fine
    ///     (`activeTab` returns `nil`).
    @available(*, deprecated, message: "Use init(paneTabs:sessions:) instead.")
    public init(sessions: [AgentSession], activeTabID: AgentSession.ID? = nil) {
        self.tabs = Self.assignShortcuts(sessions: sessions)
        self.activeTabID = activeTabID
    }

    private static func assignShortcuts(sessions: [AgentSession]) -> [SessionNode] {
        sessions.enumerated().map { index, session in
            SessionNode(session: session, shortcutNumber: index < 9 ? index + 1 : nil)
        }
    }

    /// The currently active tab. `nil` if `activeTabID` is not in the tab list.
    public var activeTab: SessionNode? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    // MARK: - Selection management

    /// Select a tab directly. Passing `nil` clears the selection.
    @available(*, deprecated, message: "Mutate PaneTabs instead.")
    public mutating func selectTab(_ id: AgentSession.ID?) {
        activeTabID = id
    }

    /// Select the tab corresponding to ⌘1..9 (index+1 within the worktree). If there is none, does nothing and returns `false`.
    @discardableResult
    @available(*, deprecated, message: "Mutate PaneTabs instead.")
    public mutating func selectShortcut(_ number: Int) -> Bool {
        guard let tab = tabs.first(where: { $0.shortcutNumber == number }) else {
            return false
        }
        activeTabID = tab.id
        return true
    }

    /// Select the next tab (wrapping from last to first).
    /// If the current selection is not in the tab list, selects the first tab. Does nothing if there are no tabs.
    @available(*, deprecated, message: "Mutate PaneTabs instead.")
    public mutating func selectNext() {
        guard !tabs.isEmpty else { return }
        guard let currentID = activeTabID, let index = tabs.firstIndex(where: { $0.id == currentID }) else {
            activeTabID = tabs.first?.id
            return
        }
        activeTabID = tabs[(index + 1) % tabs.count].id
    }

    /// Select the previous tab (wrapping from first to last).
    /// If the current selection is not in the tab list, selects the last tab. Does nothing if there are no tabs.
    @available(*, deprecated, message: "Mutate PaneTabs instead.")
    public mutating func selectPrevious() {
        guard !tabs.isEmpty else { return }
        guard let currentID = activeTabID, let index = tabs.firstIndex(where: { $0.id == currentID }) else {
            activeTabID = tabs.last?.id
            return
        }
        activeTabID = tabs[(index - 1 + tabs.count) % tabs.count].id
    }
}
