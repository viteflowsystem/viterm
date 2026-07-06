<img src="docs/brand/icon.svg" width="96" alt="viterm">

# viterm

AI coding agent を並列運用するためのネイティブ macOS ターミナル。

git worktree ごとにエージェントセッション(Claude Code / Codex / シェル)を何本でも
立ち上げ、全セッションの状態(busy / 入力待ち / idle)をサイドバーで一望する。
ターミナル描画は [libghostty](https://ghostty.org) がネイティブに担当するため、
リサイズしても崩れない。Electron 不使用。

[English README](README.md)

## インストール

```sh
brew tap viteflowsystem/tap
brew install --cask viterm
```

DMG 直接ダウンロードは [Releases](https://github.com/viteflowsystem/homebrew-tap/releases)
から(Developer ID 署名 + 公証済み)。要件: macOS 15+ / Apple Silicon。

## ハイライト

- **1 worktree : N セッション** — 同じブランチで複数エージェントとシェルを並走
- **worktree ライフサイクル** — 任意ブランチから作成、作成先はパステンプレート
  (`~/worktrees/{project}/{branch}`)で設定可、作成と同時にエージェント起動、
  merge/rebase で取り込んでサイドバーから削除
- **状態検出と通知** — セッションごとの busy/待ち/idle ドット。入力待ちで macOS 通知
  (OSC 9/777 一次 + 画面検出フォールバック)、`⌘⇧U` で最新の入力待ちへ
- **ペイン分割** — `⌘D` / `⌘⇧D`。ペインを閉じてもセッションは維持
- **マルチリポジトリ** — サイドバーで一括管理、`discoveryRoots` で自動検出。
  セッション構成の自動復元、外観は `~/.config/ghostty/config` を継承

## キーマップ

| キー | 動作 |
|---|---|
| `⌘K` | コマンドパレット |
| `⌘N` | 新規 worktree |
| `⌘T` | 選択中 worktree にセッション追加 |
| `⌘1`–`⌘9` | セッション切替 |
| `⌘⇧U` | 最新の入力待ちへジャンプ |
| `⌘D` / `⌘⇧D` | ペインを右 / 下に分割 |
| `⌘⇧W` | ペインを閉じる(セッションは維持) |
| `⌘]` | 次のペインへ |
| `⌘B` | サイドバー切替 |
| `⌘,` | 設定 |

## 設定

グローバル `~/.config/viterm/config.json` + プロジェクト別 `.viterm.json`。
主要キーは設定ウィンドウ(`⌘,`)からも編集できる。

```json
{
  "worktreePathTemplate": "~/worktrees/{project}/{branch}",
  "defaultPreset": "claude",
  "discoveryRoots": ["~/dev"]
}
```

全キーのリファレンス(プリセット・状態フック・マージ規則)は
[docs/configuration.md](docs/configuration.md)。設定ゼロでも動く。

## ソースからビルド

前提: macOS(arm64)/ フル Xcode(Metal Toolchain 込み。CLT のみ不可)。

```sh
scripts/setup-zig.sh     # pinned Zig を vendor/zig/ に展開
scripts/fetch-ghostty.sh # ghostty を固定コミットで取得 + viterm パッチ適用
scripts/build-ghostty.sh # GhosttyKit.xcframework を生成
swift build
swift test
scripts/make-app.sh      # .build/viterm.app を組み立て
```

libghostty ビルドの既知問題は [docs/ghostty-integration.md](docs/ghostty-integration.md)。

### アーキテクチャ

| ターゲット | 役割 |
|---|---|
| `VitermCore` | ドメインモデル・設定・パステンプレート・状態検出・ViewModel。UI 非依存 |
| `GitKit` | `git` CLI ラッパー(worktree / branch / merge)。UI 非依存 |
| `VitermServices` | オーケストレーション層(`AppModel`)。依存は全てプロトコル注入 |
| `VitermApp` | AppKit アプリ本体(サイドバー・libghostty サーフェス・ダイアログ・パレット) |
| `vendor/` | ghostty ソースと生成物(git 管理外、スクリプトで取得) |

リリース手順(署名・公証・DMG)は [docs/RELEASE.md](docs/RELEASE.md)。

## ライセンス

MIT([LICENSE](LICENSE))。バグ報告・機能要望は
[Issues](https://github.com/viteflowsystem/viterm/issues) へ。
