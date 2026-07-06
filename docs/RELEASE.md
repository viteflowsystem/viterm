# リリース手順(署名・公証・配布)

viterm は Swift + libghostty のネイティブアプリなので、electron-builder のような
全自動ツールが無い。署名・公証・DMG 化を `scripts/release.sh` で行う。

## 前提(初回だけ)

### 1. Developer ID Application 証明書

このMacのキーチェーンに Developer ID Application があること:

```sh
security find-identity -v -p codesigning
# → "Developer ID Application: AKIFUMI AKAZAWA (Q2RDXJ2534)" が出れば OK
```

無ければ Xcode → Settings → Accounts → Manage Certificates → ＋ → Developer ID
Application で作成(このMacで秘密鍵が生成される)。

### 2. 公証プロファイルの登録

App Store Connect で API キー(Access: Developer)を発行し、`.p8` をダウンロード。
Key ID / Issuer ID とあわせて一度だけ登録する:

```sh
xcrun notarytool store-credentials viteflow-notary \
  --key ~/.credentials/AuthKey_XXXXXXXXXX.p8 \
  --key-id XXXXXXXXXX \
  --issuer <Issuer ID(App Store Connect の Keys ページ上部の UUID)>
```

- `viteflow-notary` はプロファイル名(アカウント共通で使う想定の汎用名)。他アプリ
  (timedog 等)の公証でも同じプロファイルを使い回せる
- キーチェーンに保存されるので、以降 `.p8` の中身は不要
- API キーは Developer ロール = 最小権限。漏れても被害はビルドアップロード/公証まで

## リリースを切る

```sh
scripts/release.sh 0.1.0
```

これで以下が自動で走る:

1. `make-app.sh` でバンドル組み立て
2. Info.plist にバージョン反映
3. Developer ID + Hardened Runtime で本署名(`Resources/viterm.entitlements`)
4. アプリを公証 → `stapler staple`(オフラインでも Gatekeeper を通る)
5. staple 済みアプリから DMG を作成
6. DMG を署名・公証・staple
7. `spctl` で検証し、DMG のパスと sha256 を出力

公証は Apple のキュー次第で数分待つ(`--wait`)。ローカルなので待ち時間のコストは無し。

## 配布

1. **GitHub Releases** にタグ `v0.1.0` で DMG をアップロード
2. **Homebrew Cask**(`Casks/viterm.rb`)の `version` と `sha256` を、release.sh の
   出力値で更新してタップリポジトリに push
   - `brew install --cask viteflowsystem/tap/viterm`
   - ⚠️ Homebrew は DMG を**公開URL**から取得する。リポジトリが private の場合、
     Releases アセットも認証が要るため、DMG は公開リポジトリの Releases か
     Cloudflare R2 等の公開ストレージに置く必要がある

## CI 化(将来・任意)

現状はローカル実行。頻度が上がったら GitHub Actions の macOS runner に載せる:

- `.p8` を Actions secret に、`notarytool` は `--key`/`--key-id`/`--issuer` を直接渡す
- 公証待ちで課金を食わないよう `submit`(--wait なし)→ 別ステップで `wait`/`staple` に分離
- スクリプトは同じものを流用できる(プロファイル参照を引数渡しに変えるだけ)
