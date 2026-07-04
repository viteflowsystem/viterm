import AppKit
import GhosttyKit

/// libghostty サーフェス1枚をホストする NSView。
///
/// レンダリング(Metal)は libghostty が nsview に対して直接行うため、
/// ホスト側の責務は「サイズ・フォーカス・入力イベントをサーフェスへ中継する」こと。
/// 実装リファレンス: Ghostty.app macOS 版 SurfaceView_AppKit.swift
final class GhosttySurfaceView: NSView {
    // deinit(nonisolated)から解放するため unsafe 指定。書き込みは init/deinit のみ。
    nonisolated(unsafe) private(set) var surface: ghostty_surface_t?

    /// IME 変換中(未確定)のテキスト。NSTextInputClient の setMarkedText/unmarkText で更新する。
    private var markedText = NSMutableAttributedString()

    /// keyDown 処理中のみ non-nil。interpretKeyEvents 経由で呼ばれた insertText の結果をここに
    /// 蓄積し、まとめて sendKey に渡す(実装リファレンス: SurfaceView_AppKit.swift の同名の仕組み)。
    private var keyTextAccumulator: [String]?

    // MARK: - OSC 通知(GhosttyRuntime.action_cb から呼ばれる)
    //
    // libghostty がターミナル出力中の OSC シーケンス(デスクトップ通知は OSC 9/777、pwd は OSC 7 等)
    // を解釈すると action_cb が呼ばれ、GhosttyRuntime が対応するサーフェスの本コールバックを
    // 発火する。状態検出の一次シグナルとして SessionStateMonitor 等から利用する想定
    // (docs/ghostty-integration.md 参照)。

    /// OSC 9 / OSC 777 によるデスクトップ通知(`GHOSTTY_ACTION_DESKTOP_NOTIFICATION`)を受信した。
    var onDesktopNotification: ((_ title: String, _ body: String) -> Void)?

    /// ベル(`GHOSTTY_ACTION_RING_BELL`)を受信した。
    var onBell: (() -> Void)?

    /// OSC 0/1/2 等によるタイトル変更(`GHOSTTY_ACTION_SET_TITLE`)を受信した。
    var onTitleChange: ((_ title: String) -> Void)?

    /// OSC 7 によるカレントディレクトリ変更(`GHOSTTY_ACTION_PWD`)を受信した。
    var onPwdChange: ((_ pwd: String) -> Void)?

    /// 子プロセスの終了等で libghostty がサーフェスのクローズを要求した(`close_surface_cb` 経由)。
    /// セッションの後始末(一覧からの削除・ペインのクローズ)は呼び出し側の責務。
    var onSurfaceClose: (() -> Void)?

    /// コマンド終了(`GHOSTTY_ACTION_COMMAND_FINISHED`)を受信した。OSC 133 のセマンティック
    /// プロンプト(`end_input_start_output` → `end_command`)由来で、シェル統合が有効な場合のみ
    /// 発火する(docs/ghostty-integration.md 参照。vitea は現状シェル統合リソースを配布して
    /// いないため発火しない)。`exitCode` は終了コードが報告されていれば 0-255、未報告なら nil。
    /// `duration` はコマンドの実行時間(秒)。
    var onCommandFinished: ((_ exitCode: Int32?, _ duration: TimeInterval) -> Void)?

    /// 進捗レポート(`GHOSTTY_ACTION_PROGRESS_REPORT`、OSC 9;4 由来)を受信した。シェル統合とは
    /// 無関係に、実行中のプログラムが直接 OSC 9;4 を出力すれば発火しうる(docs/ghostty-integration.md
    /// 参照)。`progress` は 0-100 の割合が報告されていればその値、未報告なら nil。
    var onProgressReport: ((_ state: ghostty_action_progress_report_state_e, _ progress: Int?) -> Void)?

    /// - Parameters:
    ///   - command: 起動コマンド。nil ならユーザーのデフォルトシェル。
    ///   - workingDirectory: 作業ディレクトリ。nil ならホーム。
    init(command: String? = nil, workingDirectory: String? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        // SessionStateMonitor 等がリサイズ通知(frameDidChangeNotification)に依存する。
        postsFrameChangedNotifications = true

        guard let app = GhosttyRuntime.shared.app else { return }

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque())
        )
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)

        // withCString のスコープ内で ghostty_surface_new まで完了させる必要がある
        // (config が保持する const char* はコピーされないため)。
        func create(_ cfg: inout ghostty_surface_config_s) {
            surface = ghostty_surface_new(app, &cfg)
        }
        switch (command, workingDirectory) {
        case let (cmd?, wd?):
            cmd.withCString { c in
                wd.withCString { w in
                    config.command = c
                    config.working_directory = w
                    create(&config)
                }
            }
        case let (cmd?, nil):
            cmd.withCString { c in
                config.command = c
                create(&config)
            }
        case let (nil, wd?):
            wd.withCString { w in
                config.working_directory = w
                create(&config)
            }
        case (nil, nil):
            create(&config)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let surface {
            ghostty_surface_free(surface)
        }
    }

    // MARK: - Layout / focus

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        syncSurfaceSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        ghostty_surface_set_content_scale(surface, scale, scale)
        syncSurfaceSize()
    }

    private func syncSurfaceSize() {
        guard let surface, frame.width > 0, frame.height > 0 else { return }
        let backing = convertToBacking(bounds)
        ghostty_surface_set_size(surface, UInt32(backing.width), UInt32(backing.height))
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let surface { ghostty_surface_set_focus(surface, true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok, let surface { ghostty_surface_set_focus(surface, false) }
        return ok
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard surface != nil else {
            interpretKeyEvents([event])
            return
        }

        // preedit(変換中)かどうかを interpretKeyEvents 呼び出し前に記録しておく。
        // IME がこの入力で preedit を打ち切った場合(例: 変換中に Backspace)の composing 判定に使う。
        let markedTextBefore = markedText.length > 0

        // interpretKeyEvents 経由で NSTextInputClient(setMarkedText/insertText)にこのキー
        // イベントを処理させる。通常入力・IME確定テキストは insertText 側で蓄積する。
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        interpretKeyEvents([event])

        syncPreedit(clearIfNeeded: markedTextBefore)

        let action: ghostty_input_action_e = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        if let accumulated = keyTextAccumulator, !accumulated.isEmpty {
            // insertText で確定したテキスト(通常入力 or IME確定)。
            for text in accumulated {
                sendKey(action, event: event, text: text, composing: false)
            }
        } else {
            // insertText が呼ばれなかった通常のキー(矢印・Enter・Ctrl+C 等)。変換中、または
            // この入力で変換が打ち切られた場合は composing を立てて ghostty 側に伝える。
            sendKey(
                action,
                event: event,
                text: Self.ghosttyText(for: event),
                composing: markedText.length > 0 || markedTextBefore
            )
        }
    }

    override func keyUp(with event: NSEvent) {
        sendKey(GHOSTTY_ACTION_RELEASE, event: event, text: nil, composing: false)
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default:
            super.flagsChanged(with: event)
            return
        }

        // 変換中は修飾キー単体の press/release を送らない(本家 SurfaceView_AppKit.swift 準拠)。
        guard markedText.length == 0 else { return }

        let mods = Self.ghosttyMods(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            // 押されたのが左右どちら側の修飾キーかを判定する。反対側の同じ修飾キーがまだ
            // 押されたままの場合は release として扱う。
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: sidePressed = true
            }
            if sidePressed { action = GHOSTTY_ACTION_PRESS }
        }

        sendKey(action, event: event, text: nil, composing: false)
    }

    private func sendKey(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        text: String?,
        composing: Bool
    ) {
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.action = action
        key.mods = Self.ghosttyMods(event.modifierFlags)
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.keycode = UInt32(event.keyCode)
        key.composing = composing
        key.unshifted_codepoint = event.charactersIgnoringModifiers?.unicodeScalars.first?.value ?? 0

        // 単一の制御文字(Ctrl+C 等)やファンクションキー相当の PUA コードポイントはここでは
        // 送らない。ghostty 側が keycode/mods から制御バイトやエスケープシーケンスを組み立てる。
        if let text, let codepoint = text.utf8.first, codepoint >= 0x20 {
            text.withCString { cstr in
                key.text = cstr
                _ = ghostty_surface_key(surface, key)
            }
        } else {
            key.text = nil
            _ = ghostty_surface_key(surface, key)
        }
    }

    /// キーイベントから ghostty へ送るテキストを求める。制御文字・ファンクションキーの PUA
    /// コードポイントは除外する(実装リファレンス: NSEvent+Extension.swift の ghosttyCharacters)。
    private static func ghosttyText(for event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }
        return characters
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘V ペースト: NSPasteboard から直接サーフェスにテキストを送る。
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "v",
           let surface,
           let string = NSPasteboard.general.string(forType: .string) {
            string.withCString { cstr in
                ghostty_surface_text(surface, cstr, UInt(string.utf8.count))
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// markedText の内容を ghostty の preedit 表示に反映する。markedText が空になった場合
    /// (確定 or 変換キャンセル)は clearIfNeeded が立っていれば preedit をクリアする。
    private func syncPreedit(clearIfNeeded: Bool) {
        guard let surface else { return }
        if markedText.length > 0 {
            let str = markedText.string
            let len = str.utf8CString.count
            if len > 0 {
                str.withCString { ptr in
                    // 末尾の NUL 終端文字の分を引く。
                    ghostty_surface_preedit(surface, ptr, UInt(len - 1))
                }
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    private static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(mods)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, Self.ghosttyMods(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, Self.ghosttyMods(event.modifierFlags))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return super.rightMouseDown(with: event) }
        _ = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, Self.ghosttyMods(event.modifierFlags))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return super.rightMouseUp(with: event) }
        _ = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, Self.ghosttyMods(event.modifierFlags))
    }

    override func otherMouseDown(with event: NSEvent) {
        // 中クリック(ボタン番号2)のみ中継する。
        guard let surface, event.buttonNumber == 2 else { return }
        _ = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, Self.ghosttyMods(event.modifierFlags))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let surface, event.buttonNumber == 2 else { return }
        _ = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, Self.ghosttyMods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) {
        reportMousePos(event)
    }

    override func mouseDragged(with event: NSEvent) {
        reportMousePos(event)
    }

    private func reportMousePos(_ event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        // libghostty は左上原点の座標系を期待する。
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, Self.ghosttyMods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var mods: Int32 = 0
        if event.hasPreciseScrollingDeltas { mods = 1 }
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, ghostty_input_scroll_mods_t(mods))
    }
}

// MARK: - NSTextInputClient (日本語 IME 対応)
//
// keyDown 内の interpretKeyEvents([event]) がこのメソッド群を呼び出す。通常入力・IME 確定
// テキストは insertText、変換中(preedit)は setMarkedText/unmarkText 経由で処理される。
// 実装リファレンス: SurfaceView_AppKit.swift の同名メソッド群。
extension GhosttySurfaceView: @MainActor NSTextInputClient {
    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange() }
        return NSRange(location: 0, length: markedText.length)
    }

    func selectedRange() -> NSRange {
        guard let surface else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: v)
        case let v as String:
            markedText = NSMutableAttributedString(string: v)
        default:
            break
        }

        // keyDown の外(キーボードレイアウト切り替え等)からの変更は即座に preedit へ反映する。
        // keyDown 内であれば、keyDown 側が呼び出し後にまとめて syncPreedit する。
        if keyTextAccumulator == nil {
            syncPreedit(clearIfNeeded: true)
        }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit(clearIfNeeded: true)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let surface, range.length > 0 else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSAttributedString(string: String(cString: text.text))
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else {
            return NSRect(x: frame.origin.x, y: frame.origin.y, width: 0, height: 0)
        }

        // ghostty がカーソル位置(IME 候補ウィンドウを出すべき場所)を教えてくれる。
        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)

        // ghostty の座標系は左上原点なので、AppKit の左下原点(ウィンドウ座標)に変換する。
        let viewRect = NSRect(x: x, y: frame.size.height - y, width: width, height: height)
        let winRect = convert(viewRect, to: nil)
        guard let window else { return winRect }
        return window.convertToScreen(winRect)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard let surface, NSApp.currentEvent != nil else { return }

        let chars: String
        switch string {
        case let v as NSAttributedString: chars = v.string
        case let v as String: chars = v
        default: return
        }

        // insertText が呼ばれた時点で変換は確定しているので preedit を終了する。
        unmarkText()

        if var accumulated = keyTextAccumulator {
            // keyDown 処理中: 後段の sendKey にまとめて渡すため蓄積するだけ。
            accumulated.append(chars)
            keyTextAccumulator = accumulated
            return
        }

        // keyDown の外からの確定(絵文字ピッカー、音声入力等)は直接送る。
        chars.withCString { cstr in
            ghostty_surface_text(surface, cstr, UInt(chars.utf8.count))
        }
    }

    /// NSResponder.doCommand(by:) をオーバーライドし、未対応コマンドで NSBeep が鳴るのを防ぐ。
    override func doCommand(by selector: Selector) {
        // 現時点では特別なコマンド処理はしない(既存動作を壊さないための最小実装)。
    }
}
