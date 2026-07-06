import Foundation

/// 選択中 worktree のタブバー(= 配下セッションの並び)を表す UI 非依存な状態。
///
/// タブ = セッション 1:1。`SidebarViewModel` が worktree 横断の選択を扱うのに対し、
/// `TabBarViewModel` は単一 worktree 内のタブ局所な ⌘1..9 採番・アクティブタブの選択/循環を担う。
///
/// 純粋な値型であり、内部で監視や差分更新は行わない。呼び出し側は worktree の切り替えや
/// セッション構成の変化のたびに `init` を呼び直して(直前の `activeTabID` を引き継いで)
/// 再構築する想定。
public struct TabBarViewModel: Sendable, Equatable {
    public private(set) var tabs: [SessionNode]
    public private(set) var activeTabID: AgentSession.ID?

    /// - Parameters:
    ///   - sessions: 選択中 worktree に属するセッション。この配列の順序がそのままタブの並び順になる。
    ///   - activeTabID: 初期のアクティブタブ。`sessions` に存在しない ID を渡しても構わない
    ///     (`activeTab` は `nil` を返す)。
    public init(sessions: [AgentSession], activeTabID: AgentSession.ID? = nil) {
        self.tabs = Self.assignShortcuts(sessions: sessions)
        self.activeTabID = activeTabID
    }

    private static func assignShortcuts(sessions: [AgentSession]) -> [SessionNode] {
        sessions.enumerated().map { index, session in
            SessionNode(session: session, shortcutNumber: index < 9 ? index + 1 : nil)
        }
    }

    /// 現在アクティブなタブ。`activeTabID` がタブ列に存在しなければ `nil`。
    public var activeTab: SessionNode? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    // MARK: - 選択管理

    /// タブを直接選択する。`nil` を渡すと選択解除。
    public mutating func selectTab(_ id: AgentSession.ID?) {
        activeTabID = id
    }

    /// ⌘1..9 に対応するタブ(worktree 内 index+1)を選択する。該当が無ければ何もせず `false` を返す。
    @discardableResult
    public mutating func selectShortcut(_ number: Int) -> Bool {
        guard let tab = tabs.first(where: { $0.shortcutNumber == number }) else {
            return false
        }
        activeTabID = tab.id
        return true
    }

    /// 次のタブを選択する(末尾からは先頭へ循環)。
    /// 現在の選択がタブ列に無い場合は先頭のタブを選ぶ。タブが1件も無ければ何もしない。
    public mutating func selectNext() {
        guard !tabs.isEmpty else { return }
        guard let currentID = activeTabID, let index = tabs.firstIndex(where: { $0.id == currentID }) else {
            activeTabID = tabs.first?.id
            return
        }
        activeTabID = tabs[(index + 1) % tabs.count].id
    }

    /// 前のタブを選択する(先頭からは末尾へ循環)。
    /// 現在の選択がタブ列に無い場合は末尾のタブを選ぶ。タブが1件も無ければ何もしない。
    public mutating func selectPrevious() {
        guard !tabs.isEmpty else { return }
        guard let currentID = activeTabID, let index = tabs.firstIndex(where: { $0.id == currentID }) else {
            activeTabID = tabs.last?.id
            return
        }
        activeTabID = tabs[(index - 1 + tabs.count) % tabs.count].id
    }
}
