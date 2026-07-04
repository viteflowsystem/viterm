# libghostty 統合メモ(T2/T3)

このドキュメントは T2(libghostty ビルドパイプライン)と T3(スパイク)で得た知見を記録する。
特に、このリポジトリの開発環境固有の既知の問題(ビルド阻害要因と回避策)を優先して記載する。

## 環境

- vendor/ghostty: ghostty-org/ghostty のコミット `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`(タグ `v1.3.1` 相当)に固定。`scripts/ghostty-commit` 参照
- 要求 Zig バージョン: `0.15.2`(`vendor/ghostty/build.zig.zon` の `minimum_zig_version`。`src/build/zig.zig` の `requireZig` が major.minor の完全一致 + patch 以上を強制するため、実質「0.15.2 以降の 0.15.x のみ」)
- 本機: macOS 26.5.1 / Xcode 26.6 (Build 17F113) / arm64

## 既知の問題 1: Zig 0.15.2 のセルフホスト Mach-O リンカが新しい macOS SDK の .tbd を解釈できない

**症状**: `zig build`(および `zig run` で trivial な hello world ですら)が、`-lSystem` にリンクしているにもかかわらず `_abort` `_getenv` `_isatty` など libSystem 由来のほぼ全シンボルで `undefined symbol` を出して失敗する。Ghostty のコードとは無関係で、Zig 単体・ghostty 双方の「build.zig 自体をコンパイルするビルドランナー」の内部リンクの時点で既に失敗する。

**原因**: `xcode-select -p` が指す Xcode.app 付属の macOS SDK(本機では `MacOSX26.5.sdk`。Xcode 26.6 同梱、非常に新しいバージョン)の `.tbd` ファイルを、Zig 0.15.2 のセルフホストリンカが正しくパースできない。Zig 側の既知クラスの互換性問題で、Ghostty のバージョンには依存しない。zig master(0.17.0-dev)では発生しないが、Ghostty は `requireZig` で major.minor の完全一致を要求するため master は使えない(かつ `@cImport` / `std.process.EnvMap` などの言語仕様変更でそのままでは ghostty の build.zig がコンパイルできない)。

**回避策**: `/Library/Developer/CommandLineTools/SDKs/` に同梱される枯れたバージョンの SDK(本機では `MacOSX.sdk` → 実体は `MacOSX15.2.sdk`)を使うとリンクが成功する。ただし `--sysroot` フラグは `zig build` が内部で `build.zig` 自体をコンパイルする「ビルドランナー」のブートストラップには適用されないため効果がない。`DEVELOPER_DIR=/Library/Developer/CommandLineTools` 環境変数で zig の SDK 自動検出そのもの(`xcode-select` / `xcrun` 経由)を切り替える必要がある。

`scripts/build-ghostty.sh` は「まずデフォルトで `zig build` を試行 → 失敗したら `DEVELOPER_DIR` を CommandLineTools に切り替えて自動リトライ」という自己修復フローになっている。

## 既知の問題 2: `-Dxcframework-target=native` でも iOS SDK が要求される

**症状**: 上記の回避策(`DEVELOPER_DIR=CommandLineTools`)を適用すると、ビルドランナー自体は動くようになるが、今度は `freetype` パッケージ(`vendor/ghostty/pkg/freetype/build.zig`)の `apple_sdk.addPaths` が `std.zig.LibCInstallation.findNative` → `error.DarwinSdkNotFound` で panic する。

**原因**: `vendor/ghostty/src/build/GhosttyXCFramework.zig` の `init()` は、`-Dxcframework-target=native` / `universal` の指定に関わらず、**macOS universal・native macOS・iOS・iOS Simulator の 4 バリアントを無条件に構築**し、最終的な xcframework に含めるかどうか(`switch (target) { .universal => ..., .native => ... }`)は成果物選択の段階でしか分岐しない。iOS / iOS Simulator 向けのビルドは `apple-sdk` パッケージ経由で `xcrun --sdk iphoneos --show-sdk-path` 等を呼ぶが、CommandLineTools には iOS プラットフォーム SDK が同梱されないため失敗する。

**回避策(vendor へのパッチ)**: vitea は arm64 macOS 専用アプリで iOS ターゲットは不要なため、`src/build/GhosttyXCFramework.zig` を「`target` に応じて必要なバリアントだけを構築する」形に書き換えた(`native` の場合は `macos_native` のみを構築し、`ios` / `ios_sim` / `macos_universal` のビルドステップ自体を作らない)。

この変更は **vendor/ghostty(pinned upstream コード)へのパッチ**であり、`scripts/fetch-ghostty.sh` で再取得すると失われる。再現性を保つため、今後 `scripts/fetch-ghostty.sh` にパッチ適用ステップを追加するか、この差分を明示的にドキュメント化しておく必要がある(TODO: 現状はこの md ファイルに差分の説明を残すのみで、自動適用にはなっていない)。

## 既知の問題 3 (未解決・本機のブロッカー): Xcode の Metal Toolchain コンポーネントが欠落しており、この sandbox からは取得できない

**症状**: 上記 2 つの回避策を適用した状態で `zig build` を実行すると、153 ステップ中 147 ステップまで成功し(依存パッケージのフェッチ・freetype 等のビルド・libghostty 本体のコンパイルは完走)、最後の Metal シェーダコンパイルでのみ失敗する。

```
xcrun: error: unable to find utility "metal", not a developer tool or in PATH
```

(`DEVELOPER_DIR=CommandLineTools` の場合。CommandLineTools には Metal コンパイラ一式が存在しない)

デフォルトの `DEVELOPER_DIR`(Xcode.app)に戻すと `metal` 本体(`.../Toolchains/XcodeDefault.xctoolchain/usr/bin/metal`)は存在するが、`metallib`(AIR 中間表現を最終的な `.metallib` にリンクするツール)がこの Xcode インストールに存在しない:

```
xcrun: error: unable to find utility "metallib", not a developer tool or in PATH
```

**原因**: 最近の Xcode は Metal コンパイラツールチェーンの一部(`metallib` を含む)を「Metal Toolchain」という別ダウンロードコンポーネントとして分離しており、この sandbox の Xcode 26.6 インストールにはそれが含まれていない。`xcodebuild -downloadComponent MetalToolchain` で取得を試みたが、Apple のアセットカタログサーバーへの到達性がなく `Failed fetching catalog for assetType (com.apple.MobileAsset.MetalToolchain)` で失敗する。`xcodebuild -runFirstLaunch` でプラグイン読み込みエラー(`IDESimulatorFoundation` のシンボル不整合)は解消したが、Metal Toolchain 自体は取得できなかった。システム全体を検索しても `metallib` バイナリは存在しない。

**結論**: これは vitea / Ghostty / Zig のコード上の問題ではなく、**この sandbox 環境の Xcode インストールに Metal Toolchain コンポーネントが欠けており、かつネットワーク的に取得できない**という環境側の制約。GPU レンダラを持つ Ghostty の macOS 版は Metal シェーダのコンパイルが必須であり、これを回避する手段はない(vt のみのビルドに倒す、等の代替は「サーフェスを表示する」という T3 の目的自体を達成できないため不採用)。

**対処方針(要判断)**:
1. Metal Toolchain を含む完全な Xcode がインストール済みの macOS 実機 / 別環境で `scripts/fetch-ghostty.sh` → `scripts/setup-zig.sh` → `scripts/build-ghostty.sh` を実行する(既知の問題 1・2 の回避策は既にスクリプト/パッチに組み込み済みなので、Metal Toolchain さえ揃えばそのまま通る見込みが高い)。
2. この sandbox 自体に Apple のアセットカタログへのネットワーク到達性を追加できるなら、`xcodebuild -downloadComponent MetalToolchain` を再実行する。
3. 上記が難しい場合、T2/T3 はこの環境では完了できないため、GhosttyKit の生成物(xcframework)を外部でビルドして持ち込む、という運用に倒す。

## scripts/ 各ファイルの役割

- `scripts/ghostty-commit`: 固定コミットハッシュ(1行)
- `scripts/fetch-ghostty.sh`: `vendor/ghostty` を上記コミットで取得・更新(冪等)。**現状、既知の問題 2 のパッチは自動適用されない**点に注意
- `scripts/setup-zig.sh`: Zig 0.15.2 (aarch64-macos) を ziglang.org から取得し `vendor/zig/` に展開(sha256 検証あり)
- `scripts/build-ghostty.sh`: `zig build` を実行して `vendor/ghostty/macos/GhosttyKit.xcframework` を生成。デフォルト実行で失敗した場合、`DEVELOPER_DIR=/Library/Developer/CommandLineTools` を使った自動リトライを行う(既知の問題 1 の回避策)

## Surface API 調査メモ(T3 向け、実装未着手)

`vendor/ghostty/macos/Sources/Ghostty/` (特に `Ghostty.App.swift` / `Ghostty.Surface.swift` / `Surface View/SurfaceView_AppKit.swift`) と `include/ghostty.h` を読んだ範囲での要点:

- **初期化順序**: `ghostty_config_new()` → `ghostty_config_load_default_files` 等 → `ghostty_config_finalize` → `ghostty_app_new(&runtime_cfg, config)`(アプリ全体で 1 インスタンス)→ サーフェスごとに `ghostty_surface_new(app, &surface_cfg)`
- **サーフェス生成**: `ghostty_surface_config_new()` で config を作り、`platform_tag = GHOSTTY_PLATFORM_MACOS`、`platform.macos.nsview` に対象 `NSView` の unretained ポインタ、`scale_factor`、`working_directory`、`command`(zsh 等)、`env_vars` を設定して `ghostty_surface_new(app, &config)`。**レンダリング(Metal)はライブラリ内部が nsview に対して行う** — ホスト側で `CAMetalLayer` や描画ループを自前で用意する必要はない(`SurfaceView_AppKit.swift` にも明示的な `wantsLayer`/`CAMetalLayer` セットアップは見当たらない)
- **スレッドモデル**: `wakeup_cb`(任意スレッドから呼ばれ得る)を受けて `DispatchQueue.main.async { ghostty_app_tick(app) }` を呼ぶ。libghostty 側からのコールバックは main スレッドに戻して処理する設計
- **リサイズ**: ビューの `sizeDidChange` 相当のタイミングで `convertToBacking` したピクセルサイズを `ghostty_surface_set_size(surface, width, height)` に渡す
- **入力**: キーは `ghostty_surface_key(surface, keyEvent)`、マウスは `ghostty_surface_mouse_button` / `ghostty_surface_mouse_pos` / `ghostty_surface_mouse_scroll`
- **フォーカス**: `ghostty_surface_set_focus(surface, focused)`
- **後始末**: `ghostty_surface_free(surface)` / `ghostty_app_free(app)`

**注意**: 公式デモ Ghostling (github.com/ghostty-org/ghostling) は `ghostty/vt.h` (libghostty-vt。VT パーサ + 端末状態管理のみ)しか使っておらず、レンダリングは raylib で完全に自前実装している。**フル Surface API(Metal 描画込み)の実装リファレンスにはならない** — Ghostty.app macOS 版の `SurfaceView_AppKit.swift` が唯一の実装リファレンス。

T3(実際にウィンドウを出して zsh を動かす実装)は GhosttyKit.xcframework が生成できていないため未着手。上記の API 理解に基づき、GhosttyKit が用意でき次第 `Package.swift` に binaryTarget として組み込み、`Sources/ViteaApp` に最小の NSView + `ghostty_app_new`/`ghostty_surface_new` 呼び出しを実装する。
