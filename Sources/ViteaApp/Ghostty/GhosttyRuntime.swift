import AppKit
import GhosttyKit

/// libghostty のアプリ全体シングルトン(`ghostty_app_t`)を保持するランタイム。
///
/// - 設定は `~/.config/ghostty/config` 等のデフォルトファイルから継承する(cmux 方式)。
/// - libghostty からの wakeup コールバックは任意スレッドから呼ばれ得るため、
///   main スレッドに戻して `ghostty_app_tick` を回す。
/// - サーフェス系コールバックの `userdata` は surface config に設定した
///   `GhosttySurfaceView` の unretained ポインタ(Ghostty.app 本体と同じ流儀)。
@MainActor
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?

    private static func view(from userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceView? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
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
        runtime.action_cb = { _, _, _ in
            // スパイク段階ではアクション(タイトル変更、ベル等)は処理しない。
            false
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
            // スパイクでは確認ダイアログを出さず常に許可する。
            guard let view = GhosttyRuntime.view(from: userdata),
                  let surface = view.surface, let text else { return }
            ghostty_surface_complete_clipboard_request(surface, text, state, true)
        }
        runtime.write_clipboard_cb = { _, _, content, count, _ in
            // content は (mime, data) ペアの配列。text/plain を優先して書き込む。
            guard let content, count > 0 else { return }
            let entries = UnsafeBufferPointer(start: content, count: Int(count))
            let chosen = entries.first { entry in
                entry.mime.map { String(cString: $0) == "text/plain" } ?? false
            } ?? entries[0]
            guard let data = chosen.data else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(cString: data), forType: .string)
        }
        runtime.close_surface_cb = { _, _ in }

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
