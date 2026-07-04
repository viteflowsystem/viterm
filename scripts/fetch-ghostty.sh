#!/usr/bin/env bash
# vendor/ghostty を scripts/ghostty-commit に記録された固定コミットで取得・更新する。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/vendor/ghostty"
REPO_URL="https://github.com/ghostty-org/ghostty.git"
COMMIT="$(tr -d '[:space:]' < "$ROOT_DIR/scripts/ghostty-commit")"

if [ -d "$VENDOR_DIR/.git" ]; then
  current="$(git -C "$VENDOR_DIR" rev-parse HEAD)"
  if [ "$current" = "$COMMIT" ]; then
    echo "vendor/ghostty is already pinned at $COMMIT"
    exit 0
  fi
  echo "Updating vendor/ghostty: $current -> $COMMIT"
  git -C "$VENDOR_DIR" fetch --depth 1 origin "$COMMIT"
  git -C "$VENDOR_DIR" checkout --detach "$COMMIT"
else
  echo "Cloning ghostty ($COMMIT) into $VENDOR_DIR"
  rm -rf "$VENDOR_DIR"
  mkdir -p "$VENDOR_DIR"
  git -C "$VENDOR_DIR" init -q
  git -C "$VENDOR_DIR" remote add origin "$REPO_URL"
  git -C "$VENDOR_DIR" fetch --depth 1 origin "$COMMIT"
  git -C "$VENDOR_DIR" checkout --detach FETCH_HEAD
fi

resolved="$(git -C "$VENDOR_DIR" rev-parse HEAD)"
if [ "$resolved" != "$COMMIT" ]; then
  echo "error: vendor/ghostty HEAD ($resolved) does not match pinned commit ($COMMIT)" >&2
  exit 1
fi

# vitea 用のローカルパッチを適用する(冪等: 適用済みならスキップ)。
# 例: 0001-xcframework-native-only.patch — native 指定時に iOS/universal
#     バリアントのビルドをスキップする(CommandLineTools には iOS SDK が無いため)。
for patch in "$ROOT_DIR"/scripts/patches/*.patch; do
  [ -e "$patch" ] || continue
  if git -C "$VENDOR_DIR" apply --check "$patch" 2>/dev/null; then
    git -C "$VENDOR_DIR" apply "$patch"
    echo "applied patch: $(basename "$patch")"
  elif git -C "$VENDOR_DIR" apply --check --reverse "$patch" 2>/dev/null; then
    echo "patch already applied: $(basename "$patch")"
  else
    echo "error: patch does not apply cleanly: $(basename "$patch")" >&2
    exit 1
  fi
done

echo "vendor/ghostty pinned at $resolved"
