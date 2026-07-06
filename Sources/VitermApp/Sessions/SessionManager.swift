import AppKit
import GhosttyKit
import VitermCore
import VitermServices

/// Manages the actual 1 worktree : N sessions relationship (T6).
///
/// Session = libghostty surface (GhosttySurfaceView) + metadata (AgentSession).
/// By keeping the surface views retained here, hidden sessions also stay alive in the
/// background and their scrollback is preserved.
@MainActor
final class SessionManager {
    /// Current config used for preset resolution. Updated after AppModel's refresh.
    var presets: [SessionPreset] = []
    /// worktree path → branch name. Used to resolve the default session name ("{branch} #n").
    /// Updated after AppModel's refresh (falls back to the last path component if unregistered).
    var worktreeBranches: [String: String] = [:]

    private var surfaces: [UUID: GhosttySurfaceView] = [:]
    /// Per-worktree sequence number (the 2 in "feat-x #2"). Numbers are not reused after a session ends.
    private var counters: [String: Int] = [:]

    func surface(for sessionID: UUID) -> GhosttySurfaceView? {
        surfaces[sessionID]
    }

    /// Reverse-look up the session ID from a surface view (for pane focus synchronization).
    func sessionID(for view: NSView) -> UUID? {
        surfaces.first { $0.value === view }?.key
    }

    func terminate(sessionID: UUID) {
        // Releasing the view triggers deinit → ghostty_surface_free, which also terminates the child process.
        surfaces[sessionID]?.removeFromSuperview()
        surfaces[sessionID] = nil
    }

    private func makeSession(worktreePath: String, presetName: String) -> AgentSession {
        let preset = presets.first { $0.name == presetName }
            ?? SessionPreset(name: presetName, command: presetName)

        var arguments = preset.arguments
        // To keep Claude Code's Agent Teams feature from conflicting with surface management,
        // automatically add --teammate-mode in-process for claude (same as ccmanager).
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
        // Reattaching surfaces is the responsibility of TerminalHostView (UI side). Do nothing here.
    }
}
