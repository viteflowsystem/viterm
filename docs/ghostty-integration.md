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

## 既知の問題 3 (解決済み): Xcode の Metal Toolchain コンポーネントが欠落していた

**解決**: サンドボックス外(リード側)で `xcodebuild -downloadComponent MetalToolchain` を実行して導入済み(2026-07-04)。以降この問題は発生しない。当時の症状・調査記録は以下に残す。

## (記録)既知の問題 3 の当時の症状

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
- `scripts/fetch-ghostty.sh`: `vendor/ghostty` を上記コミットで取得・更新(冪等)。`scripts/patches/*.patch` を自動適用する(適用済みならスキップ)
- `scripts/patches/0001-xcframework-native-only.patch`: 既知の問題 2 の回避パッチ(native 指定時に iOS/universal バリアントをビルドしない)
- `scripts/setup-zig.sh`: Zig 0.15.2 (aarch64-macos) を ziglang.org から取得し `vendor/zig/` に展開(sha256 検証あり)
- `scripts/build-ghostty.sh`: `zig build` を実行して `vendor/ghostty/macos/GhosttyKit.xcframework` を生成。デフォルト実行で失敗した場合、`DEVELOPER_DIR=/Library/Developer/CommandLineTools` に切り替えて自動リトライする(既知の問題 1 の回避策)。このとき最終ステップの `xcodebuild -create-xcframework` はフル Xcode を要求するため、`DEVELOPER_DIR` を剥がして本物の xcodebuild に委譲するシムを PATH 先頭に挿す(4つ目のハマりどころ。CLT の xcodebuild は `-create-xcframework` を実行できない)

## T3 スパイク結果(2026-07-04)

`swift build` に GhosttyKit.xcframework を binaryTarget として組み込み、サーフェス1枚 + デフォルトシェルの起動を確認済み。

- **構成**: `Sources/ViteaApp/Ghostty/GhosttyRuntime.swift`(ghostty_app_t シングルトン、wakeup→main queue で tick、クリップボード callbacks)+ `GhosttySurfaceView.swift`(NSView。サイズ/フォーカス/キー/マウスをサーフェスへ中継)
- **検証済み**: ビルド成功(リンク: stdc++ + AppKit/Metal/MetalKit/QuartzCore/CoreText/CoreVideo/IOSurface/Carbon/UniformTypeIdentifiers)、起動時に libghostty が PTY 経由で `/usr/bin/login -flp <user> ... exec -l /bin/zsh` を spawn することをプロセスツリーで確認、クラッシュ・エラーログなし
- **Swift 6 の注意点**: `ghostty_surface_t`(UnsafeMutableRawPointer)を deinit で解放するには `nonisolated(unsafe)` が必要。surface config の `const char*` は ghostty_surface_new 呼び出しまで `withCString` スコープを維持する必要がある
- **未検証(後続タスクで)**: 画面描画の目視確認(サンドボックスから screencapture 不可)、IME、修飾キー単体(flagsChanged)、⌘V 以外のキーバインド

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

## サーフェスの画面テキスト取得(T13b 向け)

状態検出(T13b)のために「サーフェスの現在の画面テキストを取得する」手段を `include/ghostty.h` / `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift` / `src/apprt/embedded.zig` / `src/terminal/Screen.zig` から調査した結果。

### API シグネチャ

```c
// include/ghostty.h
typedef struct {
  ghostty_point_tag_e tag;   // GHOSTTY_POINT_ACTIVE / VIEWPORT / SCREEN / SURFACE
  ghostty_point_coord_e coord; // EXACT / TOP_LEFT / BOTTOM_RIGHT
  uint32_t x;
  uint32_t y;
} ghostty_point_s;

typedef struct {
  ghostty_point_s top_left;
  ghostty_point_s bottom_right;
  bool rectangle;
} ghostty_selection_s;

typedef struct {
  double tl_px_x;
  double tl_px_y;
  uint32_t offset_start;
  uint32_t offset_len;
  const char* text;      // NUL 終端(かつ text_len も別途保持)
  uintptr_t text_len;
} ghostty_text_s;

bool ghostty_surface_read_text(ghostty_surface_t, ghostty_selection_s, ghostty_text_s*);
bool ghostty_surface_read_selection(ghostty_surface_t, ghostty_text_s*); // ユーザーの選択範囲版
void ghostty_surface_free_text(ghostty_surface_t, ghostty_text_s*);     // 呼び出し必須(内部で alloc.free)
```

### セマンティクス

- `ghostty_surface_read_text` は `sel`(`ghostty_selection_s`)で指定した範囲のテキストを返す。`sel` はユーザーの選択状態とは無関係に「読み取る範囲」を指定するためだけのパラメータ(コメント: "the selection structure is used as a way to determine the area of the screen to read from, it doesn't have to match the user's current selection state")
- **ビューポート(現在画面に表示されている可視領域)全体を取得する**には、`top_left` / `bottom_right` の両方に `tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT` / `GHOSTTY_POINT_COORD_BOTTOM_RIGHT`(`x`/`y` は無視されるので `0,0` でよい)を指定し、`rectangle: false`。Ghostty.app macOS 版 `SurfaceView_AppKit.swift` の `cachedVisibleContents` がまさにこのパターン(500ms キャッシュして頻度を抑えている)。スクロールバック全体を含めたい場合は `tag: GHOSTTY_POINT_SCREEN` を使う(`cachedScreenContents` が対応)
- 返る `ghostty_text_s.text` は Zig 側の `selectionString(.emit = .plain, .unwrap = true, .trim = false)` の出力で、**行はソフトラップを解除(unwrap)した上で `\n` 区切りの単一 C 文字列**になる。`String(cString: text.text)` → `.split(separator: "\n", omittingEmptySubsequences: false)` で `[String]`(可視行配列)に変換できる。`StateDetector.detect(screenLines:)` が期待する入力そのもの
- **メモリ解放は必須**: `ghostty_surface_read_text` が `true` を返した場合、使用後に必ず `ghostty_surface_free_text(surface, &text)` を呼ぶこと(Zig 側で `alloc.free` される。呼ばないとリーク)。`false` が返った場合は `text` は書き込まれておらず解放不要
- **スレッド/ロック**: `ghostty_surface_read_text` は内部で `core_surface.renderer_state.mutex` をロックする。libghostty の他の呼び出し(`ghostty_app_tick` 等)ともこのロックを介して整合するため、任意のタイミングで呼んでよいが、ロック待ちでブロックする可能性がある
- **コスト注意(重要)**: Zig 側のドキュメントコメントに明記: 「This is an expensive operation so it shouldn't be called too often. We recommend that callers cache the result and throttle calls to this function.」Ghostty.app 自身も 500ms キャッシュで緩和している。T13b では 100ms 周期のポーリングを要件としているため、この点は認識しておくこと(セッション数が増えると相応のコストがかかる)

### 使用例(Ghostty.app 本体の実装をほぼそのまま踏襲)

```swift
var text = ghostty_text_s()
let sel = ghostty_selection_s(
    top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
    bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
    rectangle: false)
guard ghostty_surface_read_text(surface, sel, &text) else { return [] }
defer { ghostty_surface_free_text(surface, &text) }
return String(cString: text.text).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
```

実装: `Sources/ViteaApp/Sessions/SessionStateMonitor.swift`(T13b)。

## OSC 通知の一次シグナル化(P7 向け)

要件定義(docs/requirements.md 3.2)は「状態検出は OSC シーケンス優先、テキストパターンはフォールバック」の
二段構えを想定しているが、T3 スパイク時点では `GhosttyRuntime` の `action_cb` は全アクションを無視して
`false` を返すだけだった。ここでは `ghostty_action_tag_e` / `ghostty_target_s` を調査し、対応する
`GhosttySurfaceView` へ中継する仕組みを実装した内容を記録する。

### action_cb のシグネチャと他コールバックとの違い

```c
typedef bool (*ghostty_runtime_action_cb)(ghostty_app_t, ghostty_target_s, ghostty_action_s);
```

`read_clipboard_cb` 等の他のコールバックは第1引数が `void* userdata`(サーフェス生成時に
`ghostty_surface_config_s.userdata` へ設定した値がそのまま返ってくる)だが、`action_cb` だけは
**userdata を直接もらえない**。代わりに `ghostty_target_s`(`tag: GHOSTTY_TARGET_APP` /
`GHOSTTY_TARGET_SURFACE`、`target.surface: ghostty_surface_t`)経由でどのサーフェス(または
アプリ全体)向けのアクションかを知る形になっている。

「どのサーフェスか」を `GhosttySurfaceView` に逆引きするには、`ghostty_surface_t` から
`void* ghostty_surface_userdata(ghostty_surface_t)` を呼ぶ(サーフェス生成時に設定した userdata が
そのまま返る)。実装リファレンス: `macos/Sources/Ghostty/Ghostty.App.swift` の
`surfaceView(from:)`/`action(_:target:action:)`。vitea 側の実装は
`Sources/ViteaApp/Ghostty/GhosttyRuntime.swift` の `surfaceView(from target:)` / `handleAction(target:action:)`。

```swift
private static func surfaceView(from target: ghostty_target_s) -> GhosttySurfaceView? {
    guard target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface else { return nil }
    return view(from: ghostty_surface_userdata(surface))
}
```

### 対応した ghostty_action_tag_e とペイロード

`ghostty_action_tag_e` は67種類(ウィンドウ/タブ/スプリット操作、検索、レンダラ健全性等、vitea が
独自のウィンドウ管理を持つため乗らないものが大半)。このうち「セッション状態把握に使える」もの・
「デスクトップ通知(OSC 9/777)」を実装した。

| tag | ペイロード(`ghostty_action_u` のメンバ) | 由来 | 用途 |
|---|---|---|---|
| `GHOSTTY_ACTION_DESKTOP_NOTIFICATION` | `desktop_notification: { title: const char*, body: const char* }` | OSC 9 / OSC 777 | エージェントからのデスクトップ通知。状態検出の一次シグナル(cmux方式) |
| `GHOSTTY_ACTION_RING_BELL` | (ペイロードなし、tag のみ) | BEL (`\a`) | 注意喚起。ツール依存のアラート検出に使える |
| `GHOSTTY_ACTION_SET_TITLE` | `set_title: { title: const char* }` | OSC 0/1/2 | ウィンドウ/タブタイトル変更。実行中コマンド名の推測等に使える |
| `GHOSTTY_ACTION_PWD` | `pwd: { pwd: const char* }` | OSC 7 | カレントディレクトリ変更 |

上記以外(`GHOSTTY_ACTION_COMMAND_FINISHED`(終了コード・実行時間つき)、`GHOSTTY_ACTION_PROGRESS_REPORT`
(OSC 9;4 のプログレスバー)なども状態検出に使えそうだが今回はスコープ外。ウィンドウ/タブ/スプリット系
(`GHOSTTY_ACTION_NEW_SPLIT` 等)は vitea が libghostty の apprt レベルのウィンドウ管理に乗っていない
(自前の `SplitHostView` を使う)ため、`handleAction` は該当しないアクションをすべて `false`
(未処理)で返す。

### GhosttySurfaceView 側の公開 API

`Sources/ViteaApp/Ghostty/GhosttySurfaceView.swift` に以下のコールバックプロパティを追加した。
`GhosttyRuntime.handleAction` が対応するサーフェスの該当コールバックを呼ぶだけで、通知UIの表示や
状態遷移の判断はコールバックの呼び出し側(`SessionStateMonitor` / `MainWindowController` 側の配線)
の責務とする。

```swift
var onDesktopNotification: ((_ title: String, _ body: String) -> Void)?
var onBell: (() -> Void)?
var onTitleChange: ((_ title: String) -> Void)?
var onPwdChange: ((_ pwd: String) -> Void)?
```

### Swift 6 の注意点

`action_cb` は他の apprt コールバック(`read_clipboard_cb` 等)と同様、`@MainActor` な
`GhosttyRuntime` の static メソッドを直接呼ぶクロージャとして代入しているが、これは libghostty が
これらのコールバックを常に `ghostty_app_tick` 呼び出し元(= main queue に async 済みの `tick()`)と
同じスレッド(メインスレッド)から呼ぶ設計になっているため成立している。既存の `read_clipboard_cb` 等
と同じ流儀を踏襲した。
