#!/usr/bin/env bash
# Fetches/updates vendor/ghostty at the pinned commit recorded in scripts/ghostty-commit.
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

# Apply viterm-specific local patches (idempotent: skipped if already applied).
# Example: 0001-xcframework-native-only.patch — skips building the iOS/universal
#     variants when native is specified (CommandLineTools has no iOS SDK).
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
