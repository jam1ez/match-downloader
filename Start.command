#!/bin/bash
cd -- "$(dirname -- "$0")" || exit 1
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if ! command -v python3 >/dev/null; then echo 'Install Python 3 from python.org, then reopen this file.'; read -r; exit 1; fi
if [ ! -x .venv/bin/python ]; then python3 -m venv .venv || exit 1; fi
if ! .venv/bin/python -c 'import yt_dlp, yt_dlp_ejs' 2>/dev/null; then .venv/bin/python -m pip install -r requirements.txt || { read -r; exit 1; }; fi
if ! command -v ffmpeg >/dev/null; then echo 'FFmpeg is required. Install Homebrew, then run: brew install ffmpeg'; read -r; exit 1; fi
.venv/bin/python app.py
read -r
