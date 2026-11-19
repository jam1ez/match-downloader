#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# Native cutover: preserve the previous bundle and install only after signing succeeds.
DEST="${1:-$ROOT/Match Downloader.app}"
mkdir -p "$ROOT/mac/.build"
STAGE="$(mktemp -d "$ROOT/mac/.build/bundle.XXXXXX")"
BUNDLE="$STAGE/Match Downloader.app"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "${TMPDIR:-/tmp}/match-downloader-swift-cache"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/match-downloader-swift-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift build --package-path "$ROOT/mac" --disable-sandbox --cache-path "$CLANG_MODULE_CACHE_PATH/spm" -c release
BIN="$(swift build --package-path "$ROOT/mac" --disable-sandbox --cache-path "$CLANG_MODULE_CACHE_PATH/spm" -c release --show-bin-path)"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN/MatchDownloader" "$BUNDLE/Contents/MacOS/Match Downloader"
cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.matchdownloader.app</string>
<key>CFBundleName</key><string>Match Downloader</string>
<key>CFBundleDisplayName</key><string>Match Downloader</string>
<key>CFBundleExecutable</key><string>Match Downloader</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIconName</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
# Liquid Glass icon: compile the Icon Composer file (layers in AppIcon.icon/Assets, drawn by make-icon.swift)
# into Assets.car, plus AppIcon.icns for anything that still reads the old format.
xcrun actool "$ROOT/mac/Resources/AppIcon.icon" --compile "$BUNDLE/Contents/Resources" --platform macosx \
    --minimum-deployment-target 26.0 --app-icon AppIcon --output-partial-info-plist "$STAGE/icon.plist" >/dev/null
xattr -cr "$BUNDLE"
codesign --force --sign - "$BUNDLE"
codesign --verify --strict "$BUNDLE"
mkdir -p "$(dirname "$DEST")"
if [[ -e "$DEST" ]]; then
    BACKUP="$ROOT/mac/.build/previous-bundle-$(date +%s)"
    mkdir -p "$BACKUP"
    mv "$DEST" "$BACKUP/Match Downloader.app"
fi
mv "$BUNDLE" "$DEST"
# File-provider metadata may be attached when moving into Documents.
xattr -cr "$DEST"
VERIFIED=0
for ATTEMPT in 1 2 3; do
    xattr -d com.apple.FinderInfo "$DEST" 2>/dev/null || true
    if codesign --verify --strict "$DEST"; then VERIFIED=1; break; fi
done
[[ "$VERIFIED" == 1 ]]
printf 'Built %s\n' "$DEST"
