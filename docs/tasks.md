# vitea — タスクブレイクダウン

依存関係と並列レーンを明示したマイルストーン構成。M0 がクリティカルパス(libghostty統合リスクの検証)。
M1 の T4/T5 は M0 と並列で着手できる。

```
M0(直列・クリティカルパス)          M1(M0と並列可)
T1 scaffold ─→ T2 libghostty build ─→ T3 spike    T4 domain/config   T5 GitService
                                        │              │                │
                    ┌───────────────────┤              │                │
                    ▼                   ▼              ▼                ▼
                 T6 SessionManager   T8 term host   T7 sidebar      T10 wt作成 / T11 merge・削除
                    │                                  │
                    ▼                                  ▼
                 T13 状態検出 ─→ T14 通知           T9 statusbar / T12 palette
                                                    T15 仕上げ / T16 分割(P2)
```

## M0: ビルド基盤(リスク検証。ここが通れば勝ち筋確定)

### T1. プロジェクトscaffold
- ディレクトリ構成: `Sources/`(Swift)、`vendor/ghostty`(固定コミット)、`scripts/`、`docs/`
- `.gitignore`(Xcode / Zig cache / build 成果物)、`CLAUDE.md`(ビルド手順・規約)
- アプリターゲット: XcodeGen(`project.yml`)または SwiftPM + .app バンドル化スクリプト。arm64 macOS、AppKit ベース

### T2. libghostty ビルドパイプライン
- Ghostty の pinned バージョンの Zig ツールチェーン導入(`scripts/setup-zig.sh`、ziglang.org の tarball を toolchain ディレクトリに展開。brew の zig はバージョン不一致リスクがあるので使わない)
- ghostty を**固定コミット**で取得(submodule or fetch スクリプト)。`zig build` で GhosttyKit(xcframework / 静的ライブラリ + ヘッダ)を生成する `scripts/build-ghostty.sh`
- リファレンス: Ghostty.app macOS 版のビルド構成(同じものを生成している)、Ghostling(C API の最小コンシューマ)

### T3. スパイク: サーフェス1枚で zsh が動く
- AppKit ウィンドウ + libghostty サーフェス1枚 + PTY で zsh を起動
- 検証項目: キー入力 / 24bit色 / **ウィンドウリサイズで TUI(vim, claude 等)が崩れない** / スクロールバック / ⌘V ペースト
- ここで得た知見を `docs/ghostty-integration.md` に記録(API の癖、スレッドモデル、コールバック構成)

## M1: コアドメイン(UI 非依存・並列レーン)

### T4. ドメインモデル + 設定(T1 のみ依存)
- `Repo` / `Worktree` / `Session` モデル、`AppState`(observable)
- 設定ロード: `~/.config/vitea/config.json` + プロジェクト別 `.vitea.json` マージ
- worktree パステンプレート展開: `{project}` / `{branch}`(`/`→`-`) / `{branch_raw}`、`~`・相対パス対応。ユニットテスト必須
- 登録リポジトリ一覧の永続化

### T5. GitService(T1 のみ依存)
- git CLI ラッパー(Process 実行、タイムアウト、エラー型)
- worktree list / add(新規・既存・リモートブランチ)/ remove(dirty チェック)
- ブランチ一覧、ahead/behind(`rev-list --left-right --count`)、diffstat(`diff --shortstat`)、dirty 判定
- merge(`--no-ff` 既定・引数設定可)/ rebase→`--ff-only` の2モード
- fixture リポジトリを作るユニットテスト必須

### T6. SessionManager(T3 依存)
- 1 worktree : N セッション。セッション = PTY + libghostty サーフェス + メタデータ(名前、プリセット、状態)
- 非表示セッションのバックグラウンド生存、スクロールバック保持
- エージェントプリセット(claude / codex / zsh、コマンド・引数・env)。`claude` には `--teammate-mode in-process` を自動付与
- セッションの起動 / リネーム / 再起動 / 終了

## M2: UI シェル

### T7. サイドバー(T4 依存)
- リポジトリ → worktree → セッション の3階層ツリー(NSOutlineView)
- worktree 行: ブランチ / ↑↓ / +− / dirty。セッション行: 状態ドット / 未読バッジ / ⌘番号
- リポジトリ折りたたみ時の waiting バッジ集約。⌘1..9 切替、⌘B トグル

### T8. ターミナルホストビュー(T3/T6 依存)
- 選択セッションのサーフェス表示切替(サーフェスは破棄せず付け替え)
- リサイズハンドリング、フォーカス管理

### T9. ステータスバー(T6/T7 依存)
- リポジトリ横断の状態集計(busy/waiting/idle)、現在セッション表示

## M3: worktree 操作 UI

### T10. worktree 新規作成ダイアログ(T5/T7 依存)
- ブランチ名入力 → テンプレート展開プレビュー、ベースブランチ選択(ローカル/リモート)
- オプション: Claude セッションデータコピー(`~/.claude/projects`、失敗は非致命)/ 作成後セッション起動 / post-creation hook(env: パス・ブランチ・git root、非同期)

### T11. マージ・削除フロー(T5 依存)
- merge / rebase 選択、完了後の worktree 後始末提案。削除時の dirty 確認

### T12. コマンドパレット(⌘K)(T7 依存)
- 全操作(worktree 作成・切替・マージ・削除、セッション起動、リポジトリ追加)+ ファジー検索

## M4: 状態検出・通知

### T13. 状態検出エンジン(T6 依存)
- 一次: OSC 9/99/777 等の通知シーケンス。二次: 画面テキストのパターンマッチ(ツール別 detector プラグイン、claude/codex/gemini)
- busy / waiting_input / idle、idle は 1.5s デバウンス。リサイズ中の誤検出抑制(ccmanager #73 の教訓)

### T14. 通知系(T13 依存)
- macOS 通知、サイドバーバッジ、⌘⇧U(最新 waiting へジャンプ、リポジトリ横断)、状態変化 hook(任意コマンド)

## M5: 仕上げ

### T15. 設定・polish
- Ghostty config(テーマ・フォント)継承、リポジトリ追加 UI(ディレクトリ選択)、ルート配下自動検出(優先度中)
- README / 設定ドキュメント

### T16. ペイン分割(フェーズ2・任意)
- ⌘D / ⌘⇧D、同一画面に複数サーフェス

## 環境メモ(2026-07-04 時点)
- Swift 6.3.3 / Xcode 26.6 ✅、Zig 未インストール(T2 で pinned バージョンを導入)
