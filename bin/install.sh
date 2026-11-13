#!/bin/bash
# Installs the latest Glint release into ~/Applications and opens it.
# While the repo is private it falls back to the GitHub CLI for the download.
set -euo pipefail

REPO="barkimchi/glint-app"
DEST="$HOME/Applications"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ "$(uname)" = "Darwin" ] || { echo "Glint is a macOS app."; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The release tag and its checksum are pinned in this repo at publish time, so the
# installer script, the expected checksum and the asset all come from one immutable
# source. Root of trust: this repository, fetched over HTTPS. This catches a release
# asset that doesn't match what the repo published; it is not publisher identity.
TAG="$(tr -d '[:space:]' < "$SCRIPT_DIR/RELEASE")"
PINNED="$(tr -d '[:space:]' < "$SCRIPT_DIR/SHA256")"

echo "Downloading Glint $TAG…"
if ! curl -fsSL "https://github.com/$REPO/releases/download/$TAG/Glint.zip" -o "$TMP/Glint.zip" 2>/dev/null; then
  # Private repo: fall back to the GitHub CLI, which carries your sign-in.
  command -v gh >/dev/null || { echo "Download failed. If the repo is private, install the GitHub CLI and run: gh auth login"; exit 1; }
  gh release download "$TAG" --repo "$REPO" --pattern "Glint.zip" --dir "$TMP" --clobber
fi
ACTUAL="$(shasum -a 256 "$TMP/Glint.zip" | awk '{print $1}')"
if [ "$ACTUAL" != "$PINNED" ]; then
  echo "Checksum mismatch: the download does not match the release pinned in the repo." >&2
  echo "If a release was published in the last few minutes, wait a moment and try again." >&2
  exit 1
fi

ditto -x -k "$TMP/Glint.zip" "$TMP/app"
[ -d "$TMP/app/Glint.app" ] || { echo "Download did not contain Glint.app"; exit 1; }

pkill -x Glint 2>/dev/null || true
mkdir -p "$DEST"
rm -rf "$DEST/Glint.app"
ditto "$TMP/app/Glint.app" "$DEST/Glint.app"
open "$DEST/Glint.app"

VERSION="$(defaults read "$DEST/Glint.app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")"
echo "Glint $VERSION installed in $DEST. Look for the glint in the menu bar."
