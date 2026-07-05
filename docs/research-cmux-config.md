# cmux の設定項目調査(2026-07-05)

viterm の設定画面・設定スキーマ設計の参考資料。調査エージェントによるレポート。

## 1. 設定ファイルの場所・形式・リロード

| 種別 | パス | 役割 |
|---|---|---|
| ターミナル外観 | `~/.config/ghostty/config`(fallback: `~/Library/Application Support/com.mitchellh.ghostty/config`、v0.64.0以降 `com.cmuxterm.app/config.ghostty` も) | フォント・テーマ・色を既存 Ghostty 設定から継承 |
| グローバル設定 | `~/.config/cmux/cmux.json` | アプリ挙動全般 |
| プロジェクトローカル | `./.cmux/cmux.json`(fallback `./cmux.json`) | actions/commands/UI配線/通知フックの上書き(チームでgit共有可) |

- JSON with comments・trailing comma 許容。`$schema` でエディタ補完
- **ホットリロード**: `Cmd+Shift+,` / CLI `cmux reload-config`(例外: `automation.socketControlMode` は起動時のみ)
- スキーマエラーはコマンドパレットに表示

## 2. トップレベルキー(21+)

`$schema`, `schemaVersion`, `paneBorderColor`, `activePaneBorderColor`, `actions`, `ui`, `commands`, `vault`, `newWorkspaceCommand`, `workspaceGroups`, `surfaceTabBarButtons`, `app`, `terminal`, `notifications`, `sidebar`, `workspaceColors`, `sidebarAppearance`, `automation`, `browser`, `markdown`, `shortcuts`, `canvas`, `fileEditor`, `fileExplorer`, `diffViewer`

### app(抜粋)
`appearance`(system/light/dark)、`windowTitleTemplate`(プレースホルダ付き)、`menuBarOnly`、`newWorkspacePlacement`(top/afterCurrent/end)、`workspaceInheritWorkingDirectory`、`minimalMode`、`globalFontMagnification`、`reorderOnNotification`(新通知でワークスペースを先頭へ)、`confirmQuit`(always/dirty-only/never)、`sendAnonymousTelemetry` ほか

### terminal(cmux固有部分)
`showScrollBar`(TUI検出時は自動非表示)、`scrollSpeed`、`copyOnSelect`、`autoResumeAgentSessions`、`agentHibernation`(アイドルエージェントの一時停止=メモリ節約)、`rendererRealization`(オフスクリーン時のGPUメモリ解放)、`textBox*`(プロンプト入力欄)、`resumeCommands`

### notifications
`dockBadge`、`unreadPaneRing`、`paneFlash`、`suppressOnlyFocusedSurface`、`agentPermissionPrompt`、`agentTurnComplete`(whenIdle/always/never)、`agentIdleReminder`、`sound`/`customSoundFilePath`、`command`(通知時シェル実行)、`hooksMode`/`hooks`(append/replace)
検出: OSC 9/99/777 + CLI `cmux notify`。UIは「ペイン枠・サイドバー未読バッジ・ポップオーバー・macOS通知」の4系統

### sidebar / workspaceColors / sidebarAppearance
表示項目の個別ON/OFF(`hideAllDetails`, `wrapWorkspaceTitles`, `branchLayout`, `showBranchDirectory`, `showPullRequests`, `watchGitStatus`, `showSSH`, `showPorts`, `showLog`, `showProgress` 等)。ワークスペース色は8スタイル×16色を編集可。`sidebarAppearance.matchTerminalBackground` / `tintColor` / `tintOpacity`

### automation
`socketControlMode`(off/cmuxOnly/automation/password/allowAll)、`socketPassword`、各エージェント統合の個別ON/OFF(`claudeCodeIntegration` 等)、`claudeBinaryPath`、`workspaceAutoNaming` + `autoNamingAgent`(会話内容から自動命名)、`suppressSubagentNotifications`、`portBase`/`portRange`(`CMUX_PORT`)
Socket API は Unix ドメインソケット上の JSON-RPC(既定 `/tmp/cmux.sock`)

### shortcuts
全68アクションを個別上書き(`bindings`: アクションID→キー、コード対応、null で無効化)。`when` に VS Code スタイルのコンテキスト述語(`sidebarFocus && !terminalFocus` 等)

### actions / commands(ユーザー拡張の核心)
- `actions.<id>`: type(builtin/command/agent/workspaceCommand)、title、command、target、shortcut、icon、palette、confirm
- `commands[]`: 単純シェルコマンド、または `workspace.layout`(direction/split/children の分割ツリー、葉は surfaces[] で terminal/browser + command/cwd/env/focus)でワークスペースレイアウトを丸ごと定義
- `ui.newWorkspace.action` に自作アクションIDを指定して「＋」ボタンの既定動作を差し替え(= worktree-agents 方式のワークフロー登録口)
- プロジェクトローカル設定で actions/commands/ui をリポジトリごとに上書き

## 3. GUI設定画面(Cmd+,)

カテゴリタブ: **App / Workspace colors / Automation / Browser / Keyboard shortcuts / Reset** の6区分。ショートカットは一覧から「値クリック→キー入力で記録」。actions/commands のようなユーザー拡張は GUI に含めず JSON のみ。

## 4. 設計思想

「cmux is a primitive, not a solution」— 通知は事実を伝えるだけで対応はフックに委譲、ワークフロー(worktree運用等)は actions/commands/layout の汎用プリミティブでユーザーが記述。Socket API/CLI も操作の型のみ提供。

## viterm への示唆

1. **外観は Ghostty config 継承で自作しない**(既に同方針)— スクロールバー等 cmux固有の少数だけ足す
2. **GUI設定は少カテゴリ + ショートカット一覧UI**、拡張ポイント(プリセット、hook、レイアウト)は JSON に置いて GUI は入口だけ
3. 取り込み候補(優先度順):
   - 通知の粒度設定(`agentTurnComplete` 相当: whenIdle/always/never、サウンド選択)
   - ショートカットのカスタマイズ(`shortcuts.bindings`)
   - ホットリロード(config.json の変更監視 or ⌘⇧, )
   - プロジェクトローカル設定の actions 拡張(viterm は `.viterm.json` が既にあるので同路線)
   - `agentHibernation` / `rendererRealization` 相当のリソース節約(セッション多数時)
   - `windowTitleTemplate`、`confirmQuit`

主な情報源: cmux.com/docs(Configuration / Custom Commands / Settings / Socket API)、manaflow-ai/cmux README、Discussion #1323
