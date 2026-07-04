import Foundation

/// 1 worktree に N 個ぶら下がる、実行中のエージェントセッション。
public struct AgentSession: Codable, Sendable, Hashable, Identifiable {
    /// セッション状態(ccmanager 方式の3状態)。
    public enum State: String, Codable, Sendable {
        case busy
        case waitingInput
        case idle
    }

    public var id: UUID
    /// 紐付く `Worktree.id`(= worktree の絶対パス)への参照。
    public var worktreePath: String
    /// 起動に使った `SessionPreset.name`。
    public var presetName: String
    /// サイドバー等での表示名(リネーム可能)。
    public var displayName: String
    public var state: State

    public init(
        id: UUID = UUID(),
        worktreePath: String,
        presetName: String,
        displayName: String,
        state: State = .idle
    ) {
        self.id = id
        self.worktreePath = worktreePath
        self.presetName = presetName
        self.displayName = displayName
        self.state = state
    }
}
