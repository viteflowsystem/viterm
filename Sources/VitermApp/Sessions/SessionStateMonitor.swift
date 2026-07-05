import AppKit
import GhosttyKit
import VitermCore

/// 監視対象のセッション1件分の状態(サーフェスの弱参照 + 状態機械 + 直近の判定結果)。
private struct WatchEntry {
    weak var surfaceView: GhosttySurfaceView?
    var stateMachine: SessionStateMachine
    var lastEmittedState: AgentSession.State
    var lastFrameSize: CGSize
    /// 次に `ghostty_surface_read_text` を呼んでよい時刻。表示中セッションは毎 tick、
    /// 非表示セッションは `backgroundReadInterval` 間隔まで間引く。
    var nextReadDue: Date
}

/// libghostty サーフェスの画面テキストを取得し、
/// `VitermCore.StateDetectorRegistry` の detector + `SessionStateMachine` に通して
/// セッション状態(busy/waitingInput/idle)を判定する(T13b)。
///
/// `ghostty_surface_read_text` はビューポート全文取得のたびにコストがかかる
/// (`docs/ghostty-integration.md` に "expensive, cache and throttle" と明記)ため、
/// 表示中(選択中)のセッションのみ `pollInterval`(100ms)の高頻度で読み、
/// 非表示セッションは `backgroundReadInterval`(既定600ms)まで間引く。
/// 非表示セッション同士は登録時にランダムな初期オフセットを持たせ、
/// 同一 tick に読み取りが集中しないよう分散させる。
///
/// テキスト取得 API の詳細(セマンティクス・メモリ解放・コスト注意)は
/// `docs/ghostty-integration.md` の「サーフェスの画面テキスト取得(T13b 向け)」参照。
@MainActor
final class SessionStateMonitor {
    /// タイマー自体の tick 間隔。リサイズ検出の粒度を保つため 100ms を維持する
    /// (read_text の呼び出し頻度はこれとは別に `readInterval(for:)` で制御する)。
    static let pollInterval: TimeInterval = 0.1
    /// 表示中セッションの read_text 間隔(= 毎 tick)。
    static let visibleReadInterval: TimeInterval = pollInterval
    /// 非表示セッションの read_text 間隔。busy→waitingInput 等の検出遅延と
    /// 引き換えに呼び出し頻度を下げる(要件: 500ms〜1s)。
    static let backgroundReadInterval: TimeInterval = 0.6

    /// 状態が確定的に変化したときに main actor で発火するコールバック。
    /// `AppModel.sessionStateChanged` への接続はこのクラスの利用側(リード)が行う。
    var onStateChange: ((UUID, AgentSession.State) -> Void)?

    private var entries: [UUID: WatchEntry] = [:]
    private var frameChangeObservers: [UUID: NSObjectProtocol] = [:]
    private var timer: Timer?
    /// 現在フォアグラウンド表示中のセッション。`setVisibleSession` で外部(選択中タブ等)から伝える。
    private var visibleSessionID: UUID?

    /// 表示中セッションを外部から伝える。切り替え後は次 tick で即座に高頻度読み取りへ戻す。
    func setVisibleSession(_ sessionID: UUID?) {
        guard visibleSessionID != sessionID else { return }
        visibleSessionID = sessionID
        guard let sessionID, var entry = entries[sessionID] else { return }
        entry.nextReadDue = Date()
        entries[sessionID] = entry
    }

    /// セッションを監視対象に登録する。同じ `sessionID` で再度呼ぶと既存の監視を差し替える。
    func watch(sessionID: UUID, surfaceView: GhosttySurfaceView, toolName: String) {
        unwatch(sessionID: sessionID)

        let now = Date()
        let detector = StateDetectorRegistry.detector(forToolName: toolName)
        entries[sessionID] = WatchEntry(
            surfaceView: surfaceView,
            stateMachine: SessionStateMachine(detector: detector),
            lastEmittedState: .idle,
            lastFrameSize: surfaceView.frame.size,
            // 表示中なら即読み、非表示なら間隔内でランダムにずらして初回読み取りを分散させる。
            nextReadDue: sessionID == visibleSessionID
                ? now
                : now.addingTimeInterval(.random(in: 0..<Self.backgroundReadInterval))
        )

        // NSView は既定でフレーム変更通知を出さないため、明示的に有効化する
        // (GhosttySurfaceView 自体は変更せず、外部からプロパティを立てるだけで済む)。
        surfaceView.postsFrameChangedNotifications = true
        frameChangeObservers[sessionID] = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: surfaceView,
            queue: .main
        ) { [weak self] _ in
            // NotificationCenter は queue: .main 指定でも closure を静的には
            // main actor 分離と見なさないため、明示的に main actor へ戻す。
            Task { @MainActor in
                self?.recordResize(sessionID: sessionID)
            }
        }

        startTimerIfNeeded()
    }

    /// セッションを監視対象から外す。監視対象が0件になったらタイマーも止める。
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

    /// `sessionID` について今読むべき read_text 間隔。表示中セッションのみ高頻度。
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
        // .common モードでスクロール等のイベントトラッキング中も発火させる。
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
        // Dictionary を for-in で回しながら同じ辞書へ書き戻すのは未定義動作になり得るため、
        // キー一覧を先にスナップショットしてから回す。
        for sessionID in Array(entries.keys) {
            guard var entry = entries[sessionID] else { continue }
            guard let surfaceView = entry.surfaceView, let surface = surfaceView.surface else {
                continue
            }

            // NSViewFrameDidChangeNotification の見落とし・遅延に対する保険として
            // 実サイズの変化もこのポーリングループで二重チェックする。
            let frameSize = surfaceView.frame.size
            if frameSize != entry.lastFrameSize {
                entry.lastFrameSize = frameSize
                entry.stateMachine.recordResize(at: now)
            }

            // read_text は間引く: 表示中セッションは毎 tick、非表示セッションは
            // backgroundReadInterval 間隔でのみ呼ぶ(呼ばない tick でも状態機械の
            // currentState 自体は評価し、idle デバウンスの経過判定は毎 tick 進める)。
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

    /// サーフェスの現在のビューポート(可視領域)テキストを可視行配列として取得する。
    /// 取得できない場合は空配列を返す。
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
