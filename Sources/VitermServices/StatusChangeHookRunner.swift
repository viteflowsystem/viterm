import Foundation
import VitermCore

/// セッション状態変化時に実行する hook コマンドの設定。遷移(from→to)単位ではなく、
/// 到達した新状態単位で十分という要件のため `AgentSession.State` ごとに1つずつ持つ。
public struct StatusChangeHookConfig: Sendable, Equatable {
    public var onBusy: String?
    public var onWaitingInput: String?
    public var onIdle: String?

    public init(onBusy: String? = nil, onWaitingInput: String? = nil, onIdle: String? = nil) {
        self.onBusy = onBusy
        self.onWaitingInput = onWaitingInput
        self.onIdle = onIdle
    }

    func command(for state: AgentSession.State) -> String? {
        switch state {
        case .busy: return onBusy
        case .waitingInput: return onWaitingInput
        case .idle: return onIdle
        }
    }
}

/// セッション状態変化 hook の実行。新状態に対応するコマンドが設定されていれば
/// `VITERM_SESSION_NAME` / `VITERM_WORKTREE_PATH` / `VITERM_OLD_STATE` / `VITERM_NEW_STATE` を
/// 環境変数に載せて `/bin/sh -c` で非同期・非ブロッキング実行する。
public struct StatusChangeHookRunner: Sendable {
    public var config: StatusChangeHookConfig
    /// hook 実行本体。既定は `WorktreeProvisioner.defaultHookRunner` と同じプロセス起動実装を共有する。
    /// テストでは実プロセスを起動しない差し替えが可能。
    public var hookRunner: @Sendable (_ command: String, _ environment: [String: String]) async -> Void

    public init(
        config: StatusChangeHookConfig,
        hookRunner: @escaping @Sendable (String, [String: String]) async -> Void = WorktreeProvisioner.defaultHookRunner
    ) {
        self.config = config
        self.hookRunner = hookRunner
    }

    /// 状態変化を通知する。新状態に hook が設定されていなければ何もせず `nil` を返す。
    /// 呼び出し側(SessionManager 等)はこの Task を待つ必要はない(非ブロッキング)が、
    /// テストでは `await task?.value` で完了を待てる。
    @discardableResult
    public func notify(
        sessionName: String,
        worktreePath: String,
        oldState: AgentSession.State?,
        newState: AgentSession.State
    ) -> Task<Void, Never>? {
        guard let command = config.command(for: newState), !command.isEmpty else { return nil }

        let environment: [String: String] = [
            "VITERM_SESSION_NAME": sessionName,
            "VITERM_WORKTREE_PATH": worktreePath,
            "VITERM_OLD_STATE": oldState?.rawValue ?? "",
            "VITERM_NEW_STATE": newState.rawValue,
        ]

        let runHook = hookRunner
        return Task {
            await runHook(command, environment)
        }
    }

    /// 設定リロードごとに hook コマンド設定を最新化する(`StatusChangeNotifying.updateConfig`)。
    public mutating func updateConfig(_ config: StatusChangeHookConfig) {
        self.config = config
    }
}
