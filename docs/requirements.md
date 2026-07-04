# vitea — 要件定義

> AI coding agent(Claude Code / Codex など)を並列運用するための、ネイティブmacOSターミナルアプリケーション。
> 一言でいうと「cmux の UI 品質 × ccmanager の worktree 管理 × 1 worktree に複数セッション」。

## 1. 背景と課題

| ツール | 良い点 | 課題 |
|---|---|---|
| cmux (manaflow-ai/cmux) | Swift + AppKit + libghostty のネイティブ構成で軽量・洗練されたUI | git worktree の一級サポートなし(Issue #156 は "not planned" でクローズ。「cmux is a primitive, not a solution」という設計哲学のため今後も期待できない) |
| ccmanager (kbwo/ccmanager) | worktree の作成・削除・マージ・フックまで揃った管理機能 | React Ink + @xterm/headless の TUI in TUI 構成のため、リサイズ時の描画崩れが構造的に発生。リサイズ抑制タイマー(250ms)や復元遅延など対症療法の積み重ねで対処している(Issue #73 ほか) |

加えて、**同一 worktree に対して複数のエージェントセッションを同時に立ち上げたい**というユースケースを両者とも満たさない(ccmanager は worktree : session = 1 : 1 が基本)。

## 2. コンセプト

1. **TUI in TUI をやめる。** ターミナルエミュレーションは libghostty(ネイティブレイヤ)に任せ、アプリの chrome(サイドバー・タブ等)は AppKit/SwiftUI で描画する。リサイズは各サーフェスが直接 PTY にサイズ通知するだけなので、レイアウト崩れが構造的に起きない。cmux と Ghostty.app 本体が実証済みの構成。
2. **リポジトリ・worktree・セッションを第一級オブジェクトとして扱う。** repo : worktree : session = 1 : N : M。複数リポジトリを1ウィンドウのサイドバーで一括管理する。
3. **軽量・キーボード中心。** Electron を使わない。全操作がキーボードで完結する。

## 3. 機能要件

### 3.1 git worktree 管理(ccmanager 相当)
- [ ] worktree 一覧表示: ブランチ名、親ブランチとの ahead/behind(↑3 ↓1)、差分行数(+10 −5)、dirty 状態
- [ ] worktree 新規作成: 新規ブランチ / 既存ローカルブランチ / リモートブランチから
- [ ] 作成先パスはテンプレートで設定可能。例: `~/worktrees/{project}/{branch}_hogehoge` のように、プレースホルダと任意のリテラルを混在できる
  - プレースホルダ: `{project}`(リポジトリ名)、`{branch}`(ブランチ名。`/` は `-` に正規化)、`{branch_raw}`(ブランチ名そのまま。`feat/x` はサブディレクトリになる)
  - `~` と相対パス(リポジトリルート基準)の両方をサポート
  - グローバル設定で既定を持ち、プロジェクト別 `.vitea.json` でオーバーライド可能。作成ダイアログ上でその場編集も可能(テンプレートは展開済みプレビューを表示)
- [ ] worktree 作成時に Claude Code セッションデータ(`~/.claude/projects/…`)をコピーするオプション(失敗しても作成自体は成功する非致命的設計)
- [ ] post-creation hook(worktree パス・ブランチ名・git root を環境変数で渡す、非同期実行)
- [ ] worktree 削除(dirty チェック付き確認、`git worktree remove`)
- [ ] マージ支援: merge(`--no-ff` 既定、引数カスタマイズ可)/ rebase → `--ff-only` の2モード、マージ後の worktree 後始末

### 3.2 セッション管理
- [ ] **1 worktree : N セッション**(本アプリの核心要件)
- [ ] セッション = 任意コマンド(claude / codex / gemini / 素のシェル等)を PTY 上で起動。エージェントプリセット(コマンド・引数・フォールバック引数)を設定可能
- [ ] セッション状態検出: busy / waiting_input / idle。ツールごとの検出ストラテジ(ccmanager 方式: 画面テキストのパターンマッチ + idle デバウンス ~1.5s)。可能なら OSC 9/777 等のターミナル通知シーケンス(cmux 方式)を優先し、パターンマッチはフォールバックにする
- [ ] 状態変化フック(任意コマンド実行)と macOS ネイティブ通知、サイドバーの未読バッジ
- [ ] セッションはアプリ内で表示を切り替えても生存(スクロールバック保持)
- [ ] セッションのリネーム、再起動、終了

### 3.3 ターミナル
- [ ] libghostty によるフル機能ターミナルエミュレーション(24bit色、Kitty プロトコル等)
- [ ] `~/.config/ghostty/config` からテーマ・フォントを継承(cmux 方式)
- [ ] スクロールバック、コピー&ペースト、URLクリック
- [ ] ペイン分割(⌘D 右分割 / ⌘⇧D 下分割)— 同一画面で複数セッションを並べる ※フェーズ2

### 3.4 マルチリポジトリ管理
- [ ] 複数リポジトリ(複数ディレクトリ)を登録し、サイドバーで リポジトリ → worktree → セッション の3階層ツリーとして一括管理
- [ ] リポジトリの追加(ディレクトリ選択 / パス指定)・登録解除(ディスク上のリポジトリは触らない)
- [ ] 指定ルートディレクトリ配下の git リポジトリ自動検出(ccmanager の `CCMANAGER_MULTI_PROJECT_ROOT` 相当)※優先度: 中
- [ ] リポジトリ折りたたみ時も配下の waiting セッション数をバッジで集約表示
- [ ] 状態集計(ステータスバー)・⌘⇧U の未読ジャンプはリポジトリ横断で動作

### 3.5 UI
- [ ] 左サイドバー: リポジトリ → worktree → セッション の3階層ツリー。worktree 行にブランチ・ahead/behind、セッション行に状態インジケータ(●busy / ◐waiting / ○idle)と未読バッジ
- [ ] ⌘1..9 でセッション直接切替、⌘K でコマンドパレット(worktree 作成、セッション起動、切替など全操作)
- [ ] waiting_input のセッションへワンキーでジャンプ(cmux の ⌘⇧U 相当)
- [ ] ステータスバー: 現在の worktree / ブランチ / セッション状態のサマリ(busy 2 · waiting 1 など)

## 4. 非機能要件

- ネイティブ macOS アプリ(Swift + AppKit)。Electron 不使用。起動 1 秒以内、セッション切替は体感遅延なし
- 設定はファイルベース(グローバル: `~/.config/vitea/config.json`、プロジェクト別: `.vitea.json` でオーバーライド)。dotfiles 管理可能。登録リポジトリ一覧はグローバル設定に保存
- libghostty はアルファ品質のため、特定コミット/タグに固定して追随する(cmux も同様の運用)

## 5. スコープ外(当面)

- Windows / Linux 対応(libghostty の GUI レイヤは macOS/Linux 先行だが、まず macOS に集中)
- ブラウザペイン統合(cmux にはあるが本アプリの差別化点ではない)
- SSH リモートワークスペース
- Auto Approval(ccmanager の実験的機能)

## 6. 技術スタック(決定)

| レイヤ | 技術 | 根拠 |
|---|---|---|
| アプリ本体 | Swift + AppKit(一部 SwiftUI) | cmux が同構成で軽量さを実証。Ghostty.app 自体も macOS 版は Swift |
| ターミナル | libghostty(C API、必要に応じ GhosttyKit を参考) | Ghostty.app・cmux のコンシューマ実績。マルチサーフェス管理はホストアプリ責務なので自前実装 |
| PTY | posix_spawn + PTY(Ghostty/cmux と同様のネイティブ管理) | node-pty 系の制約を回避 |
| git 操作 | `git` CLI をサブプロセス実行 | ccmanager と同方式。libgit2 は worktree 系 API が弱く CLI の方が確実 |
| ビルド | Xcode + Zig 0.15.x ツールチェーン(libghostty ビルド用) | libghostty は消費言語を問わず Zig でのビルドが必要 |

### リスクと対策
- **libghostty API の破壊的変更** → コミット固定 + 薄いラッパー層(`GhosttyBridge`)に隔離
- **マルチサーフェス管理の標準パターンが未整備** → Ghostty.app macOS 版のソース(同じく Swift ホスト)を実装リファレンスにする
- **状態検出のパターンマッチが agent の UI 変更で壊れる**(ccmanager Issue #227 の教訓) → 検出ストラテジをプラグイン的に分離し、複数シグナル併用 + デバウンスで頑健化
