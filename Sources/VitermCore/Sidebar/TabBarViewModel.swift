import Foundation

/// Display-only projection of pane-owned tab state and session values.
public struct TabBarViewModel: Sendable, Equatable {
    public private(set) var tabs: [SessionNode]
    public private(set) var activeTabID: AgentSession.ID?

    public init(paneTabs: PaneTabs, sessions: [AgentSession.ID: AgentSession]) {
        tabs = paneTabs.tabIDs.compactMap { id in
            sessions[id].map {
                SessionNode(session: $0, shortcutNumber: paneTabs.shortcutNumber(for: id))
            }
        }
        activeTabID = paneTabs.activeTabID
    }

    public var activeTab: SessionNode? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }
}
