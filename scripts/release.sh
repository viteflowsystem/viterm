#!/usr/bin/env bash
# viterm のリリースビルド: Developer ID 署名 → 公証 → staple → DMG 化 → 検証。
#
# 使い方:
#   scripts/release.sh <version>          # 例: scripts/release.sh 0.1.0
#
# 前提(一度だけ):
#   1. Developer ID Application 証明書がキーチェーンにあること
#      (security find-identity -v -p codesigning で確認)
#   2. 公証プロファイルを登録済みであること:
#      xcrun notarytool store-credentials viteflow-notary \
#        --key <AuthKey_XXX.p8> --key-id <KeyID> --issuer <IssuerID>
#   詳細は docs/RELEASE.md 参照。
#
# 環境変数で上書き可:
#   NOTARY_PROFILE  公証プロファイル名(既定: viteflow-notary)
#   SIGN_IDENTITY   署名IDのSHA-1(既定: 最初の Developer ID Application を自動選択)
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version>  (例: 0.1.0)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-viteflow-notary}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/viterm.app"
DIST="$ROOT/.build/dist"
ENTITLEMENTS="$ROOT/Resources/viterm.entitlements"

# --- 署名ID ---------------------------------------------------------------
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | awk '/Developer ID Application/{print $2; exit}')}"
if [ -z "$IDENTITY" ]; then
  echo "error: Developer ID Application の署名IDが見つかりません。" >&2
  echo "       Xcode で証明書を作成するか、キーチェーンに .p12 を取り込んでください。" >&2
  exit 1
fi
echo "==> signing identity: $IDENTITY"

# --- 公証プロファイルの存在チェック --------------------------------------
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "error: 公証プロファイル '$NOTARY_PROFILE' が未登録です。docs/RELEASE.md を参照。" >&2
  exit 1
fi

# --- 1. アプリバンドルを組み立てる(この時点ではアドホック署名) ----------
"$ROOT/scripts/make-app.sh" release

# --- 2. バージョンを Info.plist に反映 ------------------------------------
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"

# --- 3. Developer ID + Hardened Runtime で本署名 --------------------------
echo "==> codesign (Developer ID, hardened runtime)"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

mkdir -p "$DIST"

# --- 4. アプリを公証(zip で提出)して staple ----------------------------
ZIP="$DIST/viterm-$VERSION.zip"
echo "==> notarize app: $ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"       # .app 自体にチケットを添付(オフラインでも起動可)

# --- 5. staple 済みアプリから DMG を作る ---------------------------------
DMG="$DIST/viterm-$VERSION.dmg"
echo "==> build dmg: $DMG"
rm -f "$DMG"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/viterm.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "viterm" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

# --- 6. DMG を署名・公証・staple -----------------------------------------
echo "==> sign + notarize dmg"
codesign --force --sign "$IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

# --- 7. 検証 -------------------------------------------------------------
echo "==> verify"
spctl --assess --type execute --verbose=2 "$APP"
SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"

echo ""
echo "✅ done"
echo "   dmg    : $DMG"
echo "   sha256 : $SHA"
echo ""
echo "次のステップ:"
echo "  1. GitHub Releases に $DMG をアップロード(タグ v$VERSION)"
echo "  2. Homebrew cask (Casks/viterm.rb) の version と sha256 を更新:"
echo "       version \"$VERSION\""
echo "       sha256 \"$SHA\""
