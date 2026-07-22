import AppKit
import GhosttyKit

/// NSView hosting one libghostty surface.
///
/// libghostty renders (Metal) directly onto the nsview, so the host's job is relaying
/// size, focus, and input events to the surface.
/// Implementation reference: Ghostty.app macOS SurfaceView_AppKit.swift
final class GhosttySurfaceView: NSView {
    // Marked unsafe so it can be freed from deinit (nonisolated). Written only in init/deinit.
    nonisolated(unsafe) private(set) var surface: ghostty_surface_t?

    /// Text being composed by the IME (unconfirmed). Updated via NSTextInputClient's setMarkedText/unmarkText.
    private var markedText = NSMutableAttributedString()

    /// Non-nil only while keyDown is being handled. Results of insertText called via
    /// interpretKeyEvents accumulate here and are passed to sendKey in one go
    /// (implementation reference: the same mechanism in SurfaceView_AppKit.swift).
    private var keyTextAccumulator: [String]?

    /// The mouse cursor shape currently requested by libghostty
    /// (via `GHOSTTY_ACTION_MOUSE_SHAPE`). Applied from both cursorUpdate
    /// and setCursorShape.
    private var currentCursor: NSCursor = .iBeam

    /// Whether the mouse is inside the view (updated by mouseEntered/mouseExited).
    /// Guards against changing the cursor shape while outside the view.
    private var mouseInside = false

    // MARK: - OSC notifications (called from GhosttyRuntime.action_cb)
    //
    // When libghostty interprets OSC sequences in terminal output (desktop notifications
    // are OSC 9/777, pwd is OSC 7, etc.), action_cb fires and GhosttyRuntime invokes the
    // corresponding surface's callback here. Intended for use by SessionStateMonitor and
    // others as a primary state-detection signal (see docs/ghostty-integration.md).

    /// Received a desktop notification via OSC 9 / OSC 777 (`GHOSTTY_ACTION_DESKTOP_NOTIFICATION`).
    var onDesktopNotification: ((_ title: String, _ body: String) -> Void)?

    /// Received the bell (`GHOSTTY_ACTION_RING_BELL`).
    var onBell: (() -> Void)?

    /// Received a title change via OSC 0/1/2 etc. (`GHOSTTY_ACTION_SET_TITLE`).
    var onTitleChange: ((_ title: String) -> Void)?

    /// Received a working-directory change via OSC 7 (`GHOSTTY_ACTION_PWD`).
    var onPwdChange: ((_ pwd: String) -> Void)?

    /// libghostty requested closing the surface (via `close_surface_cb`), e.g. because the
    /// child process exited. Session cleanup (removal from the list, closing the pane) is
    /// the caller's responsibility.
    var onSurfaceClose: (() -> Void)?

    /// Received command completion (`GHOSTTY_ACTION_COMMAND_FINISHED`). Comes from OSC 133
    /// semantic prompts (`end_input_start_output` → `end_command`) and only fires when
    /// shell integration is enabled (see docs/ghostty-integration.md; viterm currently
    /// ships no shell integration resources, so it never fires). `exitCode` is 0-255 when
    /// an exit code was reported, nil otherwise. `duration` is the command's run time in
    /// seconds.
    var onCommandFinished: ((_ exitCode: Int32?, _ duration: TimeInterval) -> Void)?

    /// Received a progress report (`GHOSTTY_ACTION_PROGRESS_REPORT`, from OSC 9;4).
    /// Independent of shell integration — any running program emitting OSC 9;4 directly can
    /// trigger it (see docs/ghostty-integration.md). `progress` is the reported 0-100
    /// percentage, or nil when unreported.
    var onProgressReport: ((_ state: ghostty_action_progress_report_state_e, _ progress: Int?) -> Void)?

    /// - Parameters:
    ///   - command: The command to launch. nil means the user's default shell.
    ///   - workingDirectory: The working directory. nil means home.
    init(command: String? = nil, workingDirectory: String? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        // SessionStateMonitor and others depend on resize notifications (frameDidChangeNotification).
        postsFrameChangedNotifications = true

        // Accept files/URLs/text dropped onto the terminal (drag & drop). The dropped
        // paths are inserted into the buffer at the cursor (see NSDraggingDestination below).
        registerForDraggedTypes(Array(Self.dropTypes))

        // There are cases where viewDidChangeBackingProperties is not called when the
        // screen changes (monitor connected, resolution change, etc.), so fire it manually
        // from the screen-change notification
        // (implementation reference: SurfaceView_AppKit.swift, ghostty#2731).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidChangeScreen(_:)),
            name: NSWindow.didChangeScreenNotification,
            object: nil)

        guard let app = GhosttyRuntime.shared.app else { return }

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque())
        )
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)

        // ghostty_surface_new must complete within the withCString scope
        // (the const char* held by config is not copied).
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
        guard let window else { return }

        // Resolution/DPI is handled by libghostty itself, so keep the layer's
        // contentsScale in sync with the screen's scale. If they drift apart, the Core
        // Animation compositor scales the layer contents during compositing, producing a
        // zoomed-looking display
        // (implementation reference: the same method in SurfaceView_AppKit.swift).
        CATransaction.begin()
        // Suppress the implicit scale animation when contentsScale changes.
        CATransaction.setDisableActions(true)
        layer?.contentsScale = window.backingScaleFactor
        CATransaction.commit()

        guard let surface else { return }
        let scale = window.backingScaleFactor
        ghostty_surface_set_content_scale(surface, scale, scale)
        syncSurfaceSize()
    }

    /// The window moved to another screen (or the monitor configuration changed). Update
    /// the display ID used for vsync, and re-fire viewDidChangeBackingProperties in case
    /// the scale changed.
    @objc private func windowDidChangeScreen(_ notification: Notification) {
        guard let window,
              let object = notification.object as? NSWindow, window == object,
              let screen = window.screen,
              let surface else { return }

        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
        ghostty_surface_set_display_id(surface, displayID ?? 0)

        DispatchQueue.main.async { [weak self] in
            self?.viewDidChangeBackingProperties()
        }
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

    // MARK: - Font size

    // Called from the menu (via the target: nil first responder chain). These run ghostty
    // keybinding actions as-is, so the actual font size change and relayout happen on the
    // libghostty side.

    @objc func increaseFontSize(_ sender: Any?) { performBindingAction("increase_font_size:1") }
    @objc func decreaseFontSize(_ sender: Any?) { performBindingAction("decrease_font_size:1") }
    @objc func resetFontSize(_ sender: Any?) { performBindingAction("reset_font_size") }

    private func performBindingAction(_ action: String) {
        guard let surface else { return }
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard surface != nil else {
            interpretKeyEvents([event])
            return
        }

        // Record whether we were in preedit (composing) before calling interpretKeyEvents.
        // Used for the composing decision when the IME aborts the preedit on this input
        // (e.g. Backspace during composition).
        let markedTextBefore = markedText.length > 0

        // Let NSTextInputClient (setMarkedText/insertText) handle this key event via
        // interpretKeyEvents. Regular input and IME-confirmed text accumulate in insertText.
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        interpretKeyEvents([event])

        syncPreedit(clearIfNeeded: markedTextBefore)

        let action: ghostty_input_action_e = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        if let accumulated = keyTextAccumulator, !accumulated.isEmpty {
            // Text confirmed by insertText (regular input or IME confirmation).
            for text in accumulated {
                sendKey(action, event: event, text: text, composing: false)
            }
        } else {
            // Ordinary keys where insertText was not called (arrows, Enter, Ctrl+C, etc.).
            // If composing, or if composition was aborted by this input, set composing so
            // ghostty knows.
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

        // While composing, don't send bare modifier press/release (per upstream SurfaceView_AppKit.swift).
        guard markedText.length == 0 else { return }

        let mods = Self.ghosttyMods(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            // Determine which side (left/right) of the modifier was pressed. If the same
            // modifier on the other side is still held down, treat this as a release.
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
        // Assume control and command don't contribute to text translation, and treat the
        // rest (shift/option) as consumed by translation (same heuristic as upstream
        // ghosttyKeyEvent). If this were NONE, then when IME-confirmed text arrives on a
        // shifted key (e.g. "?" during composition), shift would remain in ghostty core's
        // effective mods, and with the kitty keyboard protocol enabled the confirmed text
        // would be dropped and only a CSI sequence sent.
        key.consumed_mods = Self.ghosttyMods(event.modifierFlags.subtracting([.control, .command]))
        key.keycode = UInt32(event.keyCode)
        key.composing = composing
        // The unshifted codepoint is "the character typed without modifiers" ("/" for the
        // "?" key). charactersIgnoringModifiers doesn't drop shift, so it isn't used (per
        // upstream). characters(byApplyingModifiers:) only works on keyDown/keyUp NSEvents.
        key.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp {
            key.unshifted_codepoint = event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0
        }

        // Single control characters (Ctrl+C, etc.) and function-key PUA codepoints are not
        // sent here. ghostty builds the control bytes / escape sequences from keycode/mods.
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

    /// Derive the text to send to ghostty from a key event. Excludes control characters
    /// and function-key PUA codepoints (implementation reference: ghosttyCharacters in
    /// NSEvent+Extension.swift).
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
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "c" {
            if let surface, ghostty_surface_has_selection(surface) {
                performBindingAction("copy_to_clipboard")
            }
            return true
        }

        // ⌘V paste: send the text straight from NSPasteboard to the surface.
        // Plain ⌘V only — combos with extra modifiers (⌘⌥V etc.) are app shortcuts
        // and must not be swallowed as a paste.
        if event.modifierFlags.contains(.command),
           event.modifierFlags.intersection([.option, .control]).isEmpty,
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

    /// Reflect markedText into ghostty's preedit display. If markedText became empty
    /// (confirmed or composition canceled), clear the preedit when clearIfNeeded is set.
    private func syncPreedit(clearIfNeeded: Bool) {
        guard let surface else { return }
        if markedText.length > 0 {
            let str = markedText.string
            let len = str.utf8CString.count
            if len > 0 {
                str.withCString { ptr in
                    // Subtract the trailing NUL terminator.
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

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)

        // Forwarding mouseMoved is required for link detection while hovering
        // (cmd+hover underline). Use activeAlways so mouse reports are sent
        // even when unfocused (reference: SurfaceView_AppKit.swift
        // updateTrackingAreas).
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
            owner: self,
            userInfo: nil))

        // cursorUpdate cannot be combined with activeAlways, so it gets its
        // own tracking area.
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .inVisibleRect, .activeInKeyWindow],
            owner: self,
            userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        currentCursor.set()
    }

    /// Applies `GHOSTTY_ACTION_MOUSE_SHAPE` to NSCursor (called from GhosttyRuntime).
    func setCursorShape(_ shape: ghostty_action_mouse_shape_e) {
        let cursor: NSCursor
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: cursor = .arrow
        case GHOSTTY_MOUSE_SHAPE_TEXT: cursor = .iBeam
        case GHOSTTY_MOUSE_SHAPE_POINTER: cursor = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_GRAB: cursor = .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: cursor = .closedHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: cursor = .crosshair
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: cursor = .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: cursor = .contextualMenu
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED: cursor = .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_W_RESIZE: cursor = .resizeLeft
        case GHOSTTY_MOUSE_SHAPE_E_RESIZE: cursor = .resizeRight
        case GHOSTTY_MOUSE_SHAPE_N_RESIZE: cursor = .resizeUp
        case GHOSTTY_MOUSE_SHAPE_S_RESIZE: cursor = .resizeDown
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE: cursor = .resizeUpDown
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE: cursor = .resizeLeftRight
        default: return // Ignore unsupported shapes (matching Ghostty.app)
        }
        currentCursor = cursor
        if mouseInside { cursor.set() }
    }

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
        if ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, Self.ghosttyMods(event.modifierFlags)) {
            return
        }
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return super.rightMouseUp(with: event) }
        _ = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, Self.ghosttyMods(event.modifierFlags))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        // Manual enabled state below; auto-enablement would override it.
        menu.autoenablesItems = false

        let copyItem = NSMenuItem(
            title: "コピー", action: #selector(copySelection(_:)), keyEquivalent: "")
        copyItem.target = self
        copyItem.isEnabled = surface.map { ghostty_surface_has_selection($0) } ?? false
        menu.addItem(copyItem)

        let pasteItem = NSMenuItem(
            title: "ペースト", action: #selector(pasteFromClipboard(_:)), keyEquivalent: "")
        pasteItem.target = self
        menu.addItem(pasteItem)

        let selectAllItem = NSMenuItem(
            title: "すべて選択", action: #selector(selectAllTerminalText(_:)), keyEquivalent: "")
        selectAllItem.target = self
        menu.addItem(selectAllItem)

        menu.addItem(.separator())

        let resetItem = NSMenuItem(
            title: "ターミナルをリセット", action: #selector(resetTerminal(_:)), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)

        return menu
    }

    @objc private func copySelection(_ sender: Any?) {
        performBindingAction("copy_to_clipboard")
    }

    @objc private func pasteFromClipboard(_ sender: Any?) {
        performBindingAction("paste_from_clipboard")
    }

    @objc private func selectAllTerminalText(_ sender: Any?) {
        performBindingAction("select_all")
    }

    @objc private func resetTerminal(_ sender: Any?) {
        performBindingAction("reset")
    }

    override func otherMouseDown(with event: NSEvent) {
        // Relay middle-click (button number 2) only.
        guard let surface, event.buttonNumber == 2 else { return }
        _ = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, Self.ghosttyMods(event.modifierFlags))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let surface, event.buttonNumber == 2 else { return }
        _ = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, Self.ghosttyMods(event.modifierFlags))
    }

    override func mouseEntered(with event: NSEvent) {
        mouseInside = true
        // Restore the position that mouseExited set to (-1,-1). This matters
        // because mouse reporting and link detection behave differently
        // depending on whether the position is inside the viewport
        // (matching Ghostty.app).
        reportMousePos(event)
    }

    override func mouseExited(with event: NSEvent) {
        mouseInside = false
        guard let surface else { return }
        // Skip while dragging: mouseDragged keeps arriving even outside the view.
        if NSEvent.pressedMouseButtons != 0 { return }
        // Negative values indicate the cursor has left the viewport.
        ghostty_surface_mouse_pos(surface, -1, -1, Self.ghosttyMods(event.modifierFlags))
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
        // libghostty expects a top-left-origin coordinate system.
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, Self.ghosttyMods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var mods: Int32 = 0
        if event.hasPreciseScrollingDeltas { mods = 1 }
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, ghostty_input_scroll_mods_t(mods))
    }
}

// MARK: - NSTextInputClient (Japanese IME support)
//
// interpretKeyEvents([event]) inside keyDown invokes these methods. Regular input and
// IME-confirmed text go through insertText; in-progress composition (preedit) goes
// through setMarkedText/unmarkText.
// Implementation reference: the same methods in SurfaceView_AppKit.swift.
// Conforms to NSTextInputClient.
//
// Note: with `extension ...: @MainActor NSTextInputClient` (isolated conformance), the
// runtime's executor check crashes with EXC_BAD_ACCESS (observed) on the path where, the
// moment another window becomes key, AppKit calls
// `NSTextInputContext initWithClient:` → `validAttributesForMarkedText` on this view as
// the old first responder. AppKit contractually calls these methods on the main thread,
// so each method is made nonisolated + `MainActor.assumeIsolated`, avoiding the executor
// check at the witness call (where the crash occurs) altogether. The conformance's
// isolation declaration stays because doCommand(by:) (a @MainActor override from
// NSResponder) satisfies the requirement that way.
extension GhosttySurfaceView: @MainActor NSTextInputClient {
    nonisolated func hasMarkedText() -> Bool {
        MainActor.assumeIsolated {
            markedText.length > 0
        }
    }

    nonisolated func markedRange() -> NSRange {
        MainActor.assumeIsolated {
            guard markedText.length > 0 else { return NSRange() }
            return NSRange(location: 0, length: markedText.length)
        }
    }

    nonisolated func selectedRange() -> NSRange {
        MainActor.assumeIsolated {
            guard let surface else { return NSRange() }
            var text = ghostty_text_s()
            guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
            defer { ghostty_surface_free_text(surface, &text) }
            return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
        }
    }

    nonisolated func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        // `Any` (non-Sendable) can't be carried into a MainActor closure, so lower it to
        // String first. The preedit only uses plain text, so dropping attributes is fine.
        let text: String
        switch string {
        case let v as NSAttributedString: text = v.string
        case let v as String: text = v
        default: return
        }
        MainActor.assumeIsolated {
            markedText = NSMutableAttributedString(string: text)

            // Changes from outside keyDown (keyboard layout switch, etc.) are reflected
            // into the preedit immediately. Within keyDown, the keyDown side calls
            // syncPreedit once afterwards.
            if keyTextAccumulator == nil {
                syncPreedit(clearIfNeeded: true)
            }
        }
    }

    nonisolated func unmarkText() {
        MainActor.assumeIsolated {
            unmarkTextIsolated()
        }
    }

    private func unmarkTextIsolated() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit(clearIfNeeded: true)
    }

    nonisolated func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    nonisolated func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        // NSAttributedString is not Sendable, so receive a String from the closure and
        // build the NSAttributedString outside.
        let string: String? = MainActor.assumeIsolated {
            guard let surface, range.length > 0 else { return nil }
            var text = ghostty_text_s()
            guard ghostty_surface_read_selection(surface, &text) else { return nil }
            defer { ghostty_surface_free_text(surface, &text) }
            return String(cString: text.text)
        }
        return string.map { NSAttributedString(string: $0) }
    }

    nonisolated func characterIndex(for point: NSPoint) -> Int { 0 }

    nonisolated func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        MainActor.assumeIsolated {
            guard let surface else {
                return NSRect(x: frame.origin.x, y: frame.origin.y, width: 0, height: 0)
            }

            // ghostty tells us the cursor position (where the IME candidate window should go).
            var x: Double = 0
            var y: Double = 0
            var width: Double = 0
            var height: Double = 0
            ghostty_surface_ime_point(surface, &x, &y, &width, &height)

            // ghostty's coordinate system is top-left-origin; convert to AppKit's bottom-left origin (window coordinates).
            let viewRect = NSRect(x: x, y: frame.size.height - y, width: width, height: height)
            let winRect = convert(viewRect, to: nil)
            guard let window else { return winRect }
            return window.convertToScreen(winRect)
        }
    }

    nonisolated func insertText(_ string: Any, replacementRange: NSRange) {
        // `Any` (non-Sendable) can't be carried into a MainActor closure, so lower it to String first.
        let chars: String
        switch string {
        case let v as NSAttributedString: chars = v.string
        case let v as String: chars = v
        default: return
        }
        MainActor.assumeIsolated {
            guard let surface, NSApp.currentEvent != nil else { return }

            // By the time insertText is called, composition is confirmed, so end the preedit.
            unmarkTextIsolated()

            if var accumulated = keyTextAccumulator {
                // During keyDown handling: just accumulate, to pass to the later sendKey in one go.
                accumulated.append(chars)
                keyTextAccumulator = accumulated
                return
            }

            // Confirmations from outside keyDown (emoji picker, dictation, etc.) are sent directly.
            chars.withCString { cstr in
                ghostty_surface_text(surface, cstr, UInt(chars.utf8.count))
            }
        }
    }

    /// Override NSResponder.doCommand(by:) to prevent NSBeep on unsupported commands.
    override func doCommand(by selector: Selector) {
        // No special command handling for now (minimal implementation to avoid breaking existing behavior).
    }
}

// MARK: - NSDraggingDestination (file / URL / text drop)
//
// Dropping files, URLs, or text onto the terminal inserts the corresponding text at the
// cursor: file paths and URLs are shell-escaped (individually, space-joined for multiple
// files), plain text is inserted as-is. Text is sent straight to the surface via
// ghostty_surface_text (same path as ⌘V paste), bypassing insertText's IME accumulator and
// currentEvent guard, which don't apply to a drop.
// Implementation reference: the same extension in SurfaceView_AppKit.swift.
extension GhosttySurfaceView {
    static let dropTypes: Set<NSPasteboard.PasteboardType> = [.string, .fileURL, .URL]

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types else { return [] }
        // AppKit should only deliver types we registered for, but double-check.
        if Set(types).isDisjoint(with: Self.dropTypes) { return [] }
        // .copy shows the proper "+" drag icon.
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard

        let content: String?
        if let url = pb.string(forType: .URL) {
            // URLs first: escaped as-is.
            content = Self.shellEscape(url)
        } else if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            // File URLs next: each path escaped individually, joined by a space.
            content = urls.map { Self.shellEscape($0.path) }.joined(separator: " ")
        } else if let str = pb.string(forType: .string) {
            // Plain text is not escaped: it may be a command the user wants to run.
            content = str
        } else {
            content = nil
        }

        guard let content, let surface else { return false }
        content.withCString { cstr in
            ghostty_surface_text(surface, cstr, UInt(content.utf8.count))
        }
        return true
    }

    /// Escape shell-sensitive characters by prefixing each with a backslash. Suitable for
    /// inserting paths/URLs into a live terminal buffer (reference: Ghostty.Shell.escape).
    private static func shellEscape(_ str: String) -> String {
        let escapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"
        var result = str
        for char in escapeCharacters {
            result = result.replacingOccurrences(of: String(char), with: "\\\(char)")
        }
        return result
    }
}
