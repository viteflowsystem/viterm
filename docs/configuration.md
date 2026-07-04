# vitea — 設定リファレンス

vitea の設定は2段階のファイルベースで、`~/.config/vitea/config.json`(グローバル)と
`<リポジトリルート>/.vitea.json`(プロジェクト別)をマージして使う。
実装は `Sources/ViteaCore/Config/`(`ViteaConfig.swift` / `ConfigLoader.swift`)、
worktree 作成・状態変化・リポジトリ自動検出まわりの補助機能は `Sources/ViteaServices/` にある。

> 本ドキュメントは実装済みのコードのみを典拠にしている。UI(設定画面・worktree作成ダイアログ等)は
> 執筆時点でまだ実装途上のため、config ファイルのスキーマには存在してもランタイム側(`AppModel`)の
> 配線がまだ追いついていないキーについては、その旨を明記している。

## 1. ファイルの場所

| ファイル | パス | 用途 |
|---|---|---|
| グローバル設定 | `~/.config/vitea/config.json` | 全リポジトリ共通の既定値 |
| プロジェクト設定 | `<リポジトリルート>/.vitea.json` | そのリポジトリだけの上書き(dotfiles として管理可能) |

どちらのファイルも存在しなくてよい。両方無い場合は組み込みの既定値(`ViteaConfig.default`)で動作する。
ファイルが存在するが JSON として不正な場合は読み込みエラーになる(存在しないだけなら無視されて既定値にフォールバックする)。

`ConfigLoader.load(globalURL:repositoryRoot:)` がこの2ファイルを読み込み、後述のマージ規則で
1つの `ViteaConfig` にまとめる。

## 2. キー一覧

| キー | 型 | 既定値 | 説明 |
|---|---|---|---|
| `worktreePathTemplate` | string | `"~/worktrees/{project}/{branch}"` | worktree 作成先パスのテンプレート(§4参照) |
| `presets` | array | 下記「既定プリセット」参照 | セッション起動コマンドのプリセット一覧(§5参照) |
| `defaultPreset` | string \| null | `"claude"` | 新規セッション起動時に既定で選ぶプリセット名 |
| `repositories` | array | `[]` | 登録済みリポジトリ一覧(`{ "name": string, "path": string }`) |
| `copySessionDataByDefault` | boolean | `false` | worktree 作成ダイアログで「Claude セッションデータをコピー」チェックボックスの初期値 |
| `postCreationHook` | string \| null | `null` | worktree 作成後に実行する post-creation hook のシェルコマンド(§7参照) |
| `statusHooks` | object \| null | 全フィールド `null` | セッション状態変化 hook(`onBusy`/`onWaitingInput`/`onIdle`。§7参照) |
| `discoveryRoots` | array of string | `[]` | リポジトリ自動検出の走査ルートディレクトリ一覧(§9参照。グローバル設定のみ有効) |

> `postCreationHook` / `statusHooks` / `discoveryRoots` は config のスキーマ・マージ規則としては
> 実装済みだが、執筆時点では `AppModel` がまだこれらを読んでランタイムに反映していない
> (`AppModel.discoveryRootDirectory` を直接設定する、worktree作成ダイアログの入力値をそのまま
> `WorktreeCreationRequest.postCreationHookCommand` に渡す、といった暫定経路が別途ある)。
> 設定ファイルに書けば将来的にはそのまま効くようになる想定だが、現時点では config に書いても
> UI 上の挙動には反映されない。

### サンプル: グローバル設定

```json
{
  "worktreePathTemplate": "~/worktrees/{project}/{branch}",
  "defaultPreset": "claude",
  "copySessionDataByDefault": true,
  "postCreationHook": "echo \"worktree ready: $VITEA_WORKTREE_PATH\"",
  "statusHooks": {
    "onWaitingInput": "terminal-notifier -message \"$VITEA_SESSION_NAME が入力待ちです\""
  },
  "discoveryRoots": ["~/dev", "~/work"],
  "repositories": [
    { "name": "vitea", "path": "/Users/me/dev/vitea" }
  ],
  "presets": [
    { "name": "gemini", "command": "gemini", "arguments": ["--yolo"] }
  ]
}
```

`presets` に組み込み既定(`claude`/`codex`/`shell`)を書き直す必要はない。何も指定しなくても
既定の3つは常に使えるので、ここでは追加したい `gemini` だけを書けば十分(§3参照)。

### サンプル: プロジェクト設定(`.vitea.json`)

このリポジトリだけ worktree の置き場所を変え、`claude` プリセットに追加引数を足す例。

```json
{
  "worktreePathTemplate": "worktrees/{branch}",
  "presets": [
    { "name": "claude", "command": "claude", "arguments": ["--dangerously-skip-permissions"] }
  ]
}
```

> `presets` の各要素(`SessionPreset`)はカスタム `Decodable` 実装により、`arguments` / `environment` を
> 省略すると既定値(`[]` / `{}`)としてデコードされる(上の例のように省略してよい)。
> 一方 `name` / `command` は必須で、これらを省略すると `keyNotFound` でデコードエラーになる。

## 3. マージ規則

`ViteaConfig.merge(global:project:)` は「組み込み既定値 → グローバル → プロジェクト」の順に重ね合わせる。

- **スカラー値**(`worktreePathTemplate` / `defaultPreset` / `copySessionDataByDefault` / `postCreationHook`):
  プロジェクト側の値があればそれを使い、無ければグローバル、どちらも無ければ組み込み既定値。
  (`project ?? global ?? default` の3段フォールバック)
- **`statusHooks`**: `onBusy` / `onWaitingInput` / `onIdle` を **フィールドごとに独立して**
  同じ `project ?? global ?? default` のフォールバックを適用する(オブジェクト単位の丸ごと上書きではない)。
  例えばグローバルで `onIdle` だけ設定し、プロジェクトで `onBusy` だけ設定した場合、
  マージ結果は両方とも有効になる(§2 サンプル参照)。
- **`discoveryRoots`**: グローバル設定の値のみを使う(`global ?? default`)。`.vitea.json` に書いても
  無視される。複数リポジトリを横断的にスキャンするための設定という性質上、プロジェクト単位で
  持つ意味が薄いと判断したため。
- **リスト値**(`presets` / `repositories`): それぞれのキー(`presets` は `name`、`repositories` は
  `path`)でマージする。**組み込み既定値は常にベースとして適用され**、その上にグローバル、
  さらにその上にプロジェクトを「グローバル → プロジェクト」の順で重ねる。同じキーのエントリは
  後勝ちの内容で完全に上書き(部分マージではない)、新規キーは末尾に追加する。順序は初出時点の並びを保つ。

`presets` について具体的には、`.vitea.json` に `claude` プリセットを1つだけ書いても、組み込み既定の
`codex` / `shell` が消えることはない(同じ `claude` というキーだけがその内容で上書きされる)。
`repositories` の組み込み既定値は空配列なので、この「常にベースを適用する」規則があっても
実質的な違いは生まれない。

## 4. worktree パステンプレート

`WorktreePathTemplate`(`Sources/ViteaCore/WorktreePathTemplate.swift`)が `worktreePathTemplate` 文字列を
実際のパスへ展開する。

### プレースホルダ

| プレースホルダ | 展開内容 |
|---|---|
| `{project}` | リポジトリ名(`Repository.name`) |
| `{branch}` | ブランチ名。`/` は `-` に正規化される(例: `feat/login` → `feat-login`) |
| `{branch_raw}` | ブランチ名そのまま(`/` を含む場合、その分だけサブディレクトリになる) |

### パスの解決規則

展開後の文字列の先頭で分岐する。

1. `~` そのもの → ホームディレクトリそのもの
2. `~/` で始まる → ホームディレクトリ基準(`~` を実際のホームディレクトリパスに置換)
3. `/` で始まる → 絶対パスとしてそのまま使う
4. それ以外 → リポジトリルート(`repositoryRoot`)からの相対パスとして、`repositoryRoot + "/" + 展開後文字列` で解決する

### 例

以下はホームディレクトリ `/Users/me`、project(リポジトリ名)`vitea`、
repositoryRoot(リポジトリルート)`/Users/me/dev/vitea` での展開結果。

| テンプレート | branch | 展開結果 |
|---|---|---|
| `~/worktrees/{project}/{branch}`(既定) | `feat/login` | `/Users/me/worktrees/vitea/feat-login` |
| `worktrees/{branch_raw}`(相対パス) | `feat/login` | `/Users/me/dev/vitea/worktrees/feat/login`(サブディレクトリになる) |
| `/Volumes/Work/worktrees/{branch}`(絶対パス) | `hotfix` | `/Volumes/Work/worktrees/hotfix`(ホーム・リポジトリ基準は無視) |

相対パステンプレートは `repositoryRoot + "/" + 展開後文字列` という単純な文字列連結で、
`..` のようなパス要素を正規化(折りたたみ)しない点に注意。`../{branch}` のようなテンプレートを書くと、
展開結果にも文字通り `/…/vitea/../feat-login` の形で `..` が残る(ファイルシステム上は正しく解決されるが、
プレビュー表示上はそのまま見える)。

## 5. プリセット(`presets`)

各プリセットは `SessionPreset`(`Sources/ViteaCore/Models/SessionPreset.swift`)。

| フィールド | 型 | 既定値 | 説明 |
|---|---|---|---|
| `name` | string | (必須) | プリセット名。設定内で一意。`defaultPreset` 等から参照される |
| `command` | string | (必須) | 実行するコマンド(絶対パス、または `PATH` 解決される名前) |
| `arguments` | array of string | `[]` | コマンド引数 |
| `environment` | object (string→string) | `{}` | 追加の環境変数 |

### 組み込み既定プリセット(`ViteaConfig.defaultPresets`)

グローバル・プロジェクトのどちらにも `presets` の指定が無い場合に使われる。

```json
[
  { "name": "claude", "command": "claude", "arguments": [], "environment": {} },
  { "name": "codex", "command": "codex", "arguments": [], "environment": {} },
  { "name": "shell", "command": "/bin/zsh", "arguments": [], "environment": {} }
]
```

`defaultPreset` の既定値は `"claude"`。

## 6. リポジトリ一覧(`repositories`)

`Repository`(`Sources/ViteaCore/Models/Repository.swift`)は `name`(サイドバー表示名。`{project}` にも使われる)と
`path`(リポジトリルートの絶対パス。これが一意キーになる)の2フィールドのみ。ディスク上のリポジトリ自体には
一切手を加えない、単なる参照情報。

## 7. hook の環境変数

`postCreationHook` / `statusHooks` は config のキーとして存在するが、§2 の注記のとおり
`AppModel` がまだこれらを読んでいない。post-creation hook は現状、worktree作成ダイアログの入力値が
`WorktreeCreationRequest.postCreationHookCommand` としてそのまま使われ、状態変化 hook は
`AppModel` 初期化時点の `StatusChangeHookConfig()`(全フィールド `nil`)が使われている。
どちらも `/bin/sh -c <コマンド>` で非同期・非ブロッキング実行され、実行完了を待たない。

### post-creation hook(`WorktreeProvisioner`)

worktree 作成後に実行される。

| 環境変数 | 内容 |
|---|---|
| `VITEA_WORKTREE_PATH` | 作成された worktree の絶対パス |
| `VITEA_BRANCH` | チェックアウトされたブランチ名(生の形。`/` を含みうる) |
| `VITEA_GIT_ROOT` | リポジトリルートの絶対パス |

### 状態変化 hook(`StatusChangeHookRunner`)

セッションの状態(`AgentSession.State`: `busy` / `waitingInput` / `idle`)が変化したときに、
**到達した新状態ごとに**設定されたコマンドを実行する(状態遷移の組み合わせごとではない)。
config の `statusHooks.onBusy` / `onWaitingInput` / `onIdle` にそれぞれ対応する。

| 環境変数 | 内容 |
|---|---|
| `VITEA_SESSION_NAME` | セッションの表示名 |
| `VITEA_WORKTREE_PATH` | セッションが紐づく worktree の絶対パス |
| `VITEA_OLD_STATE` | 変化前の状態(`busy`/`waitingInput`/`idle`)。不明な場合は空文字列 |
| `VITEA_NEW_STATE` | 変化後の状態(`busy`/`waitingInput`/`idle`) |

## 8. Claude セッションデータのコピー

`copySessionDataByDefault`(config)はダイアログのチェックボックス初期値であり、実際のコピー処理は
`WorktreeProvisioner` が行う。

- コピー元: `~/.claude/projects/<パスの "/" を "-" に置換したディレクトリ名>`
  (既定はリポジトリルートのパス。`WorktreeCreationRequest.copySessionDataFrom` で明示的に指定も可能)
- コピー先: 同じ命名規則で、新しい worktree のパスをエンコードしたディレクトリ
- コピー元が存在しない場合(その場所での Claude Code 利用履歴がまだ無い)は **警告なしで何もしない**
- コピー自体が失敗した場合(権限エラー等)は worktree 作成を失敗扱いにはせず、結果の `warnings` に
  メッセージを追加するだけ(非致命的)

## 9. リポジトリ自動検出

`RepositoryDiscovery`(`Sources/ViteaServices/RepositoryDiscovery.swift`)がルートディレクトリ配下の
git リポジトリを走査する(ccmanager の `CCMANAGER_MULTI_PROJECT_ROOT` 相当)。走査ルートは config の
`discoveryRoots`(グローバル設定のみ有効。§3参照)に文字列配列として書けるが、§2の注記のとおり
`AppModel` はまだこれを読んでいない。現状は `AppModel.discoveryRootDirectory` に呼び出し側が
直接 `URL` を1つ設定する形になっている(`discoveryRoots` は複数ルートに対応した文字列配列である一方、
`discoveryRootDirectory` は単一の `URL?` で、両者はまだ型も本数も揃っていない)。

- あるディレクトリは、直下の `.git` が **ディレクトリ** の場合のみリポジトリ本体として検出される。
  `.git` が **ファイル**(`gitdir: …` を指すポインタ、= worktree のチェックアウト先)の場合は除外される
- リポジトリが見つかったディレクトリの内部はそれ以上降りない(ネストした vendor 済みリポジトリ等の
  二重登録を避けるため)
- `maxDepth`(既定 `4`): ルートから何階層下まで走査するか
- `excludedDirectoryNames`(既定: `node_modules` / `vendor` / `Pods` / `DerivedData` / `dist` / `build` /
  `target` / `__pycache__`): この名前のディレクトリには降りない
- 隠しディレクトリ(`.` で始まる名前。`.git` 自身を含む)には既定で降りない

検出結果は `ViteaCore.Repository` の配列で返る(グローバル設定の `repositories` へ追加するかどうかは
呼び出し側=将来の設定 UI が判断する)。
