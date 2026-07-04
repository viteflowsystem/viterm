#!/usr/bin/env bash
# GhosttyKit.xcframework を Ghostty.app macOS 版と同じ方法(zig build)で生成する。
# 出力先: vendor/ghostty/macos/GhosttyKit.xcframework
#
# 前提: scripts/fetch-ghostty.sh / scripts/setup-zig.sh を先に実行しておくこと。
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

# -Demit-macos-app=false: Xcode 側で Ghostty.app 本体をビルドするので、
#   zig 側で重複するアプリバンドル生成はスキップする(CI と同じ構成)。
# -Dxcframework-target=native: vitea は arm64 macOS 専用アプリなので、
#   universal(x86_64含む)/iOS/iOS Simulator スライスは作らない。
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

# Zig 0.15.2 のセルフホストMach-Oリンカは、非常に新しい/beta版の macOS SDK
# (`xcode-select -p` が指す Xcode.app 付属の MacOSX*.sdk)の .tbd を正しく解釈
# できず、libSystem のシンボルが軒並み undefined symbol になることがある
# (hello world レベルでも再現する)。しかも `--sysroot` フラグは `zig build` が
# 内部で build.zig 自体をコンパイルする「ビルドランナー」のブートストラップには
# 適用されないため効果がない。DEVELOPER_DIR で zig の SDK 自動検出先そのものを
# CommandLineTools 同梱の枯れたバージョンの SDK に切り替えることで回避する。
echo "warning: default zig build failed. Retrying with DEVELOPER_DIR pointed at Command Line Tools as a workaround for a Zig 0.15.2 / new macOS SDK linker incompatibility..." >&2

CLT_DIR="/Library/Developer/CommandLineTools"
if [ ! -d "$CLT_DIR/SDKs" ]; then
  echo "error: zig build failed and no fallback toolchain found at $CLT_DIR." >&2
  echo "       Install Xcode Command Line Tools (xcode-select --install) and retry." >&2
  exit 1
fi

# Command Line Tools には Metal シェーダコンパイラ(metal/metallib)が同梱されて
# いない。これらは通常の Xcode インストールでは別ダウンロードの "Metal
# Toolchain" コンポーネントとして cryptex にマウントされており、DEVELOPER_DIR を
# CommandLineTools に切り替えると xcrun がそのツールチェーンを見つけられなくなる
# (`xcrun -sdk macosx metal` が "not a developer tool or in PATH" で失敗する)。
# `xcrun` は PATH 上のツールも探すため、デフォルトの DEVELOPER_DIR で解決できる
# metal の bin ディレクトリを PATH に足しておくことで両立させる。
METAL_BIN_DIR="$(xcrun -f metal 2>/dev/null | xargs -n1 dirname || true)"
if [ -z "$METAL_BIN_DIR" ]; then
  echo "warning: could not locate the metal compiler via xcrun. Install the Metal Toolchain" >&2
  echo "         (xcodebuild -downloadComponent MetalToolchain) if the retry below fails." >&2
fi

# 逆に xcodebuild(最終ステップの -create-xcframework が使う)は CommandLineTools
# では動かず、フル Xcode の DEVELOPER_DIR を要求する。zig build は PATH から
# xcodebuild を探すので、DEVELOPER_DIR を剥がして本物に委譲するシムを PATH の
# 先頭に置き、コンパイル=CLT SDK / xcodebuild=フル Xcode を両立させる。
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
