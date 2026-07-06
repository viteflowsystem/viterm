import Foundation

/// サイドバー(リポジトリ → worktree → セッションの3階層ツリー)の UI 非依存な状態。
///
/// `Repository` / `Worktree` / `AgentSession` のフラットな配列から木構造を組み立て、
/// リポジトリ折りたたみ時の waiting バッジ集約、状態集計(busy/waiting/idle)、
/// 選択セッションの管理(次/前移動・⌘⇧U ジャンプ)を提供する。⌘1..9 のショートカット番号は
/// タブ局所(`TabBarViewModel`)の役割のため、ここでは割り当てない。
///
/// 選択の主語は worktree(`selectedWorktreePath`)。worktree を離れて戻ったときに同じタブへ
/// 復帰できるよう、worktree ごとの最終アクティブセッションを `activeSessionByWorktree` に記憶する。
/// `selectedSessionID` はその worktree 内で実際にアクティブなセッションを指す(後方互換のため
/// 引き続き第一級の値として保持・公開する)。
///
/// 純粋な値型であり、内部で監視や差分更新は行わない。呼び出し側は元データが変わるたびに
/// `init` を呼び直して(直前の `selectedSessionID` / `selectedWorktreePath` /
/// `activeSessionByWorktree` を引き継いで)再構築する想定。
public struct SidebarViewModel: Sendable, Equatable {
    public private(set) var repositories: [RepositoryNode]
    public private(set) var selectedSessionID: AgentSession.ID?
    public private(set) var selectedWorktreePath: String?
    /// worktree ごとの最終アクティブセッション。worktree を離れて戻ったとき同じタブに復帰するための記憶。
    public private(set) var activeSessionByWorktree: [String: AgentSession.ID]

    /// - Parameters:
    ///   - repositories: サイドバーに表示するリポジトリ。この配列の順序がそのまま表示順になる。
    ///   - worktrees: 全リポジトリ分の worktree。`repositoryPath` で対応するリポジトリに紐付けられる。
    ///     どのリポジトリにも一致しない worktree はツリーに現れない。
    ///   - sessions: 全 worktree 分のセッション。`worktreePath` で対応する worktree に紐付けられる。
    ///     どの worktree にも一致しないセッションはツリーに現れない。
    ///   - selectedSessionID: 初期選択セッション。ツリーに存在しない ID を渡しても構わない
    ///     (`selectedSession` は `nil` を返す)。
    ///   - selectedWorktreePath: 初期選択 worktree。ツリーに存在しないパスを渡しても構わない
    ///     (`selectedWorktree` は `nil` を返す)。
    ///   - activeSessionByWorktree: 再構築前の worktree ごとの最終アクティブセッション記憶。
    public init(
        repositories: [Repository],
        worktrees: [Worktree],
        sessions: [AgentSession],
        selectedSessionID: AgentSession.ID? = nil,
        selectedWorktreePath: String? = nil,
        activeSessionByWorktree: [String: AgentSession.ID] = [:]
    ) {
        self.repositories = Self.buildTree(repositories: repositories, worktrees: worktrees, sessions: sessions)
        self.selectedSessionID = selectedSessionID
        self.selectedWorktreePath = selectedWorktreePath
        self.activeSessionByWorktree = activeSessionByWorktree
    }

    private static func buildTree(
        repositories: [Repository],
        worktrees: [Worktree],
        sessions: [AgentSession]
    ) -> [RepositoryNode] {
        // `Dictionary(grouping:by:)` は元の配列の相対順序を保ったままグルーピングするため、
        // 呼び出し側が渡した並び順(= サイドバー表示順)がそのままツリーに反映される。
        let worktreesByRepository = Dictionary(grouping: worktrees, by: \.repositoryPath)
        let sessionsByWorktree = Dictionary(grouping: sessions, by: \.worktreePath)

        return repositories.map { repository in
            let childWorktrees = (worktreesByRepository[repository.path] ?? []).map { worktree -> WorktreeNode in
                // サイドバーにセッション行は無く ⌘1..9 はタブ局所(TabBarViewModel)の役割なので、
                // ここでは番号を振らない。
                let childSessions = (sessionsByWorktree[worktree.path] ?? []).map { session in
                    SessionNode(session: session, shortcutNumber: nil)
                }
                return WorktreeNode(worktree: worktree, sessions: childSessions)
            }
            return RepositoryNode(repository: repository, worktrees: childWorktrees)
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

    /// 全リポジトリを横断した、表示順での worktree 一覧。
    public var flattenedWorktrees: [WorktreeNode] {
        repositories.flatMap(\.worktrees)
    }

    /// 現在選択中の worktree 行。`selectedWorktreePath` がツリーに存在しなければ `nil`。
    public var selectedWorktree: WorktreeNode? {
        guard let selectedWorktreePath else { return nil }
        return flattenedWorktrees.first { $0.id == selectedWorktreePath }
    }

    /// busy/waitingInput/idle の件数集計(リポジトリ横断)。
    public var stateSummary: SessionStateSummary {
        Self.summarize(sessions: flattenedSessions.map(\.session))
    }

    /// 集計ロジックの本体は `SessionStateSummary.init(sessions:)` に委譲する。
    public static func summarize(sessions: [AgentSession]) -> SessionStateSummary {
        SessionStateSummary(sessions: sessions)
    }

    // MARK: - 選択管理

    /// セッションを直接選択する。`nil` を渡すと選択解除。
    ///
    /// セッションがツリーに存在すれば、その worktree を `selectedWorktreePath` としても記憶し、
    /// `activeSessionByWorktree` にも反映する(worktree を切り替えて戻ったときの復帰用)。
    public mutating func select(sessionID: AgentSession.ID?) {
        selectedSessionID = sessionID
        guard let sessionID, let node = flattenedSessions.first(where: { $0.id == sessionID }) else {
            return
        }
        selectedWorktreePath = node.session.worktreePath
        activeSessionByWorktree[node.session.worktreePath] = sessionID
    }

    /// 表示順で次のセッションを選択する(末尾からは先頭へ循環)。
    /// 現在の選択がツリーに無い場合は先頭のセッションを選ぶ。セッションが1件も無ければ何もしない。
    public mutating func selectNext() {
        let flat = flattenedSessions
        guard !flat.isEmpty else { return }
        guard let currentID = selectedSessionID, let index = flat.firstIndex(where: { $0.id == currentID }) else {
            select(sessionID: flat.first?.id)
            return
        }
        select(sessionID: flat[(index + 1) % flat.count].id)
    }

    /// 表示順で前のセッションを選択する(先頭からは末尾へ循環)。
    public mutating func selectPrevious() {
        let flat = flattenedSessions
        guard !flat.isEmpty else { return }
        guard let currentID = selectedSessionID, let index = flat.firstIndex(where: { $0.id == currentID }) else {
            select(sessionID: flat.last?.id)
            return
        }
        select(sessionID: flat[(index - 1 + flat.count) % flat.count].id)
    }

    /// ⌘⇧U 相当: 最新の waitingInput セッションへジャンプする。
    /// 「最新」は `AgentSession.stateChangedAt` が最も新しいもの(リポジトリ横断)。
    /// `stateChangedAt` が無いセッションは最も古いものとして扱う。同時刻の場合は表示順で後ろのものを優先する。
    /// 該当セッションの worktree も `selectedWorktreePath` として選択される(worktree 選択と
    /// セッション選択の両方が連動して切り替わる)。waitingInput のセッションが無ければ何もせず
    /// `false` を返す。
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
        select(sessionID: latest.element.id)
        return true
    }

    /// worktree を選択する(選択の主語の切り替え)。
    ///
    /// 対象 worktree について `activeSessionByWorktree` に記憶があればそのセッションを復元し、
    /// 無ければ先頭セッションを選ぶ(セッションが1件も無い worktree、または存在しない worktree
    /// パスを渡した場合はセッション選択を解除する)。`nil` を渡すと worktree・セッションの選択を
    /// 両方解除する。
    public mutating func selectWorktree(_ path: String?) {
        selectedWorktreePath = path
        guard let path, let node = flattenedWorktrees.first(where: { $0.id == path }) else {
            selectedSessionID = nil
            return
        }
        if let remembered = activeSessionByWorktree[path], node.sessions.contains(where: { $0.id == remembered }) {
            selectedSessionID = remembered
        } else {
            selectedSessionID = node.sessions.first?.id
            if let selectedSessionID {
                activeSessionByWorktree[path] = selectedSessionID
            }
        }
    }

    /// 表示順で次の worktree を選択する(リポジトリ横断・循環)。
    /// 現在の選択がツリーに無い場合は先頭の worktree を選ぶ。worktree が1件も無ければ何もしない。
    public mutating func selectNextWorktree() {
        let flat = flattenedWorktrees
        guard !flat.isEmpty else { return }
        guard let currentPath = selectedWorktreePath, let index = flat.firstIndex(where: { $0.id == currentPath }) else {
            selectWorktree(flat.first?.id)
            return
        }
        selectWorktree(flat[(index + 1) % flat.count].id)
    }

    /// 表示順で前の worktree を選択する(リポジトリ横断・循環)。
    /// 現在の選択がツリーに無い場合は末尾の worktree を選ぶ。worktree が1件も無ければ何もしない。
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
