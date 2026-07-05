# viterm

AI coding agent(Claude Code / Codex 等)を並列運用するためのネイティブ macOS ターミナル。
Swift + AppKit + libghostty。コンセプトは docs/requirements.md、タスクは docs/tasks.md 参照。

## ビルド・テスト

```sh
swift build          # 全ターゲット
swift test           # ユニットテスト(ViteaCore / GitKit)
swift run ViteaApp   # アプリ起動
```

libghostty のセットアップ(T2 完了後): `scripts/setup-zig.sh` → `scripts/build-ghostty.sh`

## 構成

- `Sources/ViteaCore` — ドメインモデル(Repo/Worktree/Session)・設定ロード・パステンプレート。UI 非依存
- `Sources/GitKit` — git CLI ラッパー(worktree / branch / merge)。UI 非依存
- `Sources/ViteaApp` — AppKit アプリ本体(サイドバー、ターミナルホスト、ダイアログ)
- `vendor/` — ghostty ソースと生成物。**git 管理外**、スクリプトで取得・生成
- `docs/` — 要件・調査・UIモック・タスク

## 規約

- Swift 6、UI 非依存層(ViteaCore / GitKit)には必ずユニットテストを付ける
- `vendor/` 以下・ビルド生成物・`*.xcframework` はコミットしない
- チーム開発時: タスクは TaskList で管理し、着手時に owner を自分に設定。担当タスクのディレクトリ以外は変更しない(Package.swift の編集は libghostty 統合担当のみ)。git commit はリードが行う
