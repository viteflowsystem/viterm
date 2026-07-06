import Foundation

/// UI-independent state of the sidebar (a 3-level tree: repository → worktree → session).
///
/// Builds the tree structure from flat arrays of `Repository` / `Worktree` / `AgentSession`,
/// and provides ⌘1..9 shortcut number assignment, waiting-badge aggregation for collapsed
/// repositories, state totals (busy/waiting/idle), and selected-session management
/// (next/previous navigation and the ⌘⇧U jump).
///
/// A pure value type; it performs no observation or incremental updates internally. Callers are
/// expected to re-call `init` (carrying over the previous `selectedSessionID`) whenever the
/// source data changes.
public struct SidebarViewModel: Sendable, Equatable {
    public private(set) var repositories: [RepositoryNode]
    public private(set) var selectedSessionID: AgentSession.ID?

    /// - Parameters:
    ///   - repositories: Repositories to show in the sidebar. The order of this array is the display order.
    ///   - worktrees: Worktrees for all repositories. Linked to their repository via `repositoryPath`.
    ///     Worktrees that match no repository do not appear in the tree.
    ///   - sessions: Sessions for all worktrees. Linked to their worktree via `worktreePath`.
    ///     Sessions that match no worktree do not appear in the tree.
    ///   - selectedSessionID: Initially selected session. Passing an ID not present in the tree
    ///     is fine (`selectedSession` returns `nil`).
    public init(
        repositories: [Repository],
        worktrees: [Worktree],
        sessions: [AgentSession],
        selectedSessionID: AgentSession.ID? = nil
    ) {
        self.repositories = Self.buildTree(repositories: repositories, worktrees: worktrees, sessions: sessions)
        self.selectedSessionID = selectedSessionID
    }

    private static func buildTree(
        repositories: [Repository],
        worktrees: [Worktree],
        sessions: [AgentSession]
    ) -> [RepositoryNode] {
        // `Dictionary(grouping:by:)` preserves the relative order of the source array while
        // grouping, so the order the caller passed (= sidebar display order) carries straight
        // through to the tree.
        let worktreesByRepository = Dictionary(grouping: worktrees, by: \.repositoryPath)
        let sessionsByWorktree = Dictionary(grouping: sessions, by: \.worktreePath)

        var shortcutCounter = 0

        return repositories.map { repository in
            let childWorktrees = (worktreesByRepository[repository.path] ?? []).map { worktree -> WorktreeNode in
                let childSessions = (sessionsByWorktree[worktree.path] ?? []).map { session -> SessionNode in
                    shortcutCounter += 1
                    let shortcutNumber = shortcutCounter <= 9 ? shortcutCounter : nil
                    return SessionNode(session: session, shortcutNumber: shortcutNumber)
                }
                return WorktreeNode(worktree: worktree, sessions: childSessions)
            }
            return RepositoryNode(repository: repository, worktrees: childWorktrees)
        }
    }

    /// Sessions across all repositories and worktrees, in display order.
    public var flattenedSessions: [SessionNode] {
        repositories.flatMap { $0.worktrees.flatMap(\.sessions) }
    }

    /// The currently selected session row. `nil` if `selectedSessionID` is not in the tree.
    public var selectedSession: SessionNode? {
        guard let selectedSessionID else { return nil }
        return flattenedSessions.first { $0.id == selectedSessionID }
    }

    /// Counts of busy/waitingInput/idle sessions (across repositories).
    public var stateSummary: SessionStateSummary {
        Self.summarize(sessions: flattenedSessions.map(\.session))
    }

    public static func summarize(sessions: [AgentSession]) -> SessionStateSummary {
        var summary = SessionStateSummary()
        for session in sessions {
            switch session.state {
            case .busy: summary.busy += 1
            case .waitingInput: summary.waitingInput += 1
            case .idle: summary.idle += 1
            }
        }
        return summary
    }

    // MARK: - Selection management

    /// Selects a session directly. Passing `nil` clears the selection.
    public mutating func select(sessionID: AgentSession.ID?) {
        selectedSessionID = sessionID
    }

    /// Selects the next session in display order (wraps from the last to the first).
    /// If the current selection is not in the tree, selects the first session. Does nothing if there are no sessions.
    public mutating func selectNext() {
        let flat = flattenedSessions
        guard !flat.isEmpty else { return }
        guard let currentID = selectedSessionID, let index = flat.firstIndex(where: { $0.id == currentID }) else {
            selectedSessionID = flat.first?.id
            return
        }
        selectedSessionID = flat[(index + 1) % flat.count].id
    }

    /// Selects the previous session in display order (wraps from the first to the last).
    public mutating func selectPrevious() {
        let flat = flattenedSessions
        guard !flat.isEmpty else { return }
        guard let currentID = selectedSessionID, let index = flat.firstIndex(where: { $0.id == currentID }) else {
            selectedSessionID = flat.last?.id
            return
        }
        selectedSessionID = flat[(index - 1 + flat.count) % flat.count].id
    }

    /// Selects the session assigned to ⌘1..9. If there is no match, does nothing and returns `false`.
    @discardableResult
    public mutating func selectShortcut(_ number: Int) -> Bool {
        guard let node = flattenedSessions.first(where: { $0.shortcutNumber == number }) else {
            return false
        }
        selectedSessionID = node.id
        return true
    }

    /// Equivalent of ⌘⇧U: jumps to the most recent waitingInput session.
    /// "Most recent" means the newest `AgentSession.stateChangedAt` (across repositories).
    /// Sessions without `stateChangedAt` are treated as the oldest. On ties, the one later in display order wins.
    /// If there is no waitingInput session, does nothing and returns `false`.
    @discardableResult
    public mutating func jumpToLatestWaiting() -> Bool {
        let waiting = flattenedSessions.enumerated().filter { $0.element.session.state == .waitingInput }
        guard let latest = waiting.max(by: { lhs, rhs in
            let lhsTime = lhs.element.session.stateChangedAt ?? .distantPast
            let rhsTime = rhs.element.session.stateChangedAt ?? .distantPast
            if lhsTime != rhsTime { return lhsTime < rhsTime }
            return lhs.offset < rhs.offset
        }) else {
            return false
        }
        selectedSessionID = latest.element.id
        return true
    }
}
