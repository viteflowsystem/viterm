import Foundation

/// Claude Code 向けの detector。
/// 判定シグナルは ccmanager(kbwo/ccmanager)の `src/services/stateDetector/claude.ts`
/// (2026-07 時点の main ブランチ)を出発点に移植している。ccmanager は同種の判定が
/// Claude Code の UI 変更で一度全壊した前科(Issue #227)があり、その修正後の実装が
/// 現時点で最も実戦検証されたパターン集合になっている。
///
/// - waitingInput(busy より優先して判定):
///   - `Do you want` / `Would you like` の後に改行を挟んで選択肢(`yes` / `❯`)が続く確認プロンプト。
///     文言だけで即断すると通常の応答文中の言い回しを誤検知しうるため、選択肢の存在まで要求する。
///   - `esc to cancel`
/// - busy:
///   - `esc to interrupt` / `ctrl+c to interrupt` / `ctrl-c to interrupt`
///   - スピナー文字+単語(`…ing` を含む)+三点リーダー(`…`)で終わる行
///     (例: `✽ Tempering…`、`✳ Simplifying recompute_tangents… (2m 18s · ↓ 4.8k tokens)`)。
///     スピナー文字で始まっていても `…ing` で終わらない行(例: `✽ Some random text`)は対象外。
///   - 括弧内に数字と `tokens` を含む統計行(例: `(2m 14s · ↓ 4.2k tokens)`、`(50s · ↓ 794 tokens)`)
/// - `⌕ Search…`(検索プロンプト)は他のどのシグナルよりも優先して `.none`(idle デバウンス側)を返す。
/// - `ctrl+r to toggle`(トランスクリプト表示切替のヒント)は `.none` を返す。ccmanager 本家は
///   このケースで直前状態を維持するが、`StateDetector` はステートレスな設計のためここでは
///   `.none` で近似する。`SessionStateMachine` の idle デバウンス(既定1.5秒)により、
///   次の tick で busy/waitingInput のシグナルが再検出されれば実害は無い。
///
/// ccmanager 側にある「プロンプトボックス(`─` 罫線)より上のみを busy 判定対象にする」処理は、
/// xterm バッファに前ターンの再描画断片が残留する問題への対処であり、libghostty の
/// `ghostty_surface_read_text`(現在のビューポートをそのまま返す。詳細は
/// `docs/ghostty-integration.md` 参照)には同種の問題が無いため移植していない。
public struct ClaudeStateDetector: StateDetector {
    public let toolName = "claude"

    public init() {}

    public func detect(screenLines: [String]) -> DetectionSignal {
        let content = screenLines.joined(separator: "\n")

        // 検索プロンプトは他のどのシグナルよりも優先して idle 側(none)を返す。
        if content.contains("⌕ Search…") {
            return .none
        }

        let lowerContent = content.lowercased()

        if lowerContent.contains("ctrl+r to toggle") {
            return .none
        }

        if Self.matchesWaitingInput(content, lowerContent: lowerContent) {
            return .waitingInput
        }
        if Self.matchesBusy(content, lowerContent: lowerContent) {
            return .busy
        }
        return .none
    }

    static func matchesWaitingInput(_ content: String, lowerContent: String) -> Bool {
        if lowerContent.contains("esc to cancel") {
            return true
        }
        return TextSignals.matchesRegex(
            lowerContent,
            pattern: #"(?:do you want|would you like)[\s\S]+?\n+[\s\S]*?(?:yes|❯)"#
        )
    }

    static func matchesBusy(_ content: String, lowerContent: String) -> Bool {
        if TextSignals.containsAny(lowerContent, of: ["esc to interrupt", "ctrl+c to interrupt", "ctrl-c to interrupt"]) {
            return true
        }
        if TextSignals.matchesRegex(content, pattern: spinnerActivityPattern) {
            return true
        }
        return TextSignals.matchesRegex(lowerContent, pattern: #"\([^)]*\d[^)]*tokens\s*\)"#)
    }

    /// 行頭のスピナー文字 + 半角スペース + 「…ing」で終わる単語 + 三点リーダー(`…`)。
    private static let spinnerActivityPattern =
        "(?m)^[" + String(TextSignals.spinnerCharacters) + "] \\S+ing.*…"
}
