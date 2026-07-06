import AppKit
import GhosttyKit

/// Runtime holding libghostty's app-wide singleton (`ghostty_app_t`).
///
/// - Configuration is inherited from the default files such as `~/.config/ghostty/config`
///   (the cmux approach).
/// - The wakeup callback from libghostty may be invoked from any thread, so we hop back
///   to the main thread and run `ghostty_app_tick`.
/// - The `userdata` of surface callbacks is the unretained pointer to the
///   `GhosttySurfaceView` set in the surface config (same convention as Ghostty.app itself).
@MainActor
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?

    private static func view(from userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceView? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    /// Unlike other callbacks, action_cb does not pass userdata directly, so look up the
    /// corresponding `GhosttySurfaceView` from the surface referenced by `ghostty_target_s`
    /// via `ghostty_surface_userdata` (implementation reference: `surfaceView(from:)` in
    /// Ghostty.App.swift).
    private static func surfaceView(from target: ghostty_target_s) -> GhosttySurfaceView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface else { return nil }
        return view(from: ghostty_surface_userdata(surface))
    }

    /// Handles libghostty's `apprt.Action` (OSC-derived desktop notifications, bell, title,
    /// pwd, etc.). As the primary signal that takes precedence over text-pattern detection in
    /// state detection (SessionStateMonitor), this does nothing but relay to the callbacks of
    /// the corresponding `GhosttySurfaceView` (notification UI and state-transition decisions
    /// are the callback caller's responsibility).
    ///
    /// Actions not handled here (window/tab/split operations, etc. — viterm has its own
    /// window management, so it does not ride on libghostty's apprt actions) return false.
    private static func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        guard let view = surfaceView(from: target) else { return false }

        switch action.tag {
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let n = action.action.desktop_notification
            guard let titlePtr = n.title, let bodyPtr = n.body else { return false }
            view.onDesktopNotification?(String(cString: titlePtr), String(cString: bodyPtr))
            return true

        case GHOSTTY_ACTION_RING_BELL:
            view.onBell?()
            return true

        case GHOSTTY_ACTION_SET_TITLE:
            guard let titlePtr = action.action.set_title.title else { return false }
            view.onTitleChange?(String(cString: titlePtr))
            return true

        case GHOSTTY_ACTION_PWD:
            guard let pwdPtr = action.action.pwd.pwd else { return false }
            view.onPwdChange?(String(cString: pwdPtr))
            return true

        case GHOSTTY_ACTION_COMMAND_FINISHED:
            let payload = action.action.command_finished
            // exit_code is "-1 if not reported, otherwise 0-255" (comment in ghostty.h).
            let exitCode: Int32? = payload.exit_code >= 0 ? Int32(payload.exit_code) : nil
            // duration is in nanoseconds.
            let duration = TimeInterval(payload.duration) / 1_000_000_000
            view.onCommandFinished?(exitCode, duration)
            return true

        case GHOSTTY_ACTION_PROGRESS_REPORT:
            let payload = action.action.progress_report
            // progress is "-1 if not reported, otherwise 0-100" (comment in ghostty.h).
            let progress: Int? = payload.progress >= 0 ? Int(payload.progress) : nil
            view.onProgressReport?(payload.state, progress)
            return true

        default:
            return false
        }
    }

    private init() {
        var initError: UnsafeMutablePointer<CChar>? = nil
        _ = ghostty_init(0, &initError)

        let config = ghostty_config_new()
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = nil
        runtime.supports_selection_clipboard = false
        runtime.wakeup_cb = { _ in
            DispatchQueue.main.async {
                GhosttyRuntime.shared.tick()
            }
        }
        runtime.action_cb = { _, target, action in
            GhosttyRuntime.handleAction(target: target, action: action)
        }
        runtime.read_clipboard_cb = { userdata, _, state in
            guard let view = GhosttyRuntime.view(from: userdata),
                  let surface = view.surface else { return false }
            let string = NSPasteboard.general.string(forType: .string) ?? ""
            string.withCString { cstr in
                ghostty_surface_complete_clipboard_request(surface, cstr, state, false)
            }
            return true
        }
        runtime.confirm_read_clipboard_cb = { userdata, text, state, _ in
            // In the spike, always allow without showing a confirmation dialog.
            guard let view = GhosttyRuntime.view(from: userdata),
                  let surface = view.surface, let text else { return }
            ghostty_surface_complete_clipboard_request(surface, text, state, true)
        }
        runtime.write_clipboard_cb = { _, _, content, count, _ in
            // content is an array of (mime, data) pairs. Prefer text/plain when writing.
            guard let content, count > 0 else { return }
            let entries = UnsafeBufferPointer(start: content, count: Int(count))
            let chosen = entries.first { entry in
                entry.mime.map { String(cString: $0) == "text/plain" } ?? false
            } ?? entries[0]
            guard let data = chosen.data else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(cString: data), forType: .string)
        }
        // Called when the surface requests to close, e.g. the child process exited
        // (wait_after_command=false). The second argument is "is the process still alive
        // (does it need confirmation)", but viterm treats both cases as session end and
        // delegates cleanup to the host-side callback.
        runtime.close_surface_cb = { userdata, _ in
            guard let view = GhosttyRuntime.view(from: userdata) else { return }
            DispatchQueue.main.async {
                view.onSurfaceClose?()
            }
        }

        app = ghostty_app_new(&runtime, config)
        ghostty_config_free(config)
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    func setFocus(_ focused: Bool) {
        guard let app else { return }
        ghostty_app_set_focus(app, focused)
    }
}
