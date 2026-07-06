#!/usr/bin/env bash
# Generates GhosttyKit.xcframework the same way the macOS Ghostty.app does (zig build).
# Output: vendor/ghostty/macos/GhosttyKit.xcframework
#
# Prerequisites: run scripts/fetch-ghostty.sh / scripts/setup-zig.sh first.
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

# -Demit-macos-app=false: Xcode builds the Ghostty.app itself, so skip the
#   duplicate app-bundle generation on the zig side (same configuration as CI).
# -Dxcframework-target=native: viterm is an arm64 macOS-only app, so do not
#   build universal (incl. x86_64) / iOS / iOS Simulator slices.
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

# Zig 0.15.2's self-hosted Mach-O linker can fail to correctly interpret the .tbd
# files of very new / beta macOS SDKs (the MacOSX*.sdk bundled with the Xcode.app
# that `xcode-select -p` points to), leaving libSystem symbols undefined across
# the board (reproducible even at hello-world level). Moreover, the `--sysroot`
# flag has no effect because it is not applied to the bootstrap of the "build
# runner" that `zig build` uses internally to compile build.zig itself. Work
# around this by using DEVELOPER_DIR to switch zig's SDK auto-detection target
# itself to the mature SDK version bundled with CommandLineTools.
echo "warning: default zig build failed. Retrying with DEVELOPER_DIR pointed at Command Line Tools as a workaround for a Zig 0.15.2 / new macOS SDK linker incompatibility..." >&2

CLT_DIR="/Library/Developer/CommandLineTools"
if [ ! -d "$CLT_DIR/SDKs" ]; then
  echo "error: zig build failed and no fallback toolchain found at $CLT_DIR." >&2
  echo "       Install Xcode Command Line Tools (xcode-select --install) and retry." >&2
  exit 1
fi

# Command Line Tools does not ship the Metal shader compilers (metal/metallib).
# In a normal Xcode install these come as the separately downloaded "Metal
# Toolchain" component mounted as a cryptex, and switching DEVELOPER_DIR to
# CommandLineTools makes xcrun unable to find that toolchain
# (`xcrun -sdk macosx metal` fails with "not a developer tool or in PATH").
# Since `xcrun` also searches tools on PATH, we reconcile the two by adding the
# metal bin directory resolvable under the default DEVELOPER_DIR to PATH.
METAL_BIN_DIR="$(xcrun -f metal 2>/dev/null | xargs -n1 dirname || true)"
if [ -z "$METAL_BIN_DIR" ]; then
  echo "warning: could not locate the metal compiler via xcrun. Install the Metal Toolchain" >&2
  echo "         (xcodebuild -downloadComponent MetalToolchain) if the retry below fails." >&2
fi

# Conversely, xcodebuild (used by the final -create-xcframework step) does not
# work under CommandLineTools and requires a full-Xcode DEVELOPER_DIR. zig build
# looks up xcodebuild on PATH, so we prepend a shim that strips DEVELOPER_DIR and
# delegates to the real one, combining compilation=CLT SDK / xcodebuild=full Xcode.
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
