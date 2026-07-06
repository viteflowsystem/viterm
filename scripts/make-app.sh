#!/bin/sh
# viterm.app バンドルを組み立てて、そのまま `open` で起動できる状態にする。
#
# 使い方: scripts/make-app.sh [release|debug]  (既定: release)
#
# 既定では開発フレーバー「viterm Dev」を組む(brew 版と見分けるため):
#   - 生成物: .build/viterm-dev.app
#   - Bundle ID: com.viteflowsystem.viterm.dev / 表示名: viterm Dev / DEV バッジ付きアイコン
# 配布用の素の viterm.app が欲しいときは VARIANT=dist(release.sh が使う):
#   VARIANT=dist scripts/make-app.sh release  → .build/viterm.app
#   Contents/MacOS/VitermApp   … `swift build` の実行バイナリ
#   Contents/Info.plist       … Resources/Info.plist のコピー
#   Contents/Frameworks/      … TODO(T3待ち): GhosttyKit が xcframework/dylib を含む場合、
#                                 ここに `vendor/ghostty` のビルド成果物をコピーする
#                                 (現時点ではディレクトリを用意するだけで中身は空)
set -eu

CONFIGURATION="${1:-release}"
VARIANT="${VARIANT:-dev}"   # dev | dist

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "==> swift build -c $CONFIGURATION"
swift build --package-path "$REPO_ROOT" -c "$CONFIGURATION"

BIN_PATH="$(swift build --package-path "$REPO_ROOT" -c "$CONFIGURATION" --show-bin-path)"
EXECUTABLE="$BIN_PATH/VitermApp"

if [ ! -x "$EXECUTABLE" ]; then
    echo "error: VitermApp executable not found at $EXECUTABLE" >&2
    exit 1
fi

if [ "$VARIANT" = "dist" ]; then
    APP_BUNDLE="$REPO_ROOT/.build/viterm.app"
else
    APP_BUNDLE="$REPO_ROOT/.build/viterm-dev.app"
fi
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"

echo "==> assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR"
mkdir -p "$FRAMEWORKS_DIR"

cp "$EXECUTABLE" "$MACOS_DIR/VitermApp"
cp "$REPO_ROOT/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
mkdir -p "$CONTENTS_DIR/Resources"

if [ "$VARIANT" = "dist" ]; then
    cp "$REPO_ROOT/Resources/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
else
    # 開発フレーバー: 別 Bundle ID・別表示名・DEV バッジアイコン・git SHA 入りバージョン
    GIT_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    PLIST="$CONTENTS_DIR/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.viteflowsystem.viterm.dev" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName viterm Dev" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName viterm Dev" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.0.0-dev.$GIT_SHA" "$PLIST"
    cp "$REPO_ROOT/Resources/AppIcon-Dev.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
fi

echo "==> codesign --force --sign - $APP_BUNDLE"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> done: $APP_BUNDLE"
echo "    open \"$APP_BUNDLE\""
