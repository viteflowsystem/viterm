import Foundation
import VitermCore

/// Persistence of the session layout (for restoring across relaunches).
///
/// What is saved: "how many sessions of which preset existed in which worktree" and the
/// selected session. PTY contents (scrollback, running processes) are not restored.
/// Location: ~/Library/Application Support/viterm/sessions.json
struct SessionRestoreStore {
    struct PersistedSession: Codable {
        var worktreePath: String
        var presetName: String
    }

    struct State: Codable {
        var sessions: [PersistedSession]
        /// Index (in restore order) of the session that was selected.
        var selectedIndex: Int?
        /// Path of the worktree that was selected. Added in phase 2. JSON without it (the
        /// old format) decodes to `nil` and is restored backward-compatibly from `selectedIndex`.
        var selectedWorktreePath: String?
        /// Remembers each worktree's last active session as an index (in restore order)
        /// into the `sessions` array (session IDs are freshly issued on every launch).
        var activeSessionIndexByWorktree: [String: Int]?
    }

    var fileURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("viterm/sessions.json")

    func save(
        sessions: [AgentSession],
        selectedSessionID: AgentSession.ID?,
        selectedWorktreePath: String?,
        activeSessionByWorktree: [String: AgentSession.ID]
    ) {
        let state = State(
            sessions: sessions.map {
                PersistedSession(worktreePath: $0.worktreePath, presetName: $0.presetName)
            },
            selectedIndex: sessions.firstIndex { $0.id == selectedSessionID },
            selectedWorktreePath: selectedWorktreePath,
            activeSessionIndexByWorktree: activeSessionByWorktree.compactMapValues { sessionID in
                sessions.firstIndex { $0.id == sessionID }
            }
        )
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Persistence failure isn't fatal, so ignore it (overwritten by the next save).
        }
    }

    func load() -> State? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }
}
