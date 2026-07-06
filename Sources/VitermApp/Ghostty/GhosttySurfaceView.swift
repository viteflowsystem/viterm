import AppKit
import GhosttyKit

/// NSView hosting a single libghostty surface.
///
/// Rendering (Metal) is done by libghostty directly against the nsview, so the
/// host's responsibility is to relay size, focus, and input events to the surface.
/// Implementation reference: SurfaceView_AppKit.swift in the Ghostty.app macOS build.
final class GhosttySurfaceView: NSView {
    // Marked unsafe so it can be freed from deinit (nonisolated). Only written in init/deinit.
    nonisolated(unsafe) private(set) var surface: ghostty_surface_t?

    /// Text being composed (unconfirmed) by the IME. Updated via NSTextInputClient's setMarkedText/unmarkText.
    private var markedText = NSMutableAttributedString()

    /// Non-nil only while keyDown is being processed. Accumulates the results of insertText
    /// calls made via interpretKeyEvents, then passes them to sendKey in one batch
    /// (implementation reference: the same-named mechanism in SurfaceView_AppKit.swift).
    private var keyTextAccumulator: [String]?

    // MARK: - OSC notifications (called from GhosttyRuntime.action_cb)
    //
    // When libghostty interprets an OSC sequence in terminal output (OSC 9/777 for desktop
    // notifications, OSC 7 for pwd, etc.), action_cb fires and GhosttyRuntime invokes the
    // corresponding callback on this surface. Intended for use by SessionStateMonitor etc.
    // as the primary signal for state detection (see docs/ghostty-integration.md).

    /// Received a desktop notification via OSC 9 / OSC 777 (`GHOSTTY_ACTION_DESKTOP_NOTIFICATION`).
    var onDesktopNotification: ((_ title: String, _ body: String) -> Void)?

    /// Received a bell (`GHOSTTY_ACTION_RING_BELL`).
    var onBell: (() -> Void)?

    /// Received a title change via OSC 0/1/2 etc. (`GHOSTTY_ACTION_SET_TITLE`).
    var onTitleChange: ((_ title: String) -> Void)?

    /// Received a current-directory change via OSC 7 (`GHOSTTY_ACTION_PWD`).
    var onPwdChange: ((_ pwd: String) -> Void)?

    /// libghostty requested that the surface be closed, e.g. because the child process exited
    /// (via `close_surface_cb`). Session cleanup (removing it from the list, closing the pane)
    /// is the caller's responsibility.
    var onSurfaceClose: (() -> Void)?

    /// Received a command-finished event (`GHOSTTY_ACTION_COMMAND_FINISHED`). Comes from OSC 133
    /// semantic prompts (`end_input_start_output` → `end_command`) and only fires when shell
    /// integration is enabled (see docs/ghostty-integration.md; viterm currently does not ship
    /// shell integration resources, so this never fires). `exitCode` is 0-255 if an exit code
    /// was reported, nil otherwise. `duration` is the command's execution time in seconds.
    var onCommandFinished: ((_ exitCode: Int32?, _ duration: TimeInterval) -> Void)?

    /// Received a progress report (`GHOSTTY_ACTION_PROGRESS_REPORT`, from OSC 9;4). Independent of
    /// shell integration: any running program that emits OSC 9;4 directly can trigger this (see
    /// docs/ghostty-integration.md). `progress` is the reported percentage (0-100), or nil if not reported.
    var onProgressReport: ((_ state: ghostty_action_progress_report_state_e, _ progress: Int?) -> Void)?

    /// - Parameters:
    ///   - command: Command to launch. If nil, the user's default shell.
    ///   - workingDirectory: Working directory. If nil, the home directory.
    init(command: String? = nil, workingDirectory: String? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        // SessionStateMonitor etc. depend on resize notifications (frameDidChangeNotification).
        postsFrameChangedNotifications = true

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

        // Record whether we are in preedit (composing) before calling interpretKeyEvents.
        // Used for the composing decision when the IME aborts the preedit on this input
        // (e.g. Backspace while composing).
        let markedTextBefore = markedText.length > 0

        // Let NSTextInputClient (setMarkedText/insertText) process this key event via
        // interpretKeyEvents. Regular input and IME-committed text accumulate in insertText.
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        interpretKeyEvents([event])

        syncPreedit(clearIfNeeded: markedTextBefore)

        let action: ghostty_input_action_e = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        if let accumulated = keyTextAccumulator, !accumulated.isEmpty {
            // Text committed via insertText (regular input or IME commit).
            for text in accumulated {
                sendKey(action, event: event, text: text, composing: false)
            }
        } else {
            // Regular keys for which insertText was not called (arrows, Enter, Ctrl+C, etc.).
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

        // While composing, do not send press/release for modifier keys alone
        // (matches upstream SurfaceView_AppKit.swift).
        guard markedText.length == 0 else { return }

        let mods = Self.ghosttyMods(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            // Determine whether the left or right modifier key was pressed. If the same
            // modifier on the opposite side is still held down, treat this as a release.
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

        // Do not send single control characters (Ctrl+C etc.) or function-key PUA codepoints
        // here. ghostty builds the control bytes / escape sequences from keycode/mods itself.
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

    /// Derive the text to send to ghostty from a key event. Excludes control characters and
    /// function-key PUA codepoints (implementation reference: ghosttyCharacters in NSEvent+Extension.swift).
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
        // Cmd+V paste: send text from NSPasteboard directly to the surface.
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

    /// Reflect the contents of markedText into ghostty's preedit display. If markedText became
    /// empty (commit or composition cancel), clear the preedit when clearIfNeeded is set.
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
        // Relay middle click (button number 2) only.
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
// IME-committed text go through insertText; in-progress composition (preedit) goes through
// setMarkedText/unmarkText.
// Implementation reference: the same-named methods in SurfaceView_AppKit.swift.
// Conforms to NSTextInputClient.
//
// Caution: with `extension ...: @MainActor NSTextInputClient` (isolated conformance), the
// runtime's executor check crashes with EXC_BAD_ACCESS (observed in practice) via the path
// where, at the moment another window becomes key, AppKit calls
// `NSTextInputContext initWithClient:` → `validAttributesForMarkedText` on this view as the
// old first responder. AppKit contractually calls these methods on the main thread, so each
// method is nonisolated + `MainActor.assumeIsolated` to avoid the executor check at the
// witness call site (where the crash occurs) entirely. The conformance's isolation
// declaration is kept because doCommand(by:) (an @MainActor override of NSResponder)
// satisfies the requirement that way.
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
        // `Any` (non-Sendable) cannot be brought into a MainActor closure, so convert to String
        // first. Preedit only uses plain text, so dropping the attributes is fine.
        let text: String
        switch string {
        case let v as NSAttributedString: text = v.string
        case let v as String: text = v
        default: return
        }
        MainActor.assumeIsolated {
            markedText = NSMutableAttributedString(string: text)

            // Changes from outside keyDown (keyboard layout switch, etc.) are reflected into
            // the preedit immediately. Inside keyDown, keyDown itself calls syncPreedit once
            // after the call returns.
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
        // NSAttributedString is not Sendable, so return a String from the closure and
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

            // ghostty tells us the cursor position (where the IME candidate window should appear).
            var x: Double = 0
            var y: Double = 0
            var width: Double = 0
            var height: Double = 0
            ghostty_surface_ime_point(surface, &x, &y, &width, &height)

            // ghostty's coordinate system is top-left origin, so convert to AppKit's
            // bottom-left origin (window coordinates).
            let viewRect = NSRect(x: x, y: frame.size.height - y, width: width, height: height)
            let winRect = convert(viewRect, to: nil)
            guard let window else { return winRect }
            return window.convertToScreen(winRect)
        }
    }

    nonisolated func insertText(_ string: Any, replacementRange: NSRange) {
        // `Any` (non-Sendable) cannot be brought into a MainActor closure, so convert to String first.
        let chars: String
        switch string {
        case let v as NSAttributedString: chars = v.string
        case let v as String: chars = v
        default: return
        }
        MainActor.assumeIsolated {
            guard let surface, NSApp.currentEvent != nil else { return }

            // Once insertText is called, composition is committed, so end the preedit.
            unmarkTextIsolated()

            if var accumulated = keyTextAccumulator {
                // During keyDown processing: just accumulate, to be passed to sendKey later in one batch.
                accumulated.append(chars)
                keyTextAccumulator = accumulated
                return
            }

            // Commits from outside keyDown (emoji picker, dictation, etc.) are sent directly.
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
