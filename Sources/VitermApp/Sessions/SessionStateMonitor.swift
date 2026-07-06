import AppKit
import GhosttyKit
import VitermCore

/// State for one monitored session (weak surface reference + state machine + last emitted result).
private struct WatchEntry {
    weak var surfaceView: GhosttySurfaceView?
    var stateMachine: SessionStateMachine
    var lastEmittedState: AgentSession.State
    var lastFrameSize: CGSize
    /// Earliest time `ghostty_surface_read_text` may be called next. The visible session reads
    /// every tick; hidden sessions are throttled to the `backgroundReadInterval` interval.
    var nextReadDue: Date
}

/// Reads the screen text of libghostty surfaces and runs it through the
/// `VitermCore.StateDetectorRegistry` detector + `SessionStateMachine` to determine
/// session state (busy/waitingInput/idle) (T13b).
///
/// `ghostty_surface_read_text` is costly every time it fetches the full viewport text
/// (`docs/ghostty-integration.md` explicitly says "expensive, cache and throttle"), so only
/// the visible (selected) session is read at the high `pollInterval` frequency (100ms),
/// while hidden sessions are throttled to `backgroundReadInterval` (default 600ms).
/// Hidden sessions get a random initial offset at registration time so their reads are
/// spread out instead of clustering on the same tick.
///
/// For details of the text-read API (semantics, memory freeing, cost caveats), see the
/// "surface screen text reading (for T13b)" section of `docs/ghostty-integration.md`.
@MainActor
final class SessionStateMonitor {
    /// Tick interval of the timer itself. Kept at 100ms to preserve resize-detection
    /// granularity (the read_text call frequency is controlled separately by `readInterval(for:)`).
    static let pollInterval: TimeInterval = 0.1
    /// read_text interval for the visible session (= every tick).
    static let visibleReadInterval: TimeInterval = pollInterval
    /// read_text interval for hidden sessions. Lowers call frequency at the cost of
    /// detection latency for busy→waitingInput etc. (requirement: 500ms-1s).
    static let backgroundReadInterval: TimeInterval = 0.6

    /// Callback fired on the main actor when the state has definitively changed.
    /// Wiring to `AppModel.sessionStateChanged` is done by this class's consumer (the lead).
    var onStateChange: ((UUID, AgentSession.State) -> Void)?

    private var entries: [UUID: WatchEntry] = [:]
    private var frameChangeObservers: [UUID: NSObjectProtocol] = [:]
    private var timer: Timer?
    /// The session currently displayed in the foreground. Communicated from outside
    /// (selected tab, etc.) via `setVisibleSession`.
    private var visibleSessionID: UUID?

    /// Communicate the visible session from outside. After a switch, return to high-frequency
    /// reads immediately on the next tick.
    func setVisibleSession(_ sessionID: UUID?) {
        guard visibleSessionID != sessionID else { return }
        visibleSessionID = sessionID
        guard let sessionID, var entry = entries[sessionID] else { return }
        entry.nextReadDue = Date()
        entries[sessionID] = entry
    }

    /// Register a session for monitoring. Calling again with the same `sessionID` replaces the existing watch.
    func watch(sessionID: UUID, surfaceView: GhosttySurfaceView, toolName: String) {
        unwatch(sessionID: sessionID)

        let now = Date()
        let detector = StateDetectorRegistry.detector(forToolName: toolName)
        entries[sessionID] = WatchEntry(
            surfaceView: surfaceView,
            stateMachine: SessionStateMachine(detector: detector),
            lastEmittedState: .idle,
            lastFrameSize: surfaceView.frame.size,
            // If visible, read immediately; if hidden, spread the first read randomly within the interval.
            nextReadDue: sessionID == visibleSessionID
                ? now
                : now.addingTimeInterval(.random(in: 0..<Self.backgroundReadInterval))
        )

        // NSView does not post frame-change notifications by default, so enable them explicitly
        // (no change to GhosttySurfaceView itself; setting the property from outside suffices).
        surfaceView.postsFrameChangedNotifications = true
        frameChangeObservers[sessionID] = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: surfaceView,
            queue: .main
        ) { [weak self] _ in
            // Even with queue: .main, NotificationCenter does not statically treat the closure
            // as main-actor-isolated, so hop back to the main actor explicitly.
            Task { @MainActor in
                self?.recordResize(sessionID: sessionID)
            }
        }

        startTimerIfNeeded()
    }

    /// Remove a session from monitoring. Stops the timer when no sessions remain watched.
    func unwatch(sessionID: UUID) {
        entries.removeValue(forKey: sessionID)
        if let observer = frameChangeObservers.removeValue(forKey: sessionID) {
            NotificationCenter.default.removeObserver(observer)
        }
        if visibleSessionID == sessionID {
            visibleSessionID = nil
        }
        if entries.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    /// The read_text interval currently applicable to `sessionID`. High frequency only for the visible session.
    private func readInterval(for sessionID: UUID) -> TimeInterval {
        sessionID == visibleSessionID ? Self.visibleReadInterval : Self.backgroundReadInterval
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let newTimer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        // .common mode keeps it firing during event tracking such as scrolling.
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func recordResize(sessionID: UUID) {
        guard var entry = entries[sessionID] else { return }
        entry.stateMachine.recordResize(at: Date())
        entries[sessionID] = entry
    }

    private func tick() {
        let now = Date()
        // Writing back into a Dictionary while iterating it with for-in can be undefined
        // behavior, so snapshot the key list first and iterate over that.
        for sessionID in Array(entries.keys) {
            guard var entry = entries[sessionID] else { continue }
            guard let surfaceView = entry.surfaceView, let surface = surfaceView.surface else {
                continue
            }

            // As insurance against missed or delayed NSViewFrameDidChangeNotification,
            // also double-check actual size changes in this polling loop.
            let frameSize = surfaceView.frame.size
            if frameSize != entry.lastFrameSize {
                entry.lastFrameSize = frameSize
                entry.stateMachine.recordResize(at: now)
            }

            // Throttle read_text: the visible session reads every tick; hidden sessions only
            // at backgroundReadInterval intervals (on ticks without a read, the state machine's
            // currentState is still evaluated, so the idle debounce elapse check advances every tick).
            if now >= entry.nextReadDue {
                let lines = Self.readViewportLines(surface: surface)
                entry.stateMachine.recordOutput(screenLines: lines, at: now)
                entry.nextReadDue = now.addingTimeInterval(readInterval(for: sessionID))
            }
            let newState = entry.stateMachine.currentState(at: now)

            let didChange = newState != entry.lastEmittedState
            if didChange {
                entry.lastEmittedState = newState
            }
            entries[sessionID] = entry

            if didChange {
                onStateChange?(sessionID, newState)
            }
        }
    }

    /// Read the surface's current viewport (visible area) text as an array of visible lines.
    /// Returns an empty array if it cannot be read.
    private static func readViewportLines(surface: ghostty_surface_t) -> [String] {
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false
        )
        guard ghostty_surface_read_text(surface, selection, &text) else { return [] }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let cString = text.text else { return [] }
        return String(cString: cString)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }
}
