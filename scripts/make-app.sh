#!/bin/sh
# Assemble the viterm.app bundle so it can be launched directly with `open`.
#
# Usage: scripts/make-app.sh [release|debug]  (default: release)
#
# By default this builds the "viterm Dev" flavor, so local builds are
# distinguishable from the brew-installed release:
#   - Output: .build/viterm-dev.app
#   - Bundle ID com.viteflowsystem.viterm.dev / display name "viterm Dev" / DEV-badged icon
# For the plain distribution viterm.app, pass VARIANT=dist (used by release.sh):
#   VARIANT=dist scripts/make-app.sh release  → .build/viterm.app
#
# Bundle layout:
#   Contents/MacOS/VitermApp   … executable from `swift build`
#   Contents/Info.plist       … copy of Resources/Info.plist
#   Contents/Frameworks/      … TODO(blocked on T3): if GhosttyKit ships an
#                                 xcframework/dylib, copy the build products from
#                                 `vendor/ghostty` here (currently just an empty dir)
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

# Copy the SPM resource bundles (Bundle.module lookups fail without them) and
# compile the string catalogs: Foundation does not parse raw .xcstrings at
# runtime, so turn them into {en,ja}.lproj/Localizable.strings.
for BUNDLE in "$BIN_PATH"/viterm_*.bundle; do
    [ -d "$BUNDLE" ] || continue
    DEST="$CONTENTS_DIR/Resources/$(basename "$BUNDLE")"
    cp -R "$BUNDLE" "$DEST"
    for CATALOG in "$DEST"/*.xcstrings; do
        [ -f "$CATALOG" ] || continue
        xcrun xcstringstool compile "$CATALOG" --output-directory "$DEST"
        rm "$CATALOG"
    done
done

if [ "$VARIANT" = "dist" ]; then
    cp "$REPO_ROOT/Resources/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
else
    # Dev flavor: separate bundle ID, display name, DEV-badged icon, and a git SHA version
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
