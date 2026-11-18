#!/bin/bash
# Builds Match Downloader.app's executable from tools/Desktop.swift.
# Needs the Xcode Command Line Tools (xcode-select --install).
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
app="Match Downloader.app"
mkdir -p "$app/Contents/MacOS"
cache="$(mktemp -d)"
trap 'rm -rf "$cache"' EXIT
swiftc -O -module-cache-path "$cache" tools/Desktop.swift -o "$app/Contents/MacOS/Match Downloader"
echo "Built $app. Run Start.command once to set up Python, then open the app."
