import AppKit
import GhosttyKit
import VitermCore
import VitermServices

/// 1 worktree : N セッションの実体管理(T6)。
///
/// セッション = libghostty サーフェス(GhosttySurfaceView)+ メタデータ(AgentSession)。
/// サーフェスビューをここで retain し続けることで、非表示のセッションも
/// バックグラウンドで生存し、スクロールバックも保持される。
@MainActor
final class SessionManager {
    /// プリセット解決に使う現在の設定。AppModel の refresh 後に更新される。
    var presets: [SessionPreset] = []
    /// worktree パス → ブランチ名。既定セッション名("{branch} #n")の解決に使う。
    /// AppModel の refresh 後に更新される(未登録時はパス末尾で代用)。
    var worktreeBranches: [String: String] = [:]

    private var surfaces: [UUID: GhosttySurfaceView] = [:]
    /// worktree ごとの連番("feat-x #2" の 2)。セッション終了後も番号は再利用しない。
    private var counters: [String: Int] = [:]

    func surface(for sessionID: UUID) -> GhosttySurfaceView? {
        surfaces[sessionID]
    }

    /// サーフェスビューからセッション ID を逆引きする(ペインのフォーカス同期用)。
    func sessionID(for view: NSView) -> UUID? {
        surfaces.first { $0.value === view }?.key
    }

    func terminate(sessionID: UUID) {
        // ビューの解放で deinit → ghostty_surface_free が走り、子プロセスも終了する。
        surfaces[sessionID]?.removeFromSuperview()
        surfaces[sessionID] = nil
    }

    private func makeSession(worktreePath: String, presetName: String) -> AgentSession {
        let preset = presets.first { $0.name == presetName }
            ?? SessionPreset(name: presetName, command: presetName)

        var arguments = preset.arguments
        // Claude Code の Agent Teams 機能とサーフェス管理が衝突しないよう、
        // claude には --teammate-mode in-process を自動付与する(ccmanager と同じ)。
        if preset.command == "claude", !arguments.contains("--teammate-mode") {
            arguments += ["--teammate-mode", "in-process"]
        }
        let commandLine = ([preset.command] + arguments).joined(separator: " ")

        let number = (counters[worktreePath] ?? 0) + 1
        counters[worktreePath] = number

        // 既定名はブランチ名ベース("feat-x #2")。ブランチ名は `/` を `-` に正規化して短く保つ。
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
        // サーフェスの付け替えは TerminalHostView(UI 側)の責務。ここでは何もしない。
    }
}
