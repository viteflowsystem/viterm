# viterm

AI coding agent(Claude Code / Codex 等)を並列運用するためのネイティブ macOS ターミナル。
Swift + AppKit + libghostty。概要と機能は README.md 参照。

## ビルド・テスト

```sh
swift build          # 全ターゲット
swift test           # ユニットテスト(VitermCore / GitKit / VitermServices)
scripts/make-app.sh  # .build/viterm-dev.app を組み立て(実行確認はこちらで。brew 版と区別できる Dev フレーバー)
```

初回は libghostty のセットアップが必要: `scripts/setup-zig.sh` → `scripts/fetch-ghostty.sh`
→ `scripts/build-ghostty.sh`(既知の問題は docs/ghostty-integration.md)

## 構成

- `Sources/VitermCore` — ドメインモデル・設定・状態検出・ViewModel。UI 非依存
- `Sources/GitKit` — git CLI ラッパー(worktree / branch / merge)。UI 非依存
- `Sources/VitermServices` — オーケストレーション層(AppModel)。UI 非依存
- `Sources/VitermApp` — AppKit アプリ本体
- `vendor/` — ghostty ソースと生成物。**git 管理外**、スクリプトで取得・生成
- `docs/ui-mock.html` — UI のデザインリファレンス。UI 変更時はこれと見比べる

## 規約

- Swift 6、UI 非依存層(VitermCore / GitKit / VitermServices)には必ずユニットテストを付ける
- コードコメントは英語で書く(UI 文言などの文字列リテラルは日本語のまま)
- `vendor/` 以下・ビルド生成物・`*.xcframework` はコミットしない
- 変更が動作確認できたらコミットして push する(溜めない)
- リリースは `scripts/release.sh <version>`(署名・公証。docs/RELEASE.md 参照)
