import Foundation

/// State machine that layers idle debouncing and resize suppression on top of
/// `StateDetector`'s immediate signals to finalize an `AgentSession.State`
/// (busy/waitingInput/idle).
///
/// - idle is not finalized immediately: it is only confirmed once
///   `configuration.idleDebounce` (default 1.5s) has elapsed since busy/waitingInput
///   signals stopped.
/// - Right after a resize, screen-text re-evaluation is skipped for
///   `configuration.resizeSuppressionWindow` (default 250ms). This prevents
///   misdetection from post-resize redraws (the lesson from ccmanager Issue #73).
///
/// All timestamps are injected by the caller (`Date` is never fetched directly), so unit
/// tests can simulate arbitrary elapsed time.
public struct SessionStateMachine: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// Time from busy/waitingInput signals stopping until idle is finalized.
        public var idleDebounce: TimeInterval
        /// How long to suppress evaluation right after a resize.
        public var resizeSuppressionWindow: TimeInterval

        public init(idleDebounce: TimeInterval = 1.5, resizeSuppressionWindow: TimeInterval = 0.25) {
            self.idleDebounce = idleDebounce
            self.resizeSuppressionWindow = resizeSuppressionWindow
        }
    }

    public let detector: any StateDetector
    public var configuration: Configuration

    /// The last finalized state (busy/waitingInput, or debounce-confirmed idle).
    private var current: AgentSession.State
    /// When busy/waitingInput signals stopped (= became an idle candidate). nil if nothing has stopped yet.
    private var idleCandidateSince: Date?
    /// Evaluation is suppressed before this time (right after a resize).
    private var resizeSuppressedUntil: Date?

    public init(
        detector: any StateDetector,
        configuration: Configuration = .init(),
        initialState: AgentSession.State = .idle
    ) {
        self.detector = detector
        self.configuration = configuration
        self.current = initialState
        self.idleCandidateSince = nil
        self.resizeSuppressedUntil = nil
    }

    /// Call when output arrives from the PTY. `screenLines` is the full screen at that moment.
    public mutating func recordOutput(screenLines: [String], at now: Date) {
        if let suppressedUntil = resizeSuppressedUntil, now < suppressedUntil {
            return
        }
        switch detector.detect(screenLines: screenLines) {
        case .busy:
            current = .busy
            idleCandidateSince = nil
        case .waitingInput:
            current = .waitingInput
            idleCandidateSince = nil
        case .none:
            if current != .idle && idleCandidateSince == nil {
                idleCandidateSince = now
            }
        }
    }

    /// Call when the terminal is resized. For the next `resizeSuppressionWindow`,
    /// `recordOutput` evaluation is suppressed.
    public mutating func recordResize(at now: Date) {
        resizeSuppressedUntil = now.addingTimeInterval(configuration.resizeSuppressionWindow)
    }

    /// Return the state finalized as of `now`.
    public func currentState(at now: Date) -> AgentSession.State {
        if let suppressedUntil = resizeSuppressedUntil, now < suppressedUntil {
            // During suppression, the idle-debounce elapsed check is frozen too; return the last finalized state.
            return current
        }
        if let since = idleCandidateSince, now.timeIntervalSince(since) >= configuration.idleDebounce {
            return .idle
        }
        return current
    }
}
