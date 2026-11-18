# Match Downloader: redesign prototype

> The later macOS 27 (Liquid Glass) interface is now the app's default at `/`, and the app is called Match Downloader. See [mac/README.md](mac/README.md). This first redesign remains at `/next`, and the original interface at `/classic`.

A separate, working redesign of the ScoutVault interface under a plain name, **Match Downloader**. The original UI (`web/index.html`) is unchanged and still served at `/`. The prototype lives in `web/next/` and is served at `/next` by the same local server, so both use the same library, queue and event data.

## Run it

1. Start the app as usual: open **Match Downloader.app**, run `Start.command`, or run `.venv/bin/python app.py`.
2. This first redesign stays available at `/next`.
3. Open **http://127.0.0.1:8766/next** in a browser. The original interface is at http://127.0.0.1:8766/classic.

Deep links work, for example `/next#/matches/RE-V5RC-25-0147`, `/next#/library` and `/next#/clip`. To try it without touching your real library, run a second copy on another folder:

```bash
MATCH_DOWNLOADER_DATA=/tmp/md-test .venv/bin/python app.py --port 8799 --no-browser
```

Do not run two servers on the same library folder: each would run its own download queue.

## Audit of the original UI

**Workflow and hierarchy (high impact)**
- On a 1440×900 screen the match schedule is not visible after choosing an event. A marketing hero ("Great matches. Anywhere."), a tagline, tabs and an open "Recordings & sync" panel listing raw URLs fill the first screen (`before-2-event.png`).
- Download settings and the Download button sit below the whole table: about 2,500 px down with 22 matches selected (`before-3-selected-full.png`). Selecting and downloading, the core task, needs long scrolling and loses sight of the selection.
- Every primary action uses the same full-width lime button (Add event, Download, Save, Add to queue), so nothing stands out. Secondary actions are identical grey pills.
- Library entries are 230 px cards, so three fit on a screen. Each repeats the full event name and a generated `SKU · Division · Teams… · Jumper · blue: 43 / red: 32` string (`before-4-library.png`).
- On a phone the first full screen is branding and the event finder. The schedule starts several screens down (`before-6-mobile.png`).

**Visual language**
- Near-black background with one acid-green accent, uppercase tracked table headers and taglines, and dot-joined meta strings everywhere: common generated-UI defaults that say nothing about VEX scouting.
- Red/blue alliance text with scores appended after a dot. The winner isn't distinguishable at a glance, and red and blue lines are stacked in one column.
- Internal names reach the user: "Jumper", "Needs sync or another recording", "Stream sync", "Detect from VEX Events".

**Interaction and accessibility**
- No visible keyboard focus style. Notes, delete confirmation and errors use `prompt()`, `confirm()` and `alert()`.
- The library re-renders every 2.5 s whether or not anything changed.
- Dead UI: the "Link a division recording" dialog has no way to open it. The "Link a recording" button opens the recording editor instead.
- Dark mode only. Light rooms and projectors at events were not considered.

**Frontend architecture**
- One 108-line HTML file holding about 60 KB, with three `<style>` blocks that override each other (`.hidden` and the media queries are defined twice) and all JavaScript on long single lines.
- State is global and views are toggled by hiding sibling sections, with no URL state, so refresh or back loses the current view.
- The stack itself (a no-build static page, an ES module, the local JSON API) is a good fit for an offline single-user tool and is kept.

## What the prototype changes

- **Layout.** App-shell layout: header, an event list on the left, and the schedule on the right. The schedule scrolls inside its own pane, so filters stay above it and the **download tray stays visible below it**. Recordings moved to a side sheet opened from the event header.
- **Name and copy.** "Match Downloader", sentence case, plain words: "Event feed", "Set by you", "No video position", "Line it up with the schedule", "Find start and end / Fixed length", "Shift (s)".
- **Selection as a highlighter.** This is the one expressive element, modelled on scouts marking matches on printed schedules. Selected rows and the tray get a soft yellow wash with a marker edge.
- **Scoreboard alliances.** Separate red and blue columns with a coloured bar; the winning score is bold in alliance colour and the loser is muted.
- **Restrained base.** Cool paper and ink, the platform system font (works offline, native in the Mac window), tabular numbers for times and scores, one border radius per tier, no decorative cards. Light and dark follow the system setting.
- **Library.** Dense rows with filter tabs and counts; a progress bar for active jobs; failures show the actual error line instead of the start of the tool log; generated notes cut down to teams and score.
- **Dialogs.** Native `<dialog>` for confirm, notes, preview, video position, recording editor (grouped into sections, with the sync method as plain choices and Save pinned at the bottom), check start and end, and playback. Toasts confirm actions.
- **Additions.** URL routing (`#/matches/<code>`, `#/library`, `#/clip`), a "Video only" filter, a "selected but outside the current filters" hint, live job status in the header, visible focus rings, reduced-motion support, and a compact phone tray (count, Options, Download).

Design inputs: the project's `frontend-design` and `ui-ux-pro-max` skills (Swiss/minimal, dense, light and dark, plus its pre-delivery checklist). I rejected its suggested indigo palette and Google Fonts because the app must work offline. "Design Taste" and "Impeccable" are not installed on this machine.

## Verified in the running prototype

Against the live API, on a copy of the library:
- **Matches:**
  - Exact `Q67` per division; lists, ranges and team search; R16 labels.
  - Select-all for a filtered round; row checkboxes with highlighting; Clear.
  - Switching between "Find start and end" and "Fixed length".
- **Preview and positions:**
  - Preview opens YouTube at the match time (04:06:33 for Ignite Q67), with the correct "Open original" link.
  - Setting a position on an untimed match.
- **Recordings:**
  - Add from a discovered link.
  - Add, edit and remove in "A match I can see" mode, including the fill-only option.
- **Downloads:**
  - A real YouTube download queued from the tray went Downloading → Processing → Saved and plays offline, a 12 s clip starting at the right position.
  - Notes, search, retry, cancel and delete, each with its confirmation.
  - A failing source shows its error.
- **Other:**
  - Clip-from-link validation, JSON import preview, adding several events with a bad code reported.
  - Deep links and page titles.
  - Phone event picker and tray.
  - No JavaScript errors during the screenshot runs.

Not verified: screen-reader announcements, the in-editor sync player against every provider, and Windows or Linux browsers.

## Screenshots

`screenshots/` holds matched pairs at 1440×900 (phones at 390×844):

| Original | Prototype |
|---|---|
| `before-1-start.png` | `after-1-start.png` |
| `before-2-event.png` | `after-2-event.png` |
| `before-3-selected-full.png` (full page) | `after-3-selected.png` (one screen) |
| `before-4-library.png` | `after-4-library.png` |
| `before-5-recording-editor.png` | `after-5-recording-editor.png` |
| `before-6-mobile.png` | `after-6-mobile.png` |

Also: `after-7-recordings.png`, `after-8-dark.png`, `after-9-mobile-events.png`, `after-10-keyboard-focus.png`, plus side-by-side `compare-matches.png`, `compare-library.png` and `compare-phone.png`.

## Later changes

Done later: the macOS 27 interface became the default and the app was renamed Match Downloader (bundle, window title, README, health check; `MATCH_DOWNLOADER_DATA`, with `SCOUTVAULT_DATA` still accepted).
