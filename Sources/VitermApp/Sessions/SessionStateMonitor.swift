import AppKit
import GhosttyKit
import VitermCore

/// State for one watched session (weak surface reference + state machine + latest verdict).
private struct WatchEntry {
    weak var surfaceView: GhosttySurfaceView?
    var stateMachine: SessionStateMachine
    var lastEmittedState: AgentSession.State
    var lastFrameSize: CGSize
    /// The next time `ghostty_surface_read_text` may be called. Every tick for the visible
    /// session; throttled to `backgroundReadInterval` for hidden ones.
    var nextReadDue: Date
}

/// Fetches screen text from libghostty surfaces and runs it through
/// `VitermCore.StateDetectorRegistry` detectors + `SessionStateMachine` to determine the
/// session state (busy/waitingInput/idle) (T13b).
///
/// `ghostty_surface_read_text` costs on every full-viewport fetch
/// (`docs/ghostty-integration.md` explicitly says "expensive, cache and throttle"), so
/// only the visible (selected) session is read at the high `pollInterval` frequency
/// (100ms); hidden sessions are throttled to `backgroundReadInterval` (default 600ms).
/// Hidden sessions get a random initial offset at registration so reads don't pile up on
/// the same tick.
///
/// For details of the text-fetch API (semantics, memory freeing, cost caveats), see the
/// section on fetching surface screen text (for T13b) in `docs/ghostty-integration.md`.
@MainActor
final class SessionStateMonitor {
    /// The timer's own tick interval. Kept at 100ms to preserve resize-detection
    /// granularity (read_text call frequency is controlled separately by `readInterval(for:)`).
    static let pollInterval: TimeInterval = 0.1
    /// read_text interval for the visible session (= every tick).
    static let visibleReadInterval: TimeInterval = pollInterval
    /// read_text interval for hidden sessions. Trades detection latency (busy→waitingInput
    /// etc.) for a lower call frequency (requirement: 500ms-1s).
    static let backgroundReadInterval: TimeInterval = 0.6

    /// Callback fired on the main actor when the state changes definitively. Wiring it to
    /// `AppModel.sessionStateChanged` is done by this class's consumer (the lead).
    var onStateChange: ((UUID, AgentSession.State) -> Void)?

    private var entries: [UUID: WatchEntry] = [:]
    private var frameChangeObservers: [UUID: NSObjectProtocol] = [:]
    private var timer: Timer?
    /// The session currently shown in the foreground. Communicated from outside (selected tab, etc.) via `setVisibleSession`.
    private var visibleSessionID: UUID?

    /// Communicate the visible session from outside. After a switch, high-frequency reading resumes immediately on the next tick.
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
            // Read immediately if visible; if hidden, randomize within the interval to spread out initial reads.
            nextReadDue: sessionID == visibleSessionID
                ? now
                : now.addingTimeInterval(.random(in: 0..<Self.backgroundReadInterval))
        )

        // NSView doesn't emit frame-change notifications by default, so enable them
        // explicitly (no change to GhosttySurfaceView itself; setting the property from
        // outside suffices).
        surfaceView.postsFrameChangedNotifications = true
        frameChangeObservers[sessionID] = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: surfaceView,
            queue: .main
        ) { [weak self] _ in
            // Even with queue: .main, NotificationCenter doesn't statically treat the
            // closure as main-actor isolated, so hop back to the main actor explicitly.
            Task { @MainActor in
                self?.recordResize(sessionID: sessionID)
            }
        }

        startTimerIfNeeded()
    }

    /// Remove a session from monitoring. When nothing is watched anymore, the timer stops too.
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
        // behavior, so snapshot the keys first and iterate over those.
        for sessionID in Array(entries.keys) {
            guard var entry = entries[sessionID] else { continue }
            guard let surfaceView = entry.surfaceView, let surface = surfaceView.surface else {
                continue
            }

            // As insurance against missed or delayed NSViewFrameDidChangeNotification,
            // double-check actual size changes in this polling loop too.
            let frameSize = surfaceView.frame.size
            if frameSize != entry.lastFrameSize {
                entry.lastFrameSize = frameSize
                entry.stateMachine.recordResize(at: now)
            }

            // Throttle read_text: every tick for the visible session, only at
            // backgroundReadInterval for hidden ones (on non-reading ticks the state
            // machine's currentState is still evaluated, so the idle-debounce elapsed check
            // advances every tick).
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

    /// Fetch the surface's current viewport (visible area) text as an array of visible
    /// lines. Returns an empty array when unavailable.
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
