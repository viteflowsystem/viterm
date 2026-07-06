import Foundation

/// A single session row in the sidebar.
public struct SessionNode: Sendable, Equatable, Identifiable {
    public var session: AgentSession
    /// Number assigned to ⌘1..9. Only the first 9 sessions in sidebar display order have one (`nil` from the 10th on).
    public var shortcutNumber: Int?

    public var id: UUID { session.id }
}

/// A single worktree row in the sidebar (including its child sessions).
public struct WorktreeNode: Sendable, Equatable, Identifiable {
    public var worktree: Worktree
    public var sessions: [SessionNode]

    public var id: String { worktree.id }
}

/// A single repository row in the sidebar (including its child worktrees).
public struct RepositoryNode: Sendable, Equatable, Identifiable {
    public var repository: Repository
    public var worktrees: [WorktreeNode]

    public var id: String { repository.id }

    /// Number of waitingInput sessions underneath (across all worktrees).
    /// Used for the badge shown when the repository is collapsed.
    public var waitingSessionCount: Int {
        worktrees.reduce(0) { count, worktree in
            count + worktree.sessions.count { $0.session.state == .waitingInput }
        }
    }
}

/// Counts of busy / waitingInput / idle sessions (for the status bar display).
public struct SessionStateSummary: Sendable, Equatable {
    public var busy: Int
    public var waitingInput: Int
    public var idle: Int

    public init(busy: Int = 0, waitingInput: Int = 0, idle: Int = 0) {
        self.busy = busy
        self.waitingInput = waitingInput
        self.idle = idle
    }

    public var total: Int { busy + waitingInput + idle }
}
