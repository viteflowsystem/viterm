#!/usr/bin/env bash
# viterm release build: Developer ID signing → notarization → staple → DMG → verify.
#
# Usage:
#   scripts/release.sh <version>          # e.g. scripts/release.sh 0.1.0
#
# Prerequisites (one-time):
#   1. A Developer ID Application certificate is in the keychain
#      (check with: security find-identity -v -p codesigning)
#   2. A notarization profile is registered:
#      xcrun notarytool store-credentials viteflow-notary \
#        --key <AuthKey_XXX.p8> --key-id <KeyID> --issuer <IssuerID>
#   See docs/RELEASE.md for details.
#
# Overridable via environment variables:
#   NOTARY_PROFILE  notarization profile name (default: viteflow-notary)
#   SIGN_IDENTITY   SHA-1 of the signing identity (default: auto-select the first Developer ID Application)
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version>  (例: 0.1.0)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-viteflow-notary}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/viterm.app"
DIST="$ROOT/.build/dist"
ENTITLEMENTS="$ROOT/Resources/viterm.entitlements"

# --- Signing identity ------------------------------------------------------
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | awk '/Developer ID Application/{print $2; exit}')}"
if [ -z "$IDENTITY" ]; then
  echo "error: Developer ID Application の署名IDが見つかりません。" >&2
  echo "       Xcode で証明書を作成するか、キーチェーンに .p12 を取り込んでください。" >&2
  exit 1
fi
echo "==> signing identity: $IDENTITY"

# --- Check that the notarization profile exists ----------------------------
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "error: 公証プロファイル '$NOTARY_PROFILE' が未登録です。docs/RELEASE.md を参照。" >&2
  exit 1
fi

# --- 1. Assemble the app bundle (ad-hoc signed at this point) --------------
VARIANT=dist "$ROOT/scripts/make-app.sh" release

# --- 2. Write the version into Info.plist ----------------------------------
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"

# --- 3. Real signing with Developer ID + Hardened Runtime ------------------
echo "==> codesign (Developer ID, hardened runtime)"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

mkdir -p "$DIST"

# --- 4. Notarize the app (submitted as zip) and staple ---------------------
ZIP="$DIST/viterm-$VERSION.zip"
echo "==> notarize app: $ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"       # Attach the ticket to the .app itself (launches offline too)

# --- 5. Build the DMG from the stapled app ---------------------------------
DMG="$DIST/viterm-$VERSION.dmg"
echo "==> build dmg: $DMG"
rm -f "$DMG"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/viterm.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "viterm" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

# --- 6. Sign, notarize, and staple the DMG ---------------------------------
echo "==> sign + notarize dmg"
codesign --force --sign "$IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

# --- 7. Verify --------------------------------------------------------------
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
