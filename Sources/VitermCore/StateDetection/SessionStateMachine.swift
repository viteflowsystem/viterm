import Foundation

/// State machine that layers idle debouncing and resize suppression on top of
/// `StateDetector`'s instantaneous signals to settle on an
/// `AgentSession.State` (busy/waitingInput/idle).
///
/// - idle is not settled immediately: idle only becomes final once
///   `configuration.idleDebounce` (default 1.5s) has elapsed after busy/waitingInput
///   signals stopped.
/// - Right after a resize, screen-text re-evaluation is skipped for
///   `configuration.resizeSuppressionWindow` (default 250ms). This prevents
///   false detections caused by the redraw immediately after a resize
///   (lesson from ccmanager Issue #73).
///
/// All timestamps are injected by the caller (no direct `Date` acquisition),
/// so unit tests can simulate arbitrary elapsed times.
public struct SessionStateMachine: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// Time after busy/waitingInput signals stop before idle is settled.
        public var idleDebounce: TimeInterval
        /// Time to suppress detection right after a resize.
        public var resizeSuppressionWindow: TimeInterval

        public init(idleDebounce: TimeInterval = 1.5, resizeSuppressionWindow: TimeInterval = 0.25) {
            self.idleDebounce = idleDebounce
            self.resizeSuppressionWindow = resizeSuppressionWindow
        }
    }

    public let detector: any StateDetector
    public var configuration: Configuration

    /// The last settled state (busy/waitingInput, or idle after debounce completion).
    private var current: AgentSession.State
    /// The time at which busy/waitingInput signals stopped (= became an idle candidate). nil if nothing has stopped yet.
    private var idleCandidateSince: Date?
    /// Detection is suppressed before this time (right after a resize).
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

    /// Call when output is received from the PTY. `screenLines` is the whole screen at that moment.
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

    /// Call when the terminal is resized. `recordOutput` evaluation is suppressed
    /// for the following `resizeSuppressionWindow`.
    public mutating func recordResize(at now: Date) {
        resizeSuppressedUntil = now.addingTimeInterval(configuration.resizeSuppressionWindow)
    }

    /// Returns the state settled as of `now`.
    public func currentState(at now: Date) -> AgentSession.State {
        if let suppressedUntil = resizeSuppressedUntil, now < suppressedUntil {
            // During the suppression window, the idle-debounce elapsed check is also frozen,
            // and the last settled state is returned.
            return current
        }
        if let since = idleCandidateSince, now.timeIntervalSince(since) >= configuration.idleDebounce {
            return .idle
        }
        return current
    }
}
