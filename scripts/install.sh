#!/bin/bash
# Installs (or updates) Half-Frame Splitter for Lightroom Classic on macOS.
#
#   bash scripts/install.sh
#
# Copies HalfFrameSplitter.lrplugin into Lightroom's own plug-in folder,
# which Lightroom loads automatically on start and which Lightroom updates
# never touch. Running it again replaces the old version with this one;
# your settings and all virtual copies already made are kept.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/HalfFrameSplitter.lrplugin"
DEST_DIR="$HOME/Library/Application Support/Adobe/Lightroom/Modules"
DEST="$DEST_DIR/HalfFrameSplitter.lrplugin"

if [ ! -f "$SRC/Info.lua" ]; then
	echo "Cannot find the plug-in at: $SRC" >&2
	exit 1
fi

mkdir -p "$DEST_DIR"
if [ -d "$DEST" ]; then
	echo "Updating the existing plug-in in: $DEST"
	rm -rf "$DEST"
else
	echo "Installing the plug-in into: $DEST"
fi
cp -R "$SRC" "$DEST"
# Files downloaded with a browser carry a quarantine flag; Lightroom does not
# need it and removing it avoids any macOS prompts.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo
echo "Done. Restart Lightroom Classic, then use:"
echo "  Library > Plug-in Extras > Split Half-Frame Pairs..."
