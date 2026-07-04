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
        handleKey(event, action: GHOSTTY_ACTION_PRESS)
    }

    override func keyUp(with event: NSEvent) {
        handleKey(event, action: GHOSTTY_ACTION_RELEASE)
    }

    override func flagsChanged(with event: NSEvent) {
        // 修飾キー単体の press/release。スパイクでは省略(T6 で対応)。
        super.flagsChanged(with: event)
    }

    private func handleKey(_ event: NSEvent, action: ghostty_input_action_e) {
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : action
        key.mods = Self.ghosttyMods(event.modifierFlags)
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.keycode = UInt32(event.keyCode)
        key.composing = false
        key.unshifted_codepoint = event.charactersIgnoringModifiers?.unicodeScalars.first?.value ?? 0

        let text = (action == GHOSTTY_ACTION_PRESS) ? (event.characters ?? "") : ""
        if !text.isEmpty {
            text.withCString { cstr in
                key.text = cstr
                _ = ghostty_surface_key(surface, key)
            }
        } else {
            key.text = nil
            _ = ghostty_surface_key(surface, key)
        }
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
