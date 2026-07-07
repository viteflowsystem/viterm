import Foundation

/// One session row in the sidebar.
public struct SessionNode: Sendable, Equatable, Identifiable {
    public var session: AgentSession
    /// The number assigned to ⌘1..9. Only the first 9 sessions in sidebar display order have one (`nil` from the 10th on).
    public var shortcutNumber: Int?

    public var id: UUID { session.id }
}

/// One worktree row in the sidebar (including its sessions).
public struct WorktreeNode: Sendable, Equatable, Identifiable {
    public var worktree: Worktree
    public var sessions: [SessionNode]

    public var id: String { worktree.id }

    /// Number of waitingInput sessions underneath. Used for the worktree row's waiting badge.
    public var waitingSessionCount: Int {
        sessions.count { $0.session.state == .waitingInput }
    }

    /// Tally of busy/waitingInput/idle counts for the sessions underneath.
    public var stateSummary: SessionStateSummary {
        SessionStateSummary(sessions: sessions.map(\.session))
    }

    /// The highest-priority state among the sessions underneath (waitingInput > busy > idle).
    /// Used to decide the representative color of the worktree row's roll-up dot. `nil` if there are no sessions.
    public var dominantState: AgentSession.State? {
        if sessions.contains(where: { $0.session.state == .waitingInput }) { return .waitingInput }
        if sessions.contains(where: { $0.session.state == .busy }) { return .busy }
        return sessions.isEmpty ? nil : .idle
    }
}

/// One repository row in the sidebar (including its worktrees).
public struct RepositoryNode: Sendable, Equatable, Identifiable {
    public var repository: Repository
    public var worktrees: [WorktreeNode]

    public var id: String { repository.id }

    /// Number of waitingInput sessions underneath (across all worktrees).
    /// Used for the badge when the repository is collapsed.
    public var waitingSessionCount: Int {
        worktrees.reduce(0) { count, worktree in
            count + worktree.sessions.count { $0.session.state == .waitingInput }
        }
    }
}

/// Tally of busy / waitingInput / idle counts (for status bar display).
public struct SessionStateSummary: Sendable, Equatable {
    public var busy: Int
    public var waitingInput: Int
    public var idle: Int

    public init(busy: Int = 0, waitingInput: Int = 0, idle: Int = 0) {
        self.busy = busy
        self.waitingInput = waitingInput
        self.idle = idle
    }

    /// Tally busy/waitingInput/idle counts from an array of sessions.
    public init(sessions: [AgentSession]) {
        self.init()
        for session in sessions {
            switch session.state {
            case .busy: busy += 1
            case .waitingInput: waitingInput += 1
            case .idle: idle += 1
            }
        }
    }

    public var total: Int { busy + waitingInput + idle }
}
