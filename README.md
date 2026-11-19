# Match Downloader

A Mac app for saving VEX match videos to watch offline. Pick an event, pick the matches, and it downloads just those moments from the event's recording as MP4 files.

## Run it

1. Double-click **Match Downloader.app** (keep it next to `app.py` and `.venv`).
2. First time on a new Mac: install Python 3.10+ and FFmpeg, then run `Start.command` once to set up the Python environment.
3. Quit with Command-Q. Closing the window leaves the app running. Downloads in progress keep going after you quit, and the engine closes itself when they finish.

Needs macOS 26. Logs are in `library/desktop.log`. On Windows run `Start.bat`; on Linux run `python3 -m venv .venv`, `.venv/bin/pip install -r requirements.txt`, then `.venv/bin/python app.py` and open http://127.0.0.1:8766.

## Use it

1. **Pick an event.** Choose one in the sidebar, or click **+** and paste an event code (`VE-…` or `RE-…`) or event page link.
2. **Select matches.** Click rows, or search for labels like `q67`, `Q60-Q70` or `qf1-1, sf2-1`. Use the filters to narrow the schedule.
3. **Check the video.** Press Space to preview the recording at the match. If a video can't play inside the app, use **Open in Browser** to watch it at the right time.
4. **Download.** Click **Download…**. By default (Quick Download) it saves a fixed-length clip from the official match time; one slider with two thumbs moves the clip's start and end (drag either thumb; the thin mark is the official match start). Turn Quick Download off and the app searches for the match's start and end instead.
5. **Watch and adjust.** Open **Downloads** in the sidebar and press Space to play. Anything marked *Needs review* lets you adjust the start and end by hand. For a saved video, **Adjust Length…** (right-click, or the inspector) trims it on this Mac or extends it before or after by downloading the extra footage.

Other things you can do:
- **Worlds** has its own folder in the sidebar (for example *Worlds 26*) with each program's event. Video positions come from the vexworlds.tv BoxCast channels. Right-click a program to open its channel on vexworlds.tv.
- **Clip from Link** (File menu) saves a clip from any recording link.
- **Recordings** (inspector) lets you add your own YouTube, Vimeo, BoxCast or MP4 link if the app didn't find one, or if an event has several.
- **Archive or remove an event** (right-click or swipe it in the sidebar). Archive moves it to an Archived list and keeps everything. Remove deletes its saved schedule and recordings from this Mac; downloaded matches stay.
- **Change the livestream.** With no match selected, the event panel lists the video found for each day. **Change…** replaces it with a recording you choose; **Use Automatic** goes back.
- **Shift all matches.** If every match in an event is early or late by the same amount, drag **Shift All Matches** (under Livestream in the event panel, up to 5 minutes either way; the arrows nudge by a second). Positions you set yourself don't move.
- **Set Video Position…** (right-click a match) fixes a match that is out of sync.

## Good to know

- Schedules you've opened stay on your Mac and work offline. Loading events, previewing and downloading need internet.
- **Settings** (the gear in the sidebar, or Command-comma) holds the set-once choices: downloads at once (1 to 4; `MATCH_DOWNLOADER_PARALLEL` still overrides it), download defaults such as clip length and lead-in, updating the event catalogue (it also updates itself once a day), and an Advanced tab with a shift for every download, the log and the older web version.
- Saved videos are in `library/`. Back up that whole folder. Set `MATCH_DOWNLOADER_DATA` to move it.
- Video positions are estimates. Preview a match before downloading.
- No logins, DRM or paywalled videos. Only download recordings you're allowed to.
- The app only listens on your own Mac (127.0.0.1).

## Next Worlds

The Worlds folder is set by `worlds-season.json` (year and folder name), with each year's events and channels in `worlds.json`. There is no setting for it in the app. To move to a new Worlds, once its events are on RobotEvents:

```
python3 tools/new_worlds_season.py 2027 "Worlds 27"
```

It looks up the events, copies last year's channels, writes both files, and tells you if a channel or division needs a manual fix. Restart the app afterwards.

## Build and test

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer mac/scripts/build-app.sh
python3 -m unittest discover -s tests -v
```

The app source is in `mac/` (Xcode 26, Swift 6). Test against a copy of the library on another port with `--data` and `--port`, never two engines on one library. Settings → Advanced → Open Web Version in Browser opens the older web version.

## License

GNU AGPL v3. See `LICENSE` and `NOTICE.md` for OpenScout data attribution.
