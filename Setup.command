#!/bin/bash
# First-time setup on a new Mac: double-click this once, then open Match Downloader.app.
cd -- "$(dirname -- "$0")" || exit 1
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
fail() { echo; echo "$1"; echo; echo "Press Return to close."; read -r; exit 1; }

echo "Setting up Match Downloader in: $PWD"
echo

# A downloaded copy is quarantined, and macOS runs a quarantined app from a hidden temporary
# folder where it can't find app.py beside it. Clear it for this folder only.
xattr -dr com.apple.quarantine . 2>/dev/null || true

command -v python3 >/dev/null || fail "Python 3 is missing. Install it from python.org, then double-click Setup.command again."
python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' || fail "Python 3.10 or later is needed. Install it from python.org, then double-click Setup.command again."
if [ ! -x .venv/bin/python ]; then
    echo "Creating the Python environment…"
    python3 -m venv .venv || fail "Couldn't create the Python environment (.venv)."
fi
echo "Installing yt-dlp…"
.venv/bin/python -m pip install --quiet --upgrade pip >/dev/null 2>&1
.venv/bin/python -m pip install --quiet -r requirements.txt || fail "Couldn't install the Python packages. Check your internet connection and try again."

missing=0
if ! command -v ffmpeg >/dev/null; then
    missing=1
    echo
    echo "FFmpeg is required to save videos. Install Homebrew (brew.sh), then run:"
    echo "    brew install ffmpeg"
fi
if ! command -v node >/dev/null && ! command -v deno >/dev/null; then
    echo
    echo "Recommended: YouTube downloads need a JavaScript runtime. Run:"
    echo "    brew install node"
fi
if ! command -v swiftc >/dev/null; then
    echo
    echo "Optional: \"Find Start and End\" reads the match timer and needs Apple's command line tools. Run:"
    echo "    xcode-select --install"
    echo "Quick Download works without them."
fi

echo
if [ "$missing" = 1 ]; then
    echo "Almost done. Install FFmpeg as shown above, then open Match Downloader.app."
else
    echo "Done. Open Match Downloader.app (keep it in this folder)."
fi
echo
echo "Press Return to close."
read -r
