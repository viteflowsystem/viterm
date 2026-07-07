import Foundation

/// A running agent session; N of these hang off one worktree.
public struct AgentSession: Codable, Sendable, Hashable, Identifiable {
    /// Session state (the three ccmanager-style states).
    public enum State: String, Codable, Sendable {
        case busy
        case waitingInput
        case idle
    }

    public var id: UUID
    /// Reference to the associated `Worktree.id` (= the worktree's absolute path).
    public var worktreePath: String
    /// The `SessionPreset.name` used to launch it.
    public var presetName: String
    /// Display name in the sidebar and elsewhere (renamable).
    public var displayName: String
    public var state: State
    /// When `state` last changed. Used to order the ⌘⇧U jump (to the most recent
    /// waitingInput). `nil` if unknown (treated as the oldest).
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
