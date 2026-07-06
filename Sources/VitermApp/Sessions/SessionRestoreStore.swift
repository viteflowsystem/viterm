import Foundation
import VitermCore

/// セッション構成の永続化(再起動時の復元用)。
///
/// 保存するのは「どの worktree にどのプリセットのセッションが何本あったか」と選択中セッション。
/// PTY の中身(スクロールバック・実行中プロセス)は復元しない。
/// 保存先: ~/Library/Application Support/viterm/sessions.json
struct SessionRestoreStore {
    struct PersistedSession: Codable {
        var worktreePath: String
        var presetName: String
    }

    struct State: Codable {
        var sessions: [PersistedSession]
        /// 選択していたセッションの(復元順での)インデックス。
        var selectedIndex: Int?
        /// 選択していた worktree のパス。フェーズ2で追加。無い(旧フォーマットの)JSON は
        /// `nil` にデコードされ、`selectedIndex` 側から後方互換的に復元される。
        var selectedWorktreePath: String?
        /// worktree ごとの最終アクティブセッションを、`sessions` 配列上の(復元順での)
        /// インデックスとして記憶する(セッションIDは起動のたびに新規発行されるため)。
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
            // 永続化失敗は致命的ではないので無視(次回保存で上書きされる)。
        }
    }

    func load() -> State? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }
}
