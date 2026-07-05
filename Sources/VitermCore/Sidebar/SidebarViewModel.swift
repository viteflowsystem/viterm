import Foundation

/// サイドバー(リポジトリ → worktree → セッションの3階層ツリー)の UI 非依存な状態。
///
/// `Repository` / `Worktree` / `AgentSession` のフラットな配列から木構造を組み立て、
/// ⌘1..9 のショートカット番号割当、リポジトリ折りたたみ時の waiting バッジ集約、
/// 状態集計(busy/waiting/idle)、選択セッションの管理(次/前移動・⌘⇧U ジャンプ)を提供する。
///
/// 純粋な値型であり、内部で監視や差分更新は行わない。呼び出し側は元データが変わるたびに
/// `init` を呼び直して(直前の `selectedSessionID` を引き継いで)再構築する想定。
public struct SidebarViewModel: Sendable, Equatable {
    public private(set) var repositories: [RepositoryNode]
    public private(set) var selectedSessionID: AgentSession.ID?

    /// - Parameters:
    ///   - repositories: サイドバーに表示するリポジトリ。この配列の順序がそのまま表示順になる。
    ///   - worktrees: 全リポジトリ分の worktree。`repositoryPath` で対応するリポジトリに紐付けられる。
    ///     どのリポジトリにも一致しない worktree はツリーに現れない。
    ///   - sessions: 全 worktree 分のセッション。`worktreePath` で対応する worktree に紐付けられる。
    ///     どの worktree にも一致しないセッションはツリーに現れない。
    ///   - selectedSessionID: 初期選択セッション。ツリーに存在しない ID を渡しても構わない
    ///     (`selectedSession` は `nil` を返す)。
    public init(
        repositories: [Repository],
        worktrees: [Worktree],
        sessions: [AgentSession],
        branchesByRepository: [String: [String]] = [:],
        selectedSessionID: AgentSession.ID? = nil
    ) {
        self.repositories = Self.buildTree(
            repositories: repositories,
            worktrees: worktrees,
            sessions: sessions,
            branchesByRepository: branchesByRepository
        )
        self.selectedSessionID = selectedSessionID
    }

    private static func buildTree(
        repositories: [Repository],
        worktrees: [Worktree],
        sessions: [AgentSession],
        branchesByRepository: [String: [String]]
    ) -> [RepositoryNode] {
        // `Dictionary(grouping:by:)` は元の配列の相対順序を保ったままグルーピングするため、
        // 呼び出し側が渡した並び順(= サイドバー表示順)がそのままツリーに反映される。
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
            // worktree に既にチェックアウトされているブランチは「branches」グループから除く。
            let checkedOut = Set(childWorktrees.map(\.worktree.branch))
            let available = (branchesByRepository[repository.path] ?? []).filter { !checkedOut.contains($0) }
            return RepositoryNode(
                repository: repository,
                worktrees: childWorktrees,
                availableBranches: available
            )
        }
    }

    /// 全リポジトリ・全 worktree を横断した、表示順でのセッション一覧。
    public var flattenedSessions: [SessionNode] {
        repositories.flatMap { $0.worktrees.flatMap(\.sessions) }
    }

    /// 現在選択中のセッション行。`selectedSessionID` がツリーに存在しなければ `nil`。
    public var selectedSession: SessionNode? {
        guard let selectedSessionID else { return nil }
        return flattenedSessions.first { $0.id == selectedSessionID }
    }

    /// busy/waitingInput/idle の件数集計(リポジトリ横断)。
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

    // MARK: - 選択管理

    /// セッションを直接選択する。`nil` を渡すと選択解除。
    public mutating func select(sessionID: AgentSession.ID?) {
        selectedSessionID = sessionID
    }

    /// 表示順で次のセッションを選択する(末尾からは先頭へ循環)。
    /// 現在の選択がツリーに無い場合は先頭のセッションを選ぶ。セッションが1件も無ければ何もしない。
    public mutating func selectNext() {
        let flat = flattenedSessions
        guard !flat.isEmpty else { return }
        guard let currentID = selectedSessionID, let index = flat.firstIndex(where: { $0.id == currentID }) else {
            selectedSessionID = flat.first?.id
            return
        }
        selectedSessionID = flat[(index + 1) % flat.count].id
    }

    /// 表示順で前のセッションを選択する(先頭からは末尾へ循環)。
    public mutating func selectPrevious() {
        let flat = flattenedSessions
        guard !flat.isEmpty else { return }
        guard let currentID = selectedSessionID, let index = flat.firstIndex(where: { $0.id == currentID }) else {
            selectedSessionID = flat.last?.id
            return
        }
        selectedSessionID = flat[(index - 1 + flat.count) % flat.count].id
    }

    /// ⌘1..9 に対応するセッションを選択する。該当が無ければ何もせず `false` を返す。
    @discardableResult
    public mutating func selectShortcut(_ number: Int) -> Bool {
        guard let node = flattenedSessions.first(where: { $0.shortcutNumber == number }) else {
            return false
        }
        selectedSessionID = node.id
        return true
    }

    /// ⌘⇧U 相当: 最新の waitingInput セッションへジャンプする。
    /// 「最新」は `AgentSession.stateChangedAt` が最も新しいもの(リポジトリ横断)。
    /// `stateChangedAt` が無いセッションは最も古いものとして扱う。同時刻の場合は表示順で後ろのものを優先する。
    /// waitingInput のセッションが無ければ何もせず `false` を返す。
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
