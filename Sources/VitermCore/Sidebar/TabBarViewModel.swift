import Foundation

/// UI-independent state of the selected worktree's tab bar (= the ordering of its sessions).
///
/// Tab = session, 1:1. Where `SidebarViewModel` handles cross-worktree selection,
/// `TabBarViewModel` handles the tab-local concerns within a single worktree: ⌘1..9
/// numbering and active-tab selection/cycling.
///
/// A pure value type; it does no observation or incremental updates internally. Callers
/// are expected to re-call `init` (carrying over the previous `activeTabID`) whenever the
/// worktree switches or the session composition changes.
public struct TabBarViewModel: Sendable, Equatable {
    public private(set) var tabs: [SessionNode]
    public private(set) var activeTabID: AgentSession.ID?

    /// - Parameters:
    ///   - sessions: Sessions belonging to the selected worktree. The order of this array is the tab order.
    ///   - activeTabID: The initial active tab. Passing an ID not in `sessions` is fine
    ///     (`activeTab` returns `nil`).
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
    public mutating func selectTab(_ id: AgentSession.ID?) {
        activeTabID = id
    }

    /// Select the tab corresponding to ⌘1..9 (index+1 within the worktree). If there is none, does nothing and returns `false`.
    @discardableResult
    public mutating func selectShortcut(_ number: Int) -> Bool {
        guard let tab = tabs.first(where: { $0.shortcutNumber == number }) else {
            return false
        }
        activeTabID = tab.id
        return true
    }

    /// Select the next tab (wrapping from last to first).
    /// If the current selection is not in the tab list, selects the first tab. Does nothing if there are no tabs.
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
    public mutating func selectPrevious() {
        guard !tabs.isEmpty else { return }
        guard let currentID = activeTabID, let index = tabs.firstIndex(where: { $0.id == currentID }) else {
            activeTabID = tabs.last?.id
            return
        }
        activeTabID = tabs[(index - 1 + tabs.count) % tabs.count].id
    }
}
