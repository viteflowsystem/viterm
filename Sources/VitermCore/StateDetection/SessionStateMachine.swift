import Foundation

/// `StateDetector` の即時シグナルに、idle デバウンスとリサイズ抑制を重ねて
/// `AgentSession.State`(busy/waitingInput/idle)を確定させる状態機械。
///
/// - idle は即確定しない: busy/waitingInput のシグナルが途絶えてから
///   `configuration.idleDebounce`(既定1.5秒)経過して初めて idle が確定する。
/// - リサイズ直後は `configuration.resizeSuppressionWindow`(既定250ms)の間、
///   画面テキストの再判定を行わない。リサイズ直後の再描画による誤検出を防ぐ
///   (ccmanager Issue #73 の教訓)。
///
/// 時刻は全て呼び出し側から注入する(`Date` を直接取得しない)ため、
/// ユニットテストで任意の経過時間をシミュレートできる。
public struct SessionStateMachine: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// busy/waitingInput シグナルが途絶えてから idle が確定するまでの時間。
        public var idleDebounce: TimeInterval
        /// リサイズ直後、判定を抑制する時間。
        public var resizeSuppressionWindow: TimeInterval

        public init(idleDebounce: TimeInterval = 1.5, resizeSuppressionWindow: TimeInterval = 0.25) {
            self.idleDebounce = idleDebounce
            self.resizeSuppressionWindow = resizeSuppressionWindow
        }
    }

    public let detector: any StateDetector
    public var configuration: Configuration

    /// 最後に確定していた状態(busy/waitingInput、またはデバウンス確定済みの idle)。
    private var current: AgentSession.State
    /// busy/waitingInput シグナルが途絶えた(= idle候補になった)時刻。まだ何も途絶えていなければ nil。
    private var idleCandidateSince: Date?
    /// この時刻より前は判定を抑制する(リサイズ直後)。
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

    /// PTY からの出力を受け取ったタイミングで呼ぶ。`screenLines` はその時点の画面全体。
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

    /// ターミナルがリサイズされたタイミングで呼ぶ。以降 `resizeSuppressionWindow` の間、
    /// `recordOutput` の判定を抑制する。
    public mutating func recordResize(at now: Date) {
        resizeSuppressedUntil = now.addingTimeInterval(configuration.resizeSuppressionWindow)
    }

    /// `now` 時点で確定している状態を返す。
    public func currentState(at now: Date) -> AgentSession.State {
        if let suppressedUntil = resizeSuppressedUntil, now < suppressedUntil {
            // 抑制期間中は idle デバウンスの経過判定も凍結し、直前の確定状態を返す。
            return current
        }
        if let since = idleCandidateSince, now.timeIntervalSince(since) >= configuration.idleDebounce {
            return .idle
        }
        return current
    }
}
