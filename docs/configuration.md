# vitea — 設定リファレンス

vitea の設定は2段階のファイルベースで、`~/.config/vitea/config.json`(グローバル)と
`<リポジトリルート>/.vitea.json`(プロジェクト別)をマージして使う。
実装は `Sources/ViteaCore/Config/`(`ViteaConfig.swift` / `ConfigLoader.swift`)、
worktree 作成・状態変化・リポジトリ自動検出まわりの補助機能は `Sources/ViteaServices/` にある。

> 本ドキュメントは実装済みのコードのみを典拠にしている。UI(設定画面・worktree作成ダイアログ等)は
> 執筆時点でまだ実装途上のため、「この値をどこに設定するか」がまだ config ファイルに無い項目については
> その旨を明記している。

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

これ以外のキーは現時点のスキーマには存在しない(post-creation hook・状態変化 hook・リポジトリ自動検出の
ルートディレクトリ等は §7・§8 を参照。いずれも今のところ config ファイルではなく呼び出し側がその都度渡す値)。

### サンプル: グローバル設定

```json
{
  "worktreePathTemplate": "~/worktrees/{project}/{branch}",
  "defaultPreset": "claude",
  "copySessionDataByDefault": true,
  "repositories": [
    { "name": "vitea", "path": "/Users/me/dev/vitea" }
  ],
  "presets": [
    { "name": "claude", "command": "claude", "arguments": [], "environment": {} },
    { "name": "codex", "command": "codex", "arguments": [], "environment": {} },
    { "name": "shell", "command": "/bin/zsh", "arguments": [], "environment": {} },
    { "name": "gemini", "command": "gemini", "arguments": ["--yolo"], "environment": {} }
  ]
}
```

### サンプル: プロジェクト設定(`.vitea.json`)

このリポジトリだけ worktree の置き場所を変え、`claude` プリセットに追加引数を足す例。

```json
{
  "worktreePathTemplate": "worktrees/{branch}",
  "presets": [
    { "name": "claude", "command": "claude", "arguments": ["--dangerously-skip-permissions"], "environment": {} }
  ]
}
```

> `presets` の各要素は `SessionPreset` の `Codable` 自動合成でデコードされるため、
> `arguments` / `environment` を省略すると(Swift 側の初期化子に既定値があっても)
> デコードエラーになる。JSON では4フィールドすべてを明示する必要がある
> (トップレベルの `ViteaConfigFile` 側のキー、例えば `presets` キー自体の省略は問題ない)。

> **注意**: 上の例のようにグローバル設定に `presets` の指定が無い状態でプロジェクト設定にだけ
> `presets` を書くと、§3 のマージ規則により組み込み既定プリセット(`codex` / `shell`)は
> 完全に消え、このプロジェクトでは `claude` プリセットしか使えなくなる。既定プリセットを
> 残しつつ追加・上書きしたい場合は、必要なプリセットすべてを明示的に列挙すること。

## 3. マージ規則

`ViteaConfig.merge(global:project:)` は「組み込み既定値 → グローバル → プロジェクト」の順に重ね合わせる。

- **スカラー値**(`worktreePathTemplate` / `defaultPreset` / `copySessionDataByDefault`):
  プロジェクト側の値があればそれを使い、無ければグローバル、どちらも無ければ組み込み既定値。
  (`project ?? global ?? default` の3段フォールバック)
- **リスト値**(`presets` / `repositories`): それぞれのキー(`presets` は `name`、`repositories` は
  `path`)でマージする。グローバル・プロジェクトのどちらにも指定が無ければ組み込み既定値をそのまま使う。
  どちらか一方でも指定があれば、組み込み既定値は使わず「グローバル → プロジェクト」の順に適用し、
  同じキーのエントリはプロジェクト側の内容で完全に上書き(部分マージではない)、新規キーは末尾に追加する。
  順序は初出時点の並びを保つ。

つまり、`.vitea.json` で `presets` を1つだけ書いても、グローバル設定で定義した他のプリセットは
(グローバル設定に何か `presets` の指定がある限り)消えずに残る。逆にグローバルにも `.vitea.json` にも
`presets` の指定が全く無ければ、後述の組み込み既定プリセット3つがそのまま使われる。

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

hook の起動コマンド自体は現時点では config ファイルのキーではなく、`Sources/ViteaServices/` の該当 API を
呼び出す側(worktree作成ダイアログの入力値、将来の設定画面など)がその都度文字列として渡す値になっている。
どちらも `/bin/sh -c <コマンド>` で非同期・非ブロッキング実行され、実行完了を待たない。

### post-creation hook(`WorktreeProvisioner`)

worktree 作成後に実行される。`WorktreeCreationRequest.postCreationHookCommand` に設定する。

| 環境変数 | 内容 |
|---|---|
| `VITEA_WORKTREE_PATH` | 作成された worktree の絶対パス |
| `VITEA_BRANCH` | チェックアウトされたブランチ名(生の形。`/` を含みうる) |
| `VITEA_GIT_ROOT` | リポジトリルートの絶対パス |

### 状態変化 hook(`StatusChangeHookRunner`)

セッションの状態(`AgentSession.State`: `busy` / `waitingInput` / `idle`)が変化したときに、
**到達した新状態ごとに**設定されたコマンドを実行する(状態遷移の組み合わせごとではない)。
`StatusChangeHookConfig` の `onBusy` / `onWaitingInput` / `onIdle` にそれぞれ設定する。

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
git リポジトリを走査する(ccmanager の `CCMANAGER_MULTI_PROJECT_ROOT` 相当)。走査対象のルートディレクトリ自体は
現時点では config ファイルのキーではなく、呼び出し側が `discover(rootDirectory:)` の引数として渡す。

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
