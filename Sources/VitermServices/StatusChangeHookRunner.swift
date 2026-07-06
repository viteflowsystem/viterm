import Foundation
import VitermCore

/// Configuration of the hook commands run on session state changes. Per the requirements,
/// keying by the new state reached (rather than by transition from→to) is sufficient, so
/// there is one command per `AgentSession.State`.
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

/// Executes session state-change hooks. If a command is configured for the new state,
/// runs it via `/bin/sh -c` asynchronously and non-blocking, with
/// `VITERM_SESSION_NAME` / `VITERM_WORKTREE_PATH` / `VITERM_OLD_STATE` / `VITERM_NEW_STATE`
/// set as environment variables.
public struct StatusChangeHookRunner: Sendable {
    public var config: StatusChangeHookConfig
    /// The actual hook executor. By default it shares the same process-launching implementation
    /// as `WorktreeProvisioner.defaultHookRunner`. Tests can swap this out to avoid launching a real process.
    public var hookRunner: @Sendable (_ command: String, _ environment: [String: String]) async -> Void

    public init(
        config: StatusChangeHookConfig,
        hookRunner: @escaping @Sendable (String, [String: String]) async -> Void = WorktreeProvisioner.defaultHookRunner
    ) {
        self.config = config
        self.hookRunner = hookRunner
    }

    /// Notifies of a state change. If no hook is configured for the new state, does nothing and returns `nil`.
    /// Callers (SessionManager, etc.) do not need to await this Task (non-blocking), but tests
    /// can wait for completion via `await task?.value`.
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

    /// Refreshes the hook command config on every config reload (`StatusChangeNotifying.updateConfig`).
    public mutating func updateConfig(_ config: StatusChangeHookConfig) {
        self.config = config
    }
}
