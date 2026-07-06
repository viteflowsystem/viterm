import Foundation
import VitermCore

/// Persistence of the session configuration (for restore on relaunch).
///
/// What is saved: which worktree had how many sessions of which preset, plus the selected
/// session. PTY contents (scrollback, running processes) are not restored.
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
    }

    var fileURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("viterm/sessions.json")

    func save(sessions: [AgentSession], selectedSessionID: AgentSession.ID?) {
        let state = State(
            sessions: sessions.map {
                PersistedSession(worktreePath: $0.worktreePath, presetName: $0.presetName)
            },
            selectedIndex: sessions.firstIndex { $0.id == selectedSessionID }
        )
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Persistence failure is not fatal, so ignore it (overwritten by the next save).
        }
    }

    func load() -> State? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }
}
