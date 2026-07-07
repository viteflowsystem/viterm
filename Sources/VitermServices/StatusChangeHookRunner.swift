import Foundation
import VitermCore

/// Config for hook commands run on session state changes. The requirement is satisfied by
/// keying on the new state reached — not on the (from→to) transition — so there is one
/// command per `AgentSession.State`.
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

/// Runs session-state-change hooks. If a command is configured for the new state, it is
/// executed asynchronously and non-blockingly via `/bin/sh -c` with
/// `VITERM_SESSION_NAME` / `VITERM_WORKTREE_PATH` / `VITERM_OLD_STATE` / `VITERM_NEW_STATE`
/// set as environment variables.
public struct StatusChangeHookRunner: Sendable {
    public var config: StatusChangeHookConfig
    /// The actual hook runner. By default shares the same process-launch implementation as
    /// `WorktreeProvisioner.defaultHookRunner`. Tests can swap in one that launches no real process.
    public var hookRunner: @Sendable (_ command: String, _ environment: [String: String]) async -> Void

    public init(
        config: StatusChangeHookConfig,
        hookRunner: @escaping @Sendable (String, [String: String]) async -> Void = WorktreeProvisioner.defaultHookRunner
    ) {
        self.config = config
        self.hookRunner = hookRunner
    }

    /// Notify a state change. If no hook is configured for the new state, does nothing and
    /// returns `nil`. Callers (SessionManager, etc.) don't need to await this Task
    /// (non-blocking), but tests can wait for completion via `await task?.value`.
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

    /// Refresh the hook command config on every config reload (`StatusChangeNotifying.updateConfig`).
    public mutating func updateConfig(_ config: StatusChangeHookConfig) {
        self.config = config
    }
}
