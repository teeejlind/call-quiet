#!/bin/bash
# Builds the helpers and copies the Spoon into ~/.hammerspoon/Spoons.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
"$root/scripts/build.sh"
dest="$HOME/.hammerspoon/Spoons"
mkdir -p "$dest"
rm -rf "$dest/CallQuiet.spoon"
cp -R "$root/CallQuiet.spoon" "$dest/"
echo "installed to $dest/CallQuiet.spoon"
