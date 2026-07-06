import Foundation

/// A running agent session; N of these hang off one worktree.
public struct AgentSession: Codable, Sendable, Hashable, Identifiable {
    /// Session state (the ccmanager-style three states).
    public enum State: String, Codable, Sendable {
        case busy
        case waitingInput
        case idle
    }

    public var id: UUID
    /// Reference to the associated `Worktree.id` (= absolute path of the worktree).
    public var worktreePath: String
    /// The `SessionPreset.name` used to launch this session.
    public var presetName: String
    /// Display name in the sidebar etc. (renamable).
    public var displayName: String
    public var state: State
    /// The time `state` last changed. Used for the ordering decision of
    /// ⌘⇧U (jump to the most recent waitingInput).
    /// `nil` when unknown (treated as the oldest).
    public var stateChangedAt: Date?

    public init(
        id: UUID = UUID(),
        worktreePath: String,
        presetName: String,
        displayName: String,
        state: State = .idle,
        stateChangedAt: Date? = nil
    ) {
        self.id = id
        self.worktreePath = worktreePath
        self.presetName = presetName
        self.displayName = displayName
        self.state = state
        self.stateChangedAt = stateChangedAt
    }
}
