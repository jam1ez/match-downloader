#!/bin/bash
# Builds a release zip for GitHub: the universal app plus everything it runs, in one folder.
#   mac/scripts/package-release.sh 1.0.0
# Writes dist/Match-Downloader-<version>.zip from the committed tree (uncommitted changes are left out).
set -euo pipefail
VERSION="${1:?Give a version, for example: mac/scripts/package-release.sh 1.0.0}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
NAME="Match Downloader"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/match-downloader-release.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
OUT="$ROOT/dist/Match-Downloader-$VERSION.zip"

# Everything committed, so the zip matches the tag.
mkdir -p "$STAGE/$NAME"
git -C "$ROOT" archive HEAD | tar -x -C "$STAGE/$NAME"
# The app, built for Apple silicon and Intel, with this version in About.
MATCH_DOWNLOADER_VERSION="$VERSION" UNIVERSAL=1 "$ROOT/mac/scripts/build-app.sh" "$STAGE/$NAME/$NAME.app"
chmod +x "$STAGE/$NAME/Setup.command" "$STAGE/$NAME/Start.command"

mkdir -p "$ROOT/dist"
rm -f "$OUT"
# ditto keeps the app bundle's structure and signature intact.
ditto -c -k --keepParent "$STAGE/$NAME" "$OUT"
printf 'Packaged %s\n' "$OUT"
shasum -a 256 "$OUT"
