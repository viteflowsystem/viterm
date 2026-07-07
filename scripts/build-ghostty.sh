#!/usr/bin/env bash
# Build GhosttyKit.xcframework the same way the Ghostty.app macOS build does (zig build).
# Output: vendor/ghostty/macos/GhosttyKit.xcframework
#
# Prerequisite: run scripts/fetch-ghostty.sh / scripts/setup-zig.sh first.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GHOSTTY_DIR="$ROOT_DIR/vendor/ghostty"
ZIG_VERSION="0.15.2"
ZIG_BIN="$ROOT_DIR/vendor/zig/zig-aarch64-macos-${ZIG_VERSION}/zig"

if [ ! -x "$ZIG_BIN" ]; then
  echo "error: zig not found at $ZIG_BIN (run scripts/setup-zig.sh first)" >&2
  exit 1
fi
if [ ! -d "$GHOSTTY_DIR" ]; then
  echo "error: $GHOSTTY_DIR not found (run scripts/fetch-ghostty.sh first)" >&2
  exit 1
fi

cd "$GHOSTTY_DIR"

# -Demit-macos-app=false: Ghostty.app itself is built on the Xcode side, so skip
#   the redundant app-bundle generation on the zig side (same setup as CI).
# -Dxcframework-target=native: viterm is an arm64-macOS-only app, so don't build
#   universal (incl. x86_64) / iOS / iOS Simulator slices.
run_zig_build() {
  "$ZIG_BIN" build \
    -Doptimize=ReleaseFast \
    -Demit-macos-app=false \
    -Dxcframework-target=native \
    "$@"
}

if run_zig_build "$@"; then
  echo "GhosttyKit.xcframework generated at $GHOSTTY_DIR/macos/GhosttyKit.xcframework"
  exit 0
fi

# Zig 0.15.2's self-hosted Mach-O linker can fail to parse the .tbd files of very
# new / beta macOS SDKs (the MacOSX*.sdk bundled with the Xcode.app that
# `xcode-select -p` points at), leaving libSystem symbols undefined across the
# board (reproducible even at hello-world level). The `--sysroot` flag doesn't
# help either, because it isn't applied to the "build runner" bootstrap where
# `zig build` compiles build.zig itself. Work around it by using DEVELOPER_DIR to
# switch zig's SDK auto-detection to the older, stable SDK bundled with
# CommandLineTools.
echo "warning: default zig build failed. Retrying with DEVELOPER_DIR pointed at Command Line Tools as a workaround for a Zig 0.15.2 / new macOS SDK linker incompatibility..." >&2

CLT_DIR="/Library/Developer/CommandLineTools"
if [ ! -d "$CLT_DIR/SDKs" ]; then
  echo "error: zig build failed and no fallback toolchain found at $CLT_DIR." >&2
  echo "       Install Xcode Command Line Tools (xcode-select --install) and retry." >&2
  exit 1
fi

# Command Line Tools does not ship the Metal shader compilers (metal/metallib).
# In a regular Xcode install they live in the separately downloaded "Metal
# Toolchain" component mounted as a cryptex, and once DEVELOPER_DIR is switched
# to CommandLineTools, xcrun can no longer find that toolchain
# (`xcrun -sdk macosx metal` fails with "not a developer tool or in PATH").
# Since `xcrun` also searches tools on PATH, add the metal bin directory that the
# default DEVELOPER_DIR resolves to onto PATH so both can coexist.
METAL_BIN_DIR="$(xcrun -f metal 2>/dev/null | xargs -n1 dirname || true)"
if [ -z "$METAL_BIN_DIR" ]; then
  echo "warning: could not locate the metal compiler via xcrun. Install the Metal Toolchain" >&2
  echo "         (xcodebuild -downloadComponent MetalToolchain) if the retry below fails." >&2
fi

# Conversely, xcodebuild (used by the final -create-xcframework step) does not
# work under CommandLineTools and requires a full-Xcode DEVELOPER_DIR. zig build
# looks up xcodebuild via PATH, so put a shim at the front of PATH that strips
# DEVELOPER_DIR and delegates to the real binary — compiling with the CLT SDK
# while xcodebuild uses full Xcode.
SHIM_DIR="$(mktemp -d)"
trap 'rm -rf "$SHIM_DIR"' EXIT
cat > "$SHIM_DIR/xcodebuild" <<'SHIM'
#!/bin/sh
unset DEVELOPER_DIR
exec /usr/bin/xcodebuild "$@"
SHIM
chmod +x "$SHIM_DIR/xcodebuild"

if DEVELOPER_DIR="$CLT_DIR" PATH="$SHIM_DIR:${METAL_BIN_DIR:+$METAL_BIN_DIR:}$PATH" run_zig_build "$@"; then
  echo "GhosttyKit.xcframework generated at $GHOSTTY_DIR/macos/GhosttyKit.xcframework (built with DEVELOPER_DIR=$CLT_DIR)"
  exit 0
fi

echo "error: zig build failed even with DEVELOPER_DIR=$CLT_DIR. See docs/ghostty-integration.md for known issues." >&2
exit 1
