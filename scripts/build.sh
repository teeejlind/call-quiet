#!/bin/bash
# Builds the mic-users and app-mute helpers into CallQuiet.spoon/bin.
# Needs the Xcode Command Line Tools (xcode-select --install). macOS 14.2+.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$root/CallQuiet.spoon/bin}"
mkdir -p "$out"
for name in mic-users app-mute; do
  echo "building $name"
  swiftc -O -swift-version 5 "$root/helpers/$name.swift" -o "$out/$name"
done
echo "done: $out"
