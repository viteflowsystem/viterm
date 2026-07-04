#!/usr/bin/env bash
# vendor/ghostty (build.zig.zon の minimum_zig_version) が要求する Zig を
# ziglang.org の tarball から vendor/zig/ に展開する。brew の zig は
# バージョン不一致のリスクがあるため使わない。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIG_VERSION="0.15.2"
ZIG_DIR="$ROOT_DIR/vendor/zig"
ARCHIVE_BASENAME="zig-aarch64-macos-${ZIG_VERSION}"
TARBALL_URL="https://ziglang.org/download/${ZIG_VERSION}/${ARCHIVE_BASENAME}.tar.xz"
# https://ziglang.org/download/index.json より取得
EXPECTED_SHA256="3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b"

INSTALL_DIR="$ZIG_DIR/$ARCHIVE_BASENAME"
if [ -x "$INSTALL_DIR/zig" ]; then
  echo "zig ${ZIG_VERSION} already installed at $INSTALL_DIR"
  "$INSTALL_DIR/zig" version
  exit 0
fi

if [ "$(uname -m)" != "arm64" ]; then
  echo "error: this script only fetches the macOS aarch64 zig build (host is $(uname -m))" >&2
  exit 1
fi

mkdir -p "$ZIG_DIR"
tmp_tarball="$(mktemp -t zig-download).tar.xz"
trap 'rm -f "$tmp_tarball"' EXIT

echo "Downloading zig ${ZIG_VERSION} (aarch64-macos)..."
wget -q "$TARBALL_URL" -O "$tmp_tarball"

echo "Verifying checksum..."
actual_sha256="$(shasum -a 256 "$tmp_tarball" | awk '{print $1}')"
if [ "$actual_sha256" != "$EXPECTED_SHA256" ]; then
  echo "error: checksum mismatch (expected $EXPECTED_SHA256, got $actual_sha256)" >&2
  exit 1
fi

echo "Extracting to $ZIG_DIR..."
tar -xJf "$tmp_tarball" -C "$ZIG_DIR"

echo "zig ${ZIG_VERSION} installed at $INSTALL_DIR"
"$INSTALL_DIR/zig" version
