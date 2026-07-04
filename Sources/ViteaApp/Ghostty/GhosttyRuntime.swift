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

    /// action_cb は(他のコールバックと異なり)userdata を直接渡してくれないため、
    /// `ghostty_target_s` が指すサーフェスから `ghostty_surface_userdata` 経由で
    /// 対応する `GhosttySurfaceView` を逆引きする(実装リファレンス: Ghostty.App.swift の
    /// `surfaceView(from:)`)。
    private static func surfaceView(from target: ghostty_target_s) -> GhosttySurfaceView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface else { return nil }
        return view(from: ghostty_surface_userdata(surface))
    }

    /// libghostty の `apprt.Action`(OSC 由来のデスクトップ通知・ベル・タイトル・pwd 等)を処理する。
    /// 状態検出(SessionStateMonitor)のテキストパターン検出より優先される一次シグナルとして、
    /// 対応する `GhosttySurfaceView` のコールバックへ中継するだけに徹する
    /// (通知UI・状態遷移の判断はコールバックの呼び出し側の責務)。
    ///
    /// ここで扱わないアクション(ウィンドウ/タブ/スプリット操作等、vitea は独自の
    /// ウィンドウ管理を持つため libghostty 側の apprt アクションには乗らない)は false を返す。
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
            // exit_code は「-1 なら未報告、それ以外は 0-255」(ghostty.h のコメント)。
            let exitCode: Int32? = payload.exit_code >= 0 ? Int32(payload.exit_code) : nil
            // duration はナノ秒単位。
            let duration = TimeInterval(payload.duration) / 1_000_000_000
            view.onCommandFinished?(exitCode, duration)
            return true

        case GHOSTTY_ACTION_PROGRESS_REPORT:
            let payload = action.action.progress_report
            // progress は「-1 なら未報告、それ以外は 0-100」(ghostty.h のコメント)。
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
        // 子プロセス終了(wait_after_command=false)等でサーフェスがクローズを要求したとき。
        // 第2引数は「プロセスがまだ生きているか(確認が必要か)」だが、vitea では
        // どちらもセッション終了として扱い、後始末はホスト側コールバックに委ねる。
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
