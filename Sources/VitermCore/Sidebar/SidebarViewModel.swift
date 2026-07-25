import Foundation

/// UI-independent state of the sidebar (a three-level tree: repository → worktree → session).
///
/// Builds the tree from flat arrays of `Repository` / `Worktree` / `AgentSession`, and
/// provides waiting-badge aggregation for collapsed repositories, state tallies
/// (busy/waiting/idle), and worktree selection. Session selection belongs to
/// `PaneLayout`; the sidebar only exposes session queries.
///
/// A pure value type; it does no observation or incremental updates internally. Callers
/// are expected to re-call `init` each time the source data changes, carrying over
/// `selectedWorktreePath`, filter text, and display mode.
public struct SidebarViewModel: Sendable, Equatable {
    public private(set) var repositories: [RepositoryNode]
    public private(set) var selectedWorktreePath: String?
    /// Incremental filter over the tree (repo / branch / session names). Empty = no filtering.
    /// Ephemeral UI state: carried across rebuilds via `rebuilt(...)`, never persisted.
    public private(set) var filterText: String
    /// Which body the sidebar shows (tree / state lanes). Carried across rebuilds via
    /// `rebuilt(...)`; persisted to the global config by `AppModel`.
    public private(set) var displayMode: SidebarDisplayMode

    /// - Parameters:
    ///   - repositories: Repositories shown in the sidebar. The order of this array is the display order.
    ///   - worktrees: Worktrees for all repositories, tied to their repository via `repositoryPath`.
    ///     A worktree matching no repository does not appear in the tree.
    ///   - sessions: Sessions for all worktrees, tied to their worktree via `worktreePath`.
    ///     A session matching no worktree does not appear in the tree.
    ///   - selectedWorktreePath: Initially selected worktree. Passing a path not in the tree
    ///     is fine (`selectedWorktree` returns `nil`).
    ///   - filterText: The incremental filter text from before the rebuild.
    ///   - displayMode: The sidebar body mode (tree / state lanes) from before the rebuild.
    public init(
        repositories: [Repository],
        worktrees: [Worktree],
        sessions: [AgentSession],
        selectedWorktreePath: String? = nil,
        filterText: String = "",
        displayMode: SidebarDisplayMode = .tree
    ) {
        self.repositories = Self.buildTree(repositories: repositories, worktrees: worktrees, sessions: sessions)
        self.selectedWorktreePath = selectedWorktreePath
        self.filterText = filterText
        self.displayMode = displayMode
    }

    /// Rebuild the tree from fresh source data, carrying over every piece of sidebar UI
    /// state. `AppModel.rebuildSidebar()` must use this
    /// instead of `init` so that newly added UI-state fields have exactly one carry-over spot.
    public func rebuilt(
        repositories: [Repository],
        worktrees: [Worktree],
        sessions: [AgentSession]
    ) -> SidebarViewModel {
        SidebarViewModel(
            repositories: repositories,
            worktrees: worktrees,
            sessions: sessions,
            selectedWorktreePath: selectedWorktreePath,
            filterText: filterText,
            displayMode: displayMode
        )
    }

    private static func buildTree(
        repositories: [Repository],
        worktrees: [Worktree],
        sessions: [AgentSession]
    ) -> [RepositoryNode] {
        // `Dictionary(grouping:by:)` preserves the relative order of the source array, so
        // the order the caller passed in (= sidebar display order) carries into the tree as-is.
        let worktreesByRepository = Dictionary(grouping: worktrees, by: \.repositoryPath)
        let sessionsByWorktree = Dictionary(grouping: sessions, by: \.worktreePath)

        return repositories.map { repository in
            let childWorktrees = (worktreesByRepository[repository.path] ?? []).map { worktree -> WorktreeNode in
                // The sidebar has no session rows and ⌘1..9 is tab-local (TabBarViewModel's
                // role), so no numbers are assigned here.
                let childSessions = (sessionsByWorktree[worktree.path] ?? []).map { session in
                    SessionNode(session: session, shortcutNumber: nil)
                }
                return WorktreeNode(worktree: worktree, sessions: childSessions)
            }
            return RepositoryNode(repository: repository, worktrees: childWorktrees)
        }
    }

    // MARK: - Filtering

    /// Set the incremental filter text. Filtering only affects the derived
    /// `filteredRepositories`; selection is never cleared by filtering.
    public mutating func setFilterText(_ text: String) {
        filterText = text
    }

    /// The tree narrowed by `filterText` (case-insensitive substring match against
    /// repository name, worktree branch name, and session display name).
    ///
    /// Matching keeps ancestors: a matching repository keeps all its worktrees; a
    /// matching worktree (or a worktree containing a matching session) is kept with all
    /// its sessions. Session names are filterable even though the tree shows no session
    /// rows — the match keeps the owning worktree visible.
    /// Empty filter returns `repositories` unchanged (fast path).
    public var filteredRepositories: [RepositoryNode] {
        let needle = filterText.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return repositories }
        return repositories.compactMap { repository in
            if repository.repository.name.localizedCaseInsensitiveContains(needle) {
                return repository
            }
            let worktrees = repository.worktrees.filter { worktree in
                worktree.worktree.branch.localizedCaseInsensitiveContains(needle)
                    || worktree.sessions.contains { $0.session.displayName.localizedCaseInsensitiveContains(needle) }
            }
            guard !worktrees.isEmpty else { return nil }
            var narrowed = repository
            narrowed.worktrees = worktrees
            return narrowed
        }
    }

    // MARK: - State lanes

    /// Switch the sidebar body mode (tree / state lanes).
    public mutating func setDisplayMode(_ mode: SidebarDisplayMode) {
        displayMode = mode
    }

    /// Sessions grouped by state for the lane view, derived from the *filtered* tree
    /// (the shared filter narrows both modes). Within each lane: newest `stateChangedAt`
    /// first — consistent with the ⌘⇧U "latest waiting" semantics — with `nil` sorting
    /// last and ties keeping display order.
    public var stateLanes: SidebarStateLanes {
        var cards: [StateLaneCard] = []
        for repository in filteredRepositories {
            for worktree in repository.worktrees {
                for session in worktree.sessions {
                    cards.append(StateLaneCard(
                        id: session.id,
                        sessionName: session.session.displayName,
                        state: session.session.state,
                        repositoryName: repository.repository.name,
                        branch: worktree.worktree.branch,
                        stateChangedAt: session.session.stateChangedAt
                    ))
                }
            }
        }
        // `sorted(by:)` is documented as stable, so ties (and nil-vs-nil) keep display order.
        func laneSorted(_ lane: [StateLaneCard]) -> [StateLaneCard] {
            lane.sorted { ($0.stateChangedAt ?? .distantPast) > ($1.stateChangedAt ?? .distantPast) }
        }
        return SidebarStateLanes(
            waiting: laneSorted(cards.filter { $0.state == .waitingInput }),
            busy: laneSorted(cards.filter { $0.state == .busy }),
            idle: laneSorted(cards.filter { $0.state == .idle })
        )
    }

    /// Sessions across all repositories and worktrees, in display order.
    public var flattenedSessions: [SessionNode] {
        repositories.flatMap { $0.worktrees.flatMap(\.sessions) }
    }

    /// Worktrees across all repositories, in display order.
    public var flattenedWorktrees: [WorktreeNode] {
        repositories.flatMap(\.worktrees)
    }

    /// The currently selected worktree row. `nil` if `selectedWorktreePath` is not in the tree.
    public var selectedWorktree: WorktreeNode? {
        guard let selectedWorktreePath else { return nil }
        return flattenedWorktrees.first { $0.id == selectedWorktreePath }
    }

    /// Tally of busy/waitingInput/idle counts (across repositories).
    public var stateSummary: SessionStateSummary {
        Self.summarize(sessions: flattenedSessions.map(\.session))
    }

    /// The actual tallying logic is delegated to `SessionStateSummary.init(sessions:)`.
    public static func summarize(sessions: [AgentSession]) -> SessionStateSummary {
        SessionStateSummary(sessions: sessions)
    }

    /// Returns the most recent waiting-input session without changing selection.
    /// "Most recent" means the newest `AgentSession.stateChangedAt` (across repositories).
    /// Sessions without `stateChangedAt` are treated as the oldest. On a tie, the one later
    /// in display order wins.
    public func latestWaitingSession() -> SessionNode? {
        let waiting = flattenedSessions.enumerated().filter { $0.element.session.state == .waitingInput }
        return waiting.max(by: { lhs, rhs in
            let lhsTime = lhs.element.session.stateChangedAt ?? .distantPast
            let rhsTime = rhs.element.session.stateChangedAt ?? .distantPast
            if lhsTime != rhsTime { return lhsTime < rhsTime }
            return lhs.offset < rhs.offset
        })?.element
    }

    /// Select a worktree path. Pane-owned tab state is managed outside the sidebar.
    public mutating func selectWorktree(_ path: String?) {
        selectedWorktreePath = path
    }

    /// Select the next worktree in display order (across repositories, wrapping).
    /// If the current selection is not in the tree, selects the first worktree. Does
    /// nothing if there are no worktrees.
    public mutating func selectNextWorktree() {
        let flat = flattenedWorktrees
        guard !flat.isEmpty else { return }
        guard let currentPath = selectedWorktreePath, let index = flat.firstIndex(where: { $0.id == currentPath }) else {
            selectWorktree(flat.first?.id)
            return
        }
        selectWorktree(flat[(index + 1) % flat.count].id)
    }

    /// Select the previous worktree in display order (across repositories, wrapping).
    /// If the current selection is not in the tree, selects the last worktree. Does
    /// nothing if there are no worktrees.
    public mutating func selectPreviousWorktree() {
        let flat = flattenedWorktrees
        guard !flat.isEmpty else { return }
        guard let currentPath = selectedWorktreePath, let index = flat.firstIndex(where: { $0.id == currentPath }) else {
            selectWorktree(flat.last?.id)
            return
        }
        selectWorktree(flat[(index - 1 + flat.count) % flat.count].id)
    }
}
