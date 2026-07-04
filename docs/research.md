# 事前調査サマリ(2026-07-04)

3並列エージェントによる調査の要約。詳細な根拠URLは各節末尾。

## cmux (manaflow-ai/cmux)

- **Swift + AppKit のネイティブ macOS アプリ + libghostty**。Electron 不使用が明示的な差別化点。`~/.config/ghostty/config` を読んでテーマ・フォントを継承する
- UI: 左サイドバーに縦型タブ(ワークスペース単位)。branch / PR ステータス / cwd / listening ports / 最新通知を表示。入力待ちでペインに青いリング + タブ点灯 + macOS 通知
- 通知検出は OSC 9/99/777 等のターミナルシーケンス + `cmux notify` CLI
- Socket API / CLI でワークスペース・ペイン・キーストロークをプログラム制御可能
- **git worktree 一級サポートは Issue #156 で "not planned" クローズ**。「cmux is a primitive, not a solution」哲学のため今後も期待薄 → 本アプリの差別化点
- 参考: https://github.com/manaflow-ai/cmux / issues/156

## ccmanager (kbwo/ccmanager)

- TypeScript + React Ink + `@xterm/headless`(仮想端末バッファ)。PTY は Bun 組み込み Terminal API の自前ラッパー
- **worktree 管理**(`worktreeService.ts`): 作成(新規/既存/リモートブランチ、`{branch}` パターンでパス自動生成)、削除(`--force`)、マージ(merge `--no-ff` / rebase→`--ff-only` の2モード)、post-creation hook(env でパス・ブランチ渡し、非同期)、worktree ごとの差分行数・ahead/behind 表示、Claude セッションデータ(`~/.claude/projects`)コピー
- **状態検出**(`stateDetector/`): 100ms ポーリングで仮想端末のテキストをパターンマッチ。ツール別 detector(claude/codex/gemini/…)。claude はスピナー +「…ing」+ `esc to interrupt` + トークン統計行で busy、「Do you want」+選択肢で waiting_input、idle は 1.5s デバウンス。Claude Code の UI 変更で検出が壊れた前科あり(Issue #227)
- **リサイズ問題は実在かつ根深い**(Issue #73): RESIZE_SUPPRESS_MS=250ms、リストア遅延、ghost 行除去などの対症療法タイマーが積み重なっている。TUI in TUI 構成の構造的問題
- `claude` 起動時に `--teammate-mode in-process` を自動付与(Agent Teams との衝突回避)
- 設定: `~/.config/ccmanager/config.json` + プロジェクト別 `.ccmanager.json`
- 参考: https://github.com/kbwo/ccmanager / issues/73, /issues/227

## libghostty(2026年7月時点)

- 公式声明:「libghostty is not yet a stable API」= アルファ品質・破壊的変更あり。ただし **Ghostty.app 自体(macOS=Swift, Linux=GTK4)が libghostty C API のコンシューマ**であり、実戦検証済み
- コンポーネント: **libghostty-vt**(VTパーサ+端末状態管理、ゼロ依存、最も枯れている)と、レンダラ・入力等のフルライブラリ(発展途上)。C API が公式の外部公開インターフェース。per-commit ドキュメント: https://libghostty.tip.ghostty.org/
- **マルチサーフェス(タブ・分割)管理はホストアプリ責務**。公式デモ Ghostling は意図的に未実装。Ghostty.app macOS 版の Swift 実装が最良のリファレンス
- サードパーティ: GhosttyKit(SwiftUI ラッパー、実用段階)、awesome-libghostty に100+プロジェクト(大半は vt のみ利用)
- ビルドには消費言語を問わず **Zig 0.15.x ツールチェーンが必要**
- 結論: フルGUIターミナルは「コミット固定で追随する早期採用者」なら実装可能(cmux が実証)。安定APIを待つならリスクだが、cmux という同構成の先行事例がある
- 参考: https://mitchellh.com/writing/libghostty-is-coming / https://github.com/ghostty-org/ghostling / https://github.com/Lakr233 (GhosttyKit)

## 本プロジェクトへの示唆

1. **Swift + AppKit + libghostty は cmux で実証済みの構成** — 技術選定はこれで確定してよい
2. リサイズ崩れは ccmanager のアーキテクチャ(TUI in TUI)由来 — ネイティブサーフェスにするだけで根本解決
3. worktree 管理の仕様は ccmanager をほぼそのまま踏襲できる(マージ2モード、hook、パスパターン、セッションデータコピー)
4. 状態検出は「OSC シーケンス優先 + パターンマッチはフォールバック」の二段構えにし、detector をツール別プラグインに分離する(ccmanager Issue #227 の教訓)
5. マルチサーフェス管理は Ghostty.app macOS 版のソースを実装リファレンスにする
