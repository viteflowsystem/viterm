import Foundation

/// Which body the sidebar shows: the repository → worktree tree ("where do I work") or
/// the flat state lanes ("which session needs me"). Raw string is persisted in
/// `config.json` (`sidebarDisplayMode`); unknown values fall back to `.tree`.
public enum SidebarDisplayMode: String, Sendable, Codable, Equatable {
    case tree
    case state
}

/// One session card in the state lane view. Denormalized (repository name / branch)
/// so the flat lane list renders without tree lookups.
public struct StateLaneCard: Sendable, Equatable, Identifiable {
    public var id: AgentSession.ID
    public var sessionName: String
    public var state: AgentSession.State
    public var repositoryName: String
    public var branch: String
    public var worktreePath: String
    public var stateChangedAt: Date?

    public init(
        id: AgentSession.ID,
        sessionName: String,
        state: AgentSession.State,
        repositoryName: String,
        branch: String,
        worktreePath: String,
        stateChangedAt: Date?
    ) {
        self.id = id
        self.sessionName = sessionName
        self.state = state
        self.repositoryName = repositoryName
        self.branch = branch
        self.worktreePath = worktreePath
        self.stateChangedAt = stateChangedAt
    }
}

/// All sessions grouped by state for the lane view (waiting-input / busy / idle).
public struct SidebarStateLanes: Sendable, Equatable {
    public var waiting: [StateLaneCard]
    public var busy: [StateLaneCard]
    public var idle: [StateLaneCard]

    public init(waiting: [StateLaneCard] = [], busy: [StateLaneCard] = [], idle: [StateLaneCard] = []) {
        self.waiting = waiting
        self.busy = busy
        self.idle = idle
    }
}
