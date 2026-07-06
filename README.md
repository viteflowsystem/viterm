<img src="docs/brand/icon.svg" width="96" alt="viterm">

# viterm

AI coding agent(Claude Code / Codex 等)を並列運用するためのネイティブ macOS ターミナル。

git worktree ごとにエージェントセッションを何本でも立ち上げ、全セッションの状態
(busy / 入力待ち / idle)をサイドバーで一望する。ターミナル描画は
[Ghostty](https://ghostty.org) と同じエンジン(libghostty)がネイティブに担当するため、
ウィンドウをリサイズしても TUI が崩れない。Electron 不使用。

## インストール

```sh
brew tap viteflowsystem/tap
brew install --cask viterm
```

DMG を直接ダウンロードする場合は
[homebrew-tap の Releases](https://github.com/viteflowsystem/homebrew-tap/releases) から。
配布物は Developer ID 署名 + Apple 公証済み。要件: macOS 15+ / Apple Silicon。

## なにができるか

- **1 worktree : N セッション** — 同じブランチで Claude に実装させながら、隣で Codex に
  テストを書かせ、素のシェルも並べる。セッションは何本でも
- **git worktree 管理** — 新規ブランチ / 既存ブランチ / リモートブランチから worktree を作成。
  作成先はパステンプレート(例 `~/worktrees/{project}/{branch}`)で自由に設定。作成と同時に
  エージェントを起動し、終わったら merge(`--no-ff`)か rebase → `--ff-only` で取り込んで、
  サイドバーからそのまま削除
- **状態検出と通知** — 各セッションの busy / 入力待ち / idle をサイドバーのドットで常時表示。
  エージェントが入力を求めると macOS 通知が飛び、`⌘⇧U` で最新の入力待ちへジャンプ。
  OSC 通知シーケンス(9/777)を一次シグナルに、画面テキスト検出をフォールバックにした二段構え
- **ペイン分割** — `⌘D`(右)/ `⌘⇧D`(下)で同一画面に複数セッションを並べる。
  ペインを閉じてもセッションはサイドバーで生き続ける
- **マルチリポジトリ** — 複数リポジトリを1つのサイドバーで管理。`discoveryRoots` を設定すれば
  指定ディレクトリ配下の git リポジトリを自動検出
- **セッション復元** — セッション構成(worktree × プリセット)を自動保存し、次回起動時に復元
  (PTY は新規起動。スクロールバックは引き継がれない)
- **Claude Code セッションデータの引き継ぎ** — worktree 作成時に `~/.claude/projects/…` を
  コピーして、新しい worktree でも会話履歴から再開できる
- **ターミナル設定の継承** — フォント・テーマは `~/.config/ghostty/config` をそのまま読む

## キーマップ

| キー | 動作 |
|---|---|
| `⌘K` | コマンドパレット(worktree 作成・マージ・削除、セッション起動、リポジトリ追加) |
| `⌘N` | 新規 worktree |
| `⌘T` | 選択中の worktree にセッションを追加 |
| `⌘1`–`⌘9` | セッション直接切替 |
| `⌘⇧U` | 最新の入力待ちセッションへジャンプ(リポジトリ横断) |
| `⌘D` / `⌘⇧D` | ペインを右 / 下に分割 |
| `⌘⇧W` | ペインを閉じる(セッションは維持) |
| `⌘]` | 次のペインへフォーカス |
| `⌘B` | サイドバー表示切替 |
| `⌘,` | 設定 |

## 設定

グローバル設定 `~/.config/viterm/config.json` とプロジェクト別 `.viterm.json` をマージして使う。
主要なキーは `⌘,` の設定ウィンドウ(一般 / Worktree / リポジトリ / 通知フック)からも編集できる。

```json
{
  "worktreePathTemplate": "~/worktrees/{project}/{branch}",
  "defaultPreset": "claude",
  "repositories": [
    { "name": "myapp", "path": "/Users/me/dev/myapp" }
  ],
  "discoveryRoots": ["~/dev"]
}
```

キー一覧・マージ規則・プリセット定義・状態変化フック(`statusHooks`)などの詳細は
[docs/configuration.md](docs/configuration.md) を参照。設定ファイルが無くても組み込みの
既定値(`claude` / `codex` / `shell` プリセット)で動く。

## ソースからビルド

前提: macOS(arm64)/ Xcode(Metal Toolchain 込み。Command Line Tools のみでは不可)。

```sh
scripts/setup-zig.sh     # ghostty が要求する pinned Zig を vendor/zig/ に展開
scripts/fetch-ghostty.sh # ghostty を固定コミットで取得し、viterm 用パッチを適用
scripts/build-ghostty.sh # GhosttyKit.xcframework を生成
swift build              # 全ターゲットをビルド
swift test               # ユニットテスト
scripts/make-app.sh      # .build/viterm.app を組み立て → open .build/viterm.app
```

libghostty ビルドの既知の問題と回避策は
[docs/ghostty-integration.md](docs/ghostty-integration.md) にまとめてある。

### アーキテクチャ

| ターゲット | 役割 |
|---|---|
| `VitermCore` | ドメインモデル・設定ロード・パステンプレート・状態検出・各種 ViewModel。UI 非依存 |
| `GitKit` | `git` CLI ラッパー(worktree / branch / merge)。UI 非依存 |
| `VitermServices` | Core と GitKit を束ねるオーケストレーション層(`AppModel`)。全依存をプロトコル注入でテスト可能 |
| `VitermApp` | AppKit アプリ本体(サイドバー・libghostty サーフェス・ダイアログ・パレット) |
| `vendor/` | ghostty ソースとビルド生成物(git 管理外、スクリプトで取得) |

リリース手順(署名・公証・DMG)は [docs/RELEASE.md](docs/RELEASE.md)。

## ライセンス

MIT License([LICENSE](LICENSE))。viterm は無料の OSS です。
バグ報告・機能要望は [Issues](https://github.com/viteflowsystem/viterm/issues) へ。
