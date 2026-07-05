# viterm

AI coding agent(Claude Code / Codex 等)を並列運用するためのネイティブ macOS ターミナルアプリケーション。

一言でいうと「cmux の UI 品質 × ccmanager の worktree 管理 × 1 worktree に複数セッション」。
ターミナルエミュレーションは libghostty(ネイティブレイヤ)に任せ、サイドバーやダイアログといったアプリの
chrome は AppKit で描画する構成により、TUI in TUI 構成([ccmanager](https://github.com/kbwo/ccmanager))で
起きがちなリサイズ時の描画崩れを構造的に避けている。git worktree ごとに複数のエージェントセッションを
同時に立ち上げられる点(1 worktree : N セッション)が、[cmux](https://github.com/manaflow-ai/cmux) や
ccmanager にはない差別化点。背景・要件の詳細は [docs/requirements.md](docs/requirements.md) を参照。

## 主要機能

- **git worktree 管理**: 新規ブランチ / 既存ローカルブランチ / リモートブランチからの worktree 作成、
  パステンプレートによる作成先パスの設定、Claude Code セッションデータ(`~/.claude/projects/…`)の
  コピー、post-creation hook、削除(dirty チェック付き確認)、マージ支援(merge `--no-ff` / rebase →
  `--ff-only` の2モード、完了後の worktree 後始末)
- **1 worktree : N セッション**: 任意コマンド(`claude` / `codex` / シェル等)を PTY 上で起動するエージェント
  プリセットを設定可能。既定プリセット(`defaultPreset`)は特に設定しなければ `shell`
- **サイドバー**: リポジトリ → worktree → セッション の3階層ツリー。worktree 行にブランチ・ahead/behind、
  セッション行に状態インジケータ(`●` busy / `◐` waiting / `○` idle)と未読バッジ。セッションが無い
  worktree には「＋ セッションを追加」行が常設され、クリックで既定プリセットのセッションを起動する
- **右クリックメニュー**: セッション行(リネーム / セッションを終了)、worktree 行(セッションを追加 /
  Finder で表示 / デフォルトブランチにマージ… / worktree を削除…)
- **セッション構成の自動保存・復元**: 起動中のセッション構成(worktree とプリセットの組)・選択中セッションを
  `~/Library/Application Support/viterm/sessions.json` に自動保存し、次回起動時に自動復元する。復元時は
  PTY を新規に起動し直すため、スクロールバックや実行中プロセスの状態そのものは引き継がれない
- **設定シート(⌘,)**: `worktreePathTemplate` / `defaultPreset` / `copySessionDataByDefault` /
  `discoveryRoots` を GUI から編集し、グローバル設定(`~/.config/viterm/config.json`)へ保存。
  それ以外のキー(`presets` / `statusHooks` 等)は保全されたまま
- **ステータスバー**: リポジトリ横断の状態集計(`● N busy` `◐ N waiting` `○ N idle`)
- キーボード中心の操作(下記キーマップ参照)

## セットアップ

前提: macOS(arm64)、Metal Toolchain コンポーネントを含む完全な Xcode(Command Line Tools のみでは
Metal シェーダのコンパイルができず `scripts/build-ghostty.sh` の最終ステップが失敗する。
libghostty ビルドで踏んだ既知の問題と回避策は [docs/ghostty-integration.md](docs/ghostty-integration.md) 参照)。

```sh
scripts/setup-zig.sh     # ghostty が要求する pinned Zig(0.15.2)を vendor/zig/ に展開
scripts/fetch-ghostty.sh # vendor/ghostty を固定コミット(scripts/ghostty-commit)で取得し、vitea用パッチを適用
scripts/build-ghostty.sh # zig build で GhosttyKit.xcframework を生成(vendor/ghostty/macos/ 配下)
swift build              # 全ターゲット(ViteaCore / GitKit / ViteaServices / ViteaApp)をビルド
```

起動方法は2つ:

```sh
swift run ViteaApp        # 開発時: そのまま実行
scripts/make-app.sh       # .build/vitea.app バンドルを組み立てる(既定 release。debug も指定可)
open .build/vitea.app     # バンドルとして起動する場合
```

`vendor/` 以下はすべて git 管理外(スクリプトで生成)なので、clone 直後は必ず上記4ステップを
この順番で実行する必要がある。

## キーマップ

| ショートカット | 動作 |
|---|---|
| `⌘N` | 新規 worktree 作成シートを開く |
| `⌘T` | 現在選択中の worktree(無ければ先頭の worktree)に新規セッションを起動 |
| `⌘1`..`⌘9` | サイドバーのセッションへ直接切替 |
| `⌘⇧U` | 最新の入力待ち(waiting_input)セッションへジャンプ(リポジトリ横断) |
| `⌘B` | サイドバー表示切替 |
| `⌘K` | コマンドパレット(worktree 作成・マージ・削除・セッション起動・リポジトリ追加をファジー検索で実行) |
| `⌘,` | 設定シート(`worktreePathTemplate` / `defaultPreset` / `copySessionDataByDefault` / `discoveryRoots` を編集) |

worktree のマージ(デフォルトブランチへ)・削除は、`Worktree` メニューまたはサイドバーの worktree 行の
右クリックメニューから実行可能(ショートカット未割り当て)。

## 設定

グローバル設定(`~/.config/viterm/config.json`)とプロジェクト別設定(`<リポジトリルート>/.vitea.json`)を
マージして使う。キー一覧・マージ規則・パステンプレートの展開規則などの詳細は
[docs/configuration.md](docs/configuration.md) を参照。主要なキー(`worktreePathTemplate` /
`defaultPreset` / `copySessionDataByDefault` / `discoveryRoots`)は `⌘,` の設定シートからも編集できる
(それ以外のキーは `config.json` を直接編集する)。最小サンプル:

```json
{
  "worktreePathTemplate": "~/worktrees/{project}/{branch}",
  "defaultPreset": "claude",
  "repositories": [
    { "name": "vitea", "path": "/Users/me/dev/vitea" }
  ]
}
```

両方のファイルが存在しなくても組み込みの既定値(`claude` / `codex` / `shell` プリセットなど)で動作する。

## 開発

```sh
swift build          # 全ターゲット
swift test           # ユニットテスト(ViteaCore / GitKit / ViteaServices)
swift run ViteaApp    # アプリ起動
```

### アーキテクチャ

| ターゲット | 役割 |
|---|---|
| `Sources/ViteaCore` | ドメインモデル(Repository / Worktree / AgentSession)・設定ロード(`ViteaConfig`)・worktree パステンプレート・worktree作成フォームの状態。UI 非依存 |
| `Sources/GitKit` | `git` CLI ラッパー(worktree の作成・削除・一覧、ブランチ一覧、ahead/behind、diffstat、merge/rebase)。UI 非依存 |
| `Sources/ViteaServices` | `ViteaCore` と `GitKit` を束ねるオーケストレーション層。`AppModel` が設定リロード・リポジトリ自動検出・worktree 状態スキャン・セッション一覧を統合してサイドバー用の状態を組み立てる。UI 非依存で、全依存はプロトコル越しに注入されるためフェイクでユニットテストできる |
| `Sources/ViteaApp` | AppKit アプリ本体。サイドバー・ターミナルホスト(libghostty サーフェス)・ステータスバー・worktree作成ダイアログ・コマンドパレット等 |
| `vendor/` | ghostty ソースと `zig build` の生成物。git 管理外(上記セットアップ手順で取得・生成) |

### ドキュメント一覧(`docs/`)

- [requirements.md](docs/requirements.md) — 要件定義(背景・コンセプト・機能要件・技術スタック)
- [tasks.md](docs/tasks.md) — マイルストーン・タスク分解
- [configuration.md](docs/configuration.md) — 設定ファイルのキー・マージ規則・パステンプレート・hook 等のリファレンス
- [ghostty-integration.md](docs/ghostty-integration.md) — libghostty 統合(T2/T3)で得た知見。特にこの開発環境固有のビルド阻害要因と回避策
- [research.md](docs/research.md) — cmux / ccmanager の調査メモ
- [ui-mock.html](docs/ui-mock.html) — UI モック(ブラウザで直接開いて確認する)
