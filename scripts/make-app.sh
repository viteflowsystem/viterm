#!/bin/sh
# viterm.app バンドルを組み立てて、そのまま `open` で起動できる状態にする。
#
# 使い方: scripts/make-app.sh [release|debug]  (既定: release)
#
# 生成物: .build/viterm.app (git 管理外、.build/ は .gitignore 対象)
#   Contents/MacOS/VitermApp   … `swift build` の実行バイナリ
#   Contents/Info.plist       … Resources/Info.plist のコピー
#   Contents/Frameworks/      … TODO(T3待ち): GhosttyKit が xcframework/dylib を含む場合、
#                                 ここに `vendor/ghostty` のビルド成果物をコピーする
#                                 (現時点ではディレクトリを用意するだけで中身は空)
set -eu

CONFIGURATION="${1:-release}"

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

APP_BUNDLE="$REPO_ROOT/.build/viterm.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"

echo "==> assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR"
mkdir -p "$FRAMEWORKS_DIR"

cp "$EXECUTABLE" "$MACOS_DIR/VitermApp"
cp "$REPO_ROOT/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"

echo "==> codesign --force --sign - $APP_BUNDLE"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> done: $APP_BUNDLE"
echo "    open \"$APP_BUNDLE\""
