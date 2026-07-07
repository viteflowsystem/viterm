import AppKit
import GhosttyKit
import VitermCore
import VitermServices

/// Management of the actual 1 worktree : N sessions (T6).
///
/// Session = a libghostty surface (GhosttySurfaceView) + metadata (AgentSession).
/// By retaining the surface views here, hidden sessions stay alive in the background and
/// keep their scrollback.
@MainActor
final class SessionManager {
    /// Current config used for preset resolution. Updated after AppModel's refresh.
    var presets: [SessionPreset] = []
    /// worktree path → branch name. Used to resolve the default session name
    /// ("{branch} #n"). Updated after AppModel's refresh (falls back to the path's last
    /// component when unregistered).
    var worktreeBranches: [String: String] = [:]

    private var surfaces: [UUID: GhosttySurfaceView] = [:]
    /// Per-worktree sequence number (the 2 in "feat-x #2"). Numbers are not reused after a session ends.
    private var counters: [String: Int] = [:]

    func surface(for sessionID: UUID) -> GhosttySurfaceView? {
        surfaces[sessionID]
    }

    /// Reverse-look up the session ID from a surface view (for pane focus sync).
    func sessionID(for view: NSView) -> UUID? {
        surfaces.first { $0.value === view }?.key
    }

    func terminate(sessionID: UUID) {
        // Releasing the view runs deinit → ghostty_surface_free, which also terminates the child process.
        surfaces[sessionID]?.removeFromSuperview()
        surfaces[sessionID] = nil
    }

    private func makeSession(worktreePath: String, presetName: String) -> AgentSession {
        let preset = presets.first { $0.name == presetName }
            ?? SessionPreset(name: presetName, command: presetName)

        var arguments = preset.arguments
        // So Claude Code's Agent Teams feature doesn't clash with surface management,
        // claude automatically gets --teammate-mode in-process (same as ccmanager).
        if preset.command == "claude", !arguments.contains("--teammate-mode") {
            arguments += ["--teammate-mode", "in-process"]
        }
        let commandLine = ([preset.command] + arguments).joined(separator: " ")

        let number = (counters[worktreePath] ?? 0) + 1
        counters[worktreePath] = number

        // The default name is branch-based ("feat-x #2"). Branch names normalize `/` to `-` to stay short.
        let branch = (worktreeBranches[worktreePath]
            ?? URL(fileURLWithPath: worktreePath).lastPathComponent)
            .replacingOccurrences(of: "/", with: "-")
        let session = AgentSession(
            worktreePath: worktreePath,
            presetName: preset.name,
            displayName: "\(branch) #\(number)",
            state: .idle,
            stateChangedAt: Date()
        )
        let view = GhosttySurfaceView(command: commandLine, workingDirectory: worktreePath)
        surfaces[session.id] = view
        return session
    }
}

extension SessionManager: SessionLaunching {
    nonisolated func startSession(worktreePath: String, presetName: String) async throws -> AgentSession {
        await MainActor.run {
            self.makeSession(worktreePath: worktreePath, presetName: presetName)
        }
    }

    nonisolated func switchToWorktree(_ worktreePath: String) async {
        // Swapping surfaces is TerminalHostView's (the UI's) responsibility. Nothing to do here.
    }
}
