#!/bin/bash
# Installs the latest Glint release into ~/Applications and opens it.
# While the repo is private it falls back to the GitHub CLI for the download.
set -euo pipefail

REPO="barkimchi/glint-app"
DEST="$HOME/Applications"

[ "$(uname)" = "Darwin" ] || { echo "Glint is a macOS app."; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading Glint…"
if ! curl -fsSL "https://github.com/$REPO/releases/latest/download/Glint.zip" -o "$TMP/Glint.zip" 2>/dev/null; then
  # Private repo: fall back to the GitHub CLI, which carries your sign-in.
  command -v gh >/dev/null || { echo "Download failed. If the repo is private, install the GitHub CLI and run: gh auth login"; exit 1; }
  gh release download --repo "$REPO" --pattern "Glint.zip" --dir "$TMP" --clobber
fi
ditto -x -k "$TMP/Glint.zip" "$TMP/app"
[ -d "$TMP/app/Glint.app" ] || { echo "Download did not contain Glint.app"; exit 1; }

pkill -x Glint 2>/dev/null || true
mkdir -p "$DEST"
rm -rf "$DEST/Glint.app"
ditto "$TMP/app/Glint.app" "$DEST/Glint.app"
xattr -dr com.apple.quarantine "$DEST/Glint.app" 2>/dev/null || true
open "$DEST/Glint.app"

VERSION="$(defaults read "$DEST/Glint.app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")"
echo "Glint $VERSION installed in $DEST. Look for the glint in the menu bar."
