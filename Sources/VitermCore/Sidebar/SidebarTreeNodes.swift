import Foundation

/// サイドバーのセッション行1つぶん。
public struct SessionNode: Sendable, Equatable, Identifiable {
    public var session: AgentSession
    /// ⌘1..9 に割り当てられた番号。サイドバー表示順の先頭9セッションのみ持つ(10番目以降は `nil`)。
    public var shortcutNumber: Int?

    public var id: UUID { session.id }
}

/// サイドバーの worktree 行1つぶん(配下のセッションを含む)。
public struct WorktreeNode: Sendable, Equatable, Identifiable {
    public var worktree: Worktree
    public var sessions: [SessionNode]

    public var id: String { worktree.id }

    /// 配下セッションの waitingInput 件数。worktree 行の waiting バッジ表示に使う。
    public var waitingSessionCount: Int {
        sessions.count { $0.session.state == .waitingInput }
    }

    /// 配下セッションの busy/waitingInput/idle 件数集計。
    public var stateSummary: SessionStateSummary {
        SessionStateSummary(sessions: sessions.map(\.session))
    }

    /// 配下セッションのうち最も優先度の高い状態(waitingInput > busy > idle)。
    /// worktree 行のロールアップドットの代表色決定に使う。セッションが1件も無ければ `nil`。
    public var dominantState: AgentSession.State? {
        if sessions.contains(where: { $0.session.state == .waitingInput }) { return .waitingInput }
        if sessions.contains(where: { $0.session.state == .busy }) { return .busy }
        return sessions.isEmpty ? nil : .idle
    }
}

/// サイドバーのリポジトリ行1つぶん(配下の worktree を含む)。
public struct RepositoryNode: Sendable, Equatable, Identifiable {
    public var repository: Repository
    public var worktrees: [WorktreeNode]

    public var id: String { repository.id }

    /// 配下(全 worktree 横断)の waitingInput セッション数。
    /// リポジトリ折りたたみ時のバッジ表示に使う。
    public var waitingSessionCount: Int {
        worktrees.reduce(0) { count, worktree in
            count + worktree.sessions.count { $0.session.state == .waitingInput }
        }
    }
}

/// busy / waitingInput / idle の件数集計(ステータスバー表示用)。
public struct SessionStateSummary: Sendable, Equatable {
    public var busy: Int
    public var waitingInput: Int
    public var idle: Int

    public init(busy: Int = 0, waitingInput: Int = 0, idle: Int = 0) {
        self.busy = busy
        self.waitingInput = waitingInput
        self.idle = idle
    }

    /// セッション配列から busy/waitingInput/idle の件数を集計する。
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
