# Progress log: native SwiftUI Match Downloader

Last updated: 2026-11-18, after native Phases 0–4 implementation and nonvisual verification. **Nothing has been committed.** Read the continuation and final checkpoint below for current state. The initial handoff below is retained as history.

Current status: native root bundle built; Swift/Python/Node/iOS and native workflow integration checks pass. REVIEW.md records the remaining Medium startup warning and unverified interactive/accessibility acceptance checks. Computer use remains disabled.

## Ground rules still in force (from the user's run instructions)
- Brief: `redesign/swiftui/PROMPT.md` (follow everything below its divider) and `redesign/swiftui/PLAN.md`.
- Keep this log current after each phase and before long steps.
- No screenshots or computer use unless the user asks. Skip visual checks and list them at the end.
- Keep tool output short. Build and test quietly; show failures or summaries only.
- Test only against a COPY of the library on port 8799 with MATCH_DOWNLOADER_DATA. Never touch the real `library/`. Never two servers on one library. The real app may be running on port 8766 (an old engine, started before the token change): leave it alone.
- Other sessions may edit this folder: touch only needed files, commit nothing, don't switch branches.
- `xcode-select` points at the Command Line Tools: use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` for `swift`/`xcodebuild`.
- Python venv: `.venv/bin/python`. Xcode 26.6, Swift 6.3.3, iOS Simulator SDK 26.5 is installed.

## Preconditions: DONE
Rename finished (`/api/health` returns `"app": "Match Downloader"`, `Match Downloader.app` exists). Computer-use permission was NOT asked, per the user's instruction (skip visual checks).

## Phase 0: IN PROGRESS

### Done and verified
- **Engine (`app.py`)**: token file `<library>/.session-token` (0600, written at start in `__main__`, removed on exit only if it still holds our token); `MATCH_DOWNLOADER_TOKEN` overrides the token; `/api/health` now returns `"api": 1`. No other engine change.
- **Python tests (`tests/test_app.py`)**: added `test_health_reports_api_version`, `test_token_file_lifecycle` (subprocess on port 0, checks perms 0600, token in page, removed after SIGTERM), `test_token_env_override`.
  - Verified: `.venv/bin/python -m unittest discover -s tests` = 65 tests OK. `node --test tests/test_preview.mjs` = 3 pass, 0 fail.
- **Test library copy**: `/path/to/scratch` (events, ocr-tools, library.sqlite via sqlite3 .backup; one clip row, no clip video file copied).
- **Test server**: running in the background, pid 48067, `MATCH_DOWNLOADER_DATA=/path/to/scratch .venv/bin/python app.py --port 8799 --no-browser`, log `/path/to/scratch`. Token is in `/path/to/scratch`. Stop it with `kill 48067` when finished (it removes its token file on SIGTERM).
- **Fixtures** (real JSON captured from the 8799 server, in `mac/Tests/MatchCoreTests/Fixtures/`): `health.json`, `library.json` (one real "ready" reviewed clip, contains a real clip title and notes), `catalogue.json` (24 events), `event-with-recording.json` (VE-V5-26-65786 whole: 69 matches, 1 recording with metadata), `event-schedule.json` (RE-V5RC-25-9904 trimmed to 53 matches in original order: first 30 plus Q59, Q60, Q66, Q67, Q68, Q70, Q71, R161-1, QF1-1, SF1-1, F1-1 for the Canyon and Desert divisions, and F1-1 for Grand FInals). Q60-Q70 should select Q60, Q66, Q67, Q68, Q70 in each of the two divisions = 10 matches. Not yet captured: a probe result, a failing/needs-review library, an event with anchor/wallclock recordings or discovery candidates (the models handle these but no fixture exercises them).

### Written but NEVER COMPILED (may have errors)
All under `mac/`:
- `Package.swift`: swift-tools-version 6.2; macOS 26 and iOS 26; targets `MatchCore`, executable `MatchDownloader`, test target `MatchCoreTests` (resources: `.copy("Fixtures")`); `swiftLanguageModes: [.v6]`. Uncompiled. **It will fail to resolve until `Sources/MatchDownloader/` contains at least one .swift file (the directory is empty).**
- `mac/.gitignore`: .build, .swiftpm, xcodeproj, DerivedData. (Fine; not code.)
- `Sources/MatchCore/JSONValue.swift`: open-ended JSON enum with typed accessors. Uncompiled.
- `Sources/MatchCore/Models.swift`: Codable models: Health, ClipStatus, Clip (snake_case keys mapped, analysis and detect-anchor helpers), ClipAnalysis, LibraryState, QueueResult, Catalogue(Event), Division, Alliance, StreamOption, Match (`id` JSON key mapped to `matchID`), Program, Recording, StreamMetadata (wraps JSONValue), ChannelRecording, DiscoveryCandidate, Discovery, AutoTiming, StreamSummary, EventDetail (JSON `id` mapped to `eventID`), StreamProbe, PreviewSource, requests QueueRequest, StreamDraft (custom encode omitting nil id/duration), NewClip (accepts numeric or text times). Uncompiled and not yet tested against the fixtures. Things to check on first compile: `EventDetail.recordingDurations` is typed `[String: Double]?` and `location` is `JSONValue?`; check they decode the fixtures.
- `Sources/MatchCore/APIClient.swift`: `APIError`, `SessionToken` (reads the token file, env override), `APIClient` struct with one async function per endpoint in PLAN.md's table (health, library, videoURL, catalogue, loadEvent, queue, calibrate, saveStream, deleteStream, chooseStream, discoverStreams, probeStream, autoTime, previewSource, addClip, retry/cancel/delete/setNotes/setBounds), token provider closure with one retry on 403, error text taken from the engine's `{"error": …}`. Uncompiled. Possible compile issues: the `catch APIError.server(_, 403)` pattern may need the `status:` label; `#if canImport(FoundationNetworking)` import is harmless on Apple platforms.

### Not started (empty or missing)
- `mac/Sources/MatchDownloader/` (empty directory): needs `App.swift` (@main, WindowGroup with `NavigationSplitView`, accepts `--port` / `--data` or `MATCH_DOWNLOADER_PORT` / `MATCH_DOWNLOADER_DATA`), and `BackendProcess.swift` (app target only, NOT MatchCore).
- `MatchCore` still to write: `MatchQuery.swift` (port of `canonical`/`matchesQuery` in `web/mac/app.js` lines 278-289: Q67, QF1-1, R16 1-1, `Q60-Q70` ranges, comma/semicolon/newline lists, team numbers, case-insensitive), `Labels.swift` (showLabel, roundOf, matchDay, status names, `failure()`, source text, no-position text, clipTitle, sync text), `Format.swift` (clock, parseClock, byte size, plural, dayName, dateRange), and an empty-values-last `SortComparator` (Foundation only). Check whether `SortComparator` needs a Sendable key path under Swift 6.
- `mac/Tests/MatchCoreTests/`: no test .swift files exist yet (fixtures only). Need decoding tests for every fixture, `MatchQuery` tests, formatting tests, empty-last sort tests, and an opt-in integration test against port 8799.
- `mac/scripts/build-app.sh` (empty `scripts/` dir): release build, write Info.plist (bundle id `org.matchdownloader.app`, LSMinimumSystemVersion 26.0, executable "Match Downloader", `NSAppTransportSecurity` > `NSAllowsLocalNetworking`), icon placeholder in `mac/Resources/` (empty), ad-hoc `codesign -s -`, output `Match Downloader.app` beside `app.py`. For Phase 0 it must not overwrite the existing WebKit-wrapper bundle by accident: the existing bundle's `Contents/MacOS/Match Downloader` is git-ignored and its Info.plist still says `org.matchdownloader.desktop`. Cutover is Phase 3.
- BackendProcess design (decided, not written): find the project root (env override, the folder beside the .app, or walk up from the executable until `app.py` is found); if `/api/health` already answers with app "Match Downloader" and `api` present, attach using the token file; if `api` is absent it is an older engine with no token file, so show a clear "quit the old copy and reopen" message; if another app name answers, explain; otherwise start `.venv/bin/python app.py --no-browser --port N` with PATH including /opt/homebrew/bin, log to `<library>/desktop.log`, wait for health, read the token. On quit, send SIGTERM to a backend this app started, wait up to about 5 s, then SIGKILL. Do not stop a backend it only attached to.
- iOS check still to run from `mac/`: `DEVELOPER_DIR=… xcodebuild -scheme MatchCore -destination 'generic/platform=iOS Simulator' build`.

### Phase 0 "Done when" checklist
- [ ] `swift test` passes
- [x] Python suite and Node suite pass (re-run after any further engine change)
- [ ] iOS build of MatchCore succeeds
- [ ] App bundle launches against the 8799 test server
- [ ] Quitting stops a backend the app started

## Phases 1 to 4: NOT STARTED
Follow PROMPT.md. Each phase's "Done when" must be checked before the next.

## Git state at this point
Modified: `app.py`, `tests/test_app.py`. New and untracked: `mac/` (Package.swift, .gitignore, Sources/MatchCore/{JSONValue,Models,APIClient}.swift, fixtures), `redesign/swiftui/PROGRESS.md`. Note: `mac/`, `redesign/` also contain pre-existing "Watermarks Cleaned" folders from an external tool (git-ignored; not mine).

## Visual checks for the user (collected so far; list in final report)
None collected yet. Everything visual in PROMPT.md's Phases 1-4 will be unverified and must be listed.

## Continuation — 2026-11-18 (Codex)
- Located the checkout in the 2026-11-16 ScoutVault outputs folder; no branch changes or commits.
- Read PROMPT, PLAN, this log, the parity checklist, web behavior, API and project apple-design skill.
- Verified rename in source and Swift 6.3.3 / Xcode toolchain. Computer use remains disabled.
- First build exposed missing `NewClip.CodingKeys`; fixed. Added the minimal app entry point required to resolve the package.
- Sandbox caches redirected to /tmp/md-swift-cache and /tmp/md-spm-cache; no home-directory cache writes needed.
- Phase 0 remains in progress. Next: compile, fixture/query/format tests, backend lifecycle, bundle and iOS checks. No later phase started.
- Before long verification: creating our own fresh library copy and running existing suites; port 8766 remains untouched.
- Verification checkpoint: four Swift tests pass (real fixtures, query parity, formatting, empty-last sorting and request encoding); Python 65/65 and Node 3/3 pass.
- BackendProcess and staged bundle script written. Starting iOS and bundle/lifecycle verification. First sandboxed xcodebuild could not access simulator services or recognize the package; retrying with normal Xcode access.

## Phase 0 — COMPLETE (2026-11-18 Codex)
- Existing core compiles after NewClip.CodingKeys repair. Foundation-only shared core verified.
- Added MatchQuery, Format, Labels and EmptyLast with four passing Swift tests using the existing real fixtures.
- Added Mac-only BackendProcess: root/data/port overrides, health/API validation, token handoff, served-library validation, logging, owned-process shutdown and attach preservation.
- Staging build script creates an ad-hoc signed native bundle without replacing the old wrapper.
- Verified: swift build; swift test (4 pass); Python (65 pass); Node (3 pass); required xcodebuild MatchCore iOS Simulator (arm64 and x86_64, BUILD SUCCEEDED).
- Verified staged bundle launches against our own copied library on 8799. Automated --smoke-test launches the real bundle executable; owned backend stops and removes token on quit; attached backend remains running. No computer use or screenshots.
- Copy: /var/folders/28/mhkk8k4s46v3hy9rq6tcd4rh0000gn/T/match-native-z1qgyn8t/library. No test backend left running.
- Deviation: standard macOS application icon is the initial placeholder; bundle remains in mac/.build/staging until cutover.

## Phase 1 — IN PROGRESS
Before long implementation: adding native Downloads table, inspector, review/playback, actions and active-scene polling. Next gate is real fixed/detect/failure jobs on the library copy plus Swift regression checks. Interactive visual and accessibility checks remain skipped per user instruction.
- Phase 1 implementation compiles: native multi-select/sort/resize/customizable table and scopes, search, AVPlayer windows, Save As, guarded action confirmations/Delete key, notes/error inspector, review bounds sheet, active-scene polling, Dock counts and authorized notifications.
- Before long integration run: building staged bundle and exercising real no-clock detection, review trim/playability, notes, failing source, retry/stop/delete with native APIClient. Script makes another fresh copy and refuses occupied 8799. UI interaction itself remains unverified without computer use.

## Phase 1 — IMPLEMENTED; nonvisual gates PASS
- Real native APIClient verification passed against fresh copy match-native-verify-26770e9l: actual OCR job without a clock reached Needs Review; AVFoundation opened review; bounds 1–4 saved a playable 3-second MP4; notes persisted; actual 404 error surfaced; Retry → Stop → Delete passed. Owned test backend stopped.
- Native Table and controls compile; interactive table/keyboard/Save As/notification presentation checks are explicitly skipped with all other computer-use checks. No screenshots taken. These are not claimed as tested interactions.
- Rebuild hit Finder metadata on the staged bundle; build script now clears bundle xattrs before signing. No original bundle touched.

## Phase 2 — IN PROGRESS
Before long implementation: event catalogue/sidebar, schedule, filters/query selection, download and position sheets, and the single permitted embedded preview page/bridge. Will verify fixed job and preview initialization via native integration; provider playback may depend on external service availability.
- Phase 2 native UI and bridge written; compilation fixes underway (SceneStorage requires a nonoptional route). Added an empty-last comparator test through KeyPathComparator, plus schedule/fixed-download/real-probe/YouTube bridge integration checks.
- The `/embed/preview` page registration is the explicitly requested preview-route addition to app.py; all engine operations remain unchanged.
- Before long steps: rebuild and run Swift/Python/Node checks, then the native schedule integration on a new copy.
- Swift tests 5/5, Python 65/65, Node 3/3 pass after the preview route addition.
- First Phase 2 integration verified query selections and fixed 3-second MP4 playback. Probe returned valid real metadata with null duration; corrected the test's assumption and captured probe.json as a real fixture. Retrying before checking YouTube.

## Phase 2 — IMPLEMENTED; nonvisual gates PASS
- Native sidebar/catalogue/filter/Add Events; schedule with all requested columns, alliance scores/winner weight, empty-last sorts; filters/search Return-to-select; context menu, recording chooser, match inspector, download and calibration sheets.
- One requested new web page, `/embed/preview`, reuses existing preview.js and reports to a main-frame/origin-checked WKScriptMessageHandler; native Jump/Get Time and browser links. Space toggles preview windows.
- Native integration on fresh copy match-native-verify-yg9htfv5 passed Q67/QF1-1/Q60–Q70 selection parity, real fixed 3-second download/playability, real probe metadata, and real YouTube Q67 player ready at 3687.0 seconds. Backend stopped afterwards.
- Real probe fixture captured; added KeyPathComparator empty-last test. Python 65/65 and Node 3/3 remain passing.
- UI interactions/screenshots remain unverified per no-computer-use instruction. Xcode emitted a SwiftUI NSTableView reentrancy warning during app initialization; investigate during polish.

## Phase 3 — IN PROGRESS
Before long implementation: recording management/editor and automatic timing, Clip from Link/import, commands/settings, and cutover only after verification. Keep tools/Desktop.swift and browser interfaces.
- Phase 3 compiles with six Swift tests passing. Added recording inspector/editor (all sync/scope fields, probe/channel choices, embedded player/time capture/±10s), auto-discovery/timing on load with stale-response guards, Clip from Link and checked JSON import, native menus and Settings.
- Before long verification: test recording mutations/calibration, import, invalid inputs against a fresh copy; rebuild staged bundle. Cutover and README follow passing checks.
- Phase 3 native integration passed on fresh copy match-native-verify-qp_jl3qf: Add/Edit/Choose/Remove recording, calibration, bad event-code feedback, invalid clip rejection, numeric JSON import and real saved MP4. Owned backend stopped.
- Added API token-refresh/error-path tests; corrected a test counter expectation for a subsequent separate request. Re-running before cutover.
- Before long cutover build: default build destination now the root Match Downloader.app; signing completes in a temporary bundle first, then the prior bundle is preserved under mac/.build/previous-bundle-*. Native icon placeholder added. README describes native launch, browser fallback and overrides. No running app or real library is stopped or touched.

## Phase 3 — IMPLEMENTED; nonvisual gates PASS
- Native recording mutation/calibration and JSON import integration passed, including invalid link and bad event-code feedback. All 8 Swift tests pass (includes token refresh/error fidelity); previous regression suites remain green.
- Cutover script builds/signs a complete bundle before replacing the old app and preserves the old bundle in mac/.build. README now documents the SwiftUI app and native/browser paths; tools/Desktop.swift remains intact.
- Sandbox iconutil rejected a valid iconset; normal Xcode/tool access compiled it successfully. This was an environment restriction, not an icon-source error.
- Visual/keyboard interaction, notification banners, every-provider editor player and accessibility system-setting checks remain unverified per instruction. No claim of hands-on parity verification.

## Phase 4 — IN PROGRESS
Before long polish/review: inspect source with apple-design references; improve independent-window state, state restoration and narrow layout; remove initialization reentrancy; label controls/columns; then final build, all test suites, iOS compilation and native integration regression on copied libraries.
- Phase 4 polish: each workspace now owns an independent EventStore; polling is shared with active-window subscribers; identical library responses no longer trigger row replacement. Deferred selection restoration avoids changes during table initialization. Per-event selection and last route restore, native column width autosave supplements SwiftUI customization, and narrow windows collapse sidebar/scroll filters/use a compact scope menu. Recording sheets can fit shorter screens. Alliance VoiceOver labels explicitly say teams, score and winner.
- Next: source review fixes and final verification; visual/system-settings checks remain excluded.
- Source review fixes: sort direction/columns now restore; column widths use standard NSTableView autosave; empty states give a next action; inspector labels reflect Show/Hide; changed recording links clear obsolete sync details; preview messages ignore empty warnings; startup refuses another session token on a different port; generated cleanup reports excluded from Swift source discovery.
- Before final long checks: rebuilding the root bundle, then running all three opt-in native integration phases sequentially (fresh copy each), Swift/Python/Node regression, iOS MatchCore build and signature validation. No visual/system-setting checks will be performed.
- Final regression checkpoint: Python 65/65, Node 3/3, Swift 8/8, iOS MatchCore BUILD SUCCEEDED. Release compiler needed the schedule table extracted into its own computed view; fixed and release build/signing now succeeds.
- Re-running native checks on the final root bundle. Earlier native runs all passed but used the preceding bundle while the new release was rebuilding; retain those as prior evidence, not final-build evidence. Table initialization persistence writes are deferred to avoid delegate reentrancy.

## Final verification checkpoint — 2026-11-18
- Final release build succeeds and root native bundle is installed. Eight Swift tests, 65 Python tests (including preview route/token injection assertion), three Node tests and iOS MatchCore compilation all pass.
- Final root-bundle integration passed on separate copies: Downloads `match-native-verify-2wozmrgg`, Schedule/YouTube `match-native-verify-qfyooulh`, Recordings/import `match-native-verify-y0wn9u1r`. Actual OCR Needs Review, reviewed 3-second AVFoundation-playable trim, notes, real error/Retry/Stop/Delete, fixed MP4, Q67 at 3687 seconds, probe, recording mutations, calibration and imports passed. Each test backend stopped.
- Phase 4 source implementation/review is complete; REVIEW.md has no Critical/High findings. The AppKit startup reentrancy warning remains Medium after a real deferral fix attempt. Visual, VoiceOver, system settings and hands-on restoration/keyboard checks are unverified because computer use is disabled. Full interactive parity is not claimed.
- File-provider metadata is reapplied to the bundle in Documents: strict signing checks can reject the transient com.apple.FinderInfo xattr. Removing that attribute immediately before verification reports “valid on disk / satisfies its Designated Requirement”. The build script now retries that narrow cleanup/verification; app launches and native integration pass.
- Nothing committed; no branch switched; real library untouched, port 8766 left alone. tools/Desktop.swift and all browser fallback interfaces retained. Root app prior bundles are preserved in mac/.build/previous-bundle-*.
- Final lifecycle repeat on the root bundle passed owned shutdown and attached-server preservation. No server remains on 8799.
- Literal import audit removed the unused conditional FoundationNetworking import; final core imports Foundation only. Rebuilt native bundle, Swift 8/8 and iOS BUILD SUCCEEDED afterwards.
- Last source-review correction: a failed event load now clears the previous event and shows Can’t Open Event, matching the browser behavior instead of leaving the old schedule beneath a newly selected sidebar item.
- Final build report exported to the current chat outputs; local cleanup service returned changed=false with no remaining metadata findings. No code or prose was statistically rewritten.
- 2026-11-18 01:52 Claude: play crash fixed. Cause: SwiftUI VideoPlayer linked only _AVKit_SwiftUI, not AVKit, so creating a player view aborted (crash report Match Downloader-2026-11-18-015117.ips). Replaced with NativePlayerView (AVPlayerView wrapper) in DownloadsView.swift; rebuilt bundle, AVKit now linked, signature ok, swift test passes. Play not clicked by me.
- 2026-11-18 01:56 Claude: schedule table now Match/Division/Red/Blue/Source/Download (Day and Video position removed from the table; still in inspector and Day filter), filter bar tidied, status line (N of M selected / Return hint). Preview and playback windows: default 960x540 (not full screen), content-aspect locked to the video (16:9 for preview; real clip shape for playback), controls moved to toolbar, status in subtitle, no bar under the player. Rebuilt, signed, swift test 8/8. Not visually checked.
- 2026-11-18 01:59 Claude: restyled toward the previous web look: red/blue dots + space-separated teams + dimmed losing score in alliance cells; glass capsule filter pill; floating glass status pill; toolbar split into [refresh, preview, position] | Download… | inspector toggle; match inspector rebuilt (large title, right-aligned facts, alliance card, capsule buttons, Started shown as a time, Day as 'Day N, …'); inset table without alternating rows. Built, signed, swift test 8/8, app relaunched. Not visually checked.
- 2026-11-18 02:05 Claude: visual refinement toward the first (web) design. New Theme.swift (canvas #1c1c1e/#fbfbfd, alliance dot colours, grey selection tint, soft capsule/card/floating-capsule styles, shared InspectorHeading/Section/Facts). Schedule + Downloads tables: inset, no zebra, transparent scroll background on canvas, grey selection via .tint on the Table (UNVERIFIED visually: if rows still select blue, the tint is not honoured by Table and an NSTableView bridge in TablePersistence is the fallback). Filter pill and status pill use soft fills/material instead of glass; inspector scorecard is a soft card; Download inspector rebuilt in the same layout. Files: Theme.swift (new), EventView.swift, DownloadsView.swift. swift test 8/8, iOS MatchCore build ok, relaunched.
- 2026-11-18 02:07 Claude: schedule table decluttered to match the first design: zebra rows back (alternatesRowBackgrounds true), taller rows (Match cell padded), Source column hidden by default (still in header menu and inspector), Division column auto-hidden for single-division events, wider alliance columns, column storage keys bumped to v3. Not visually checked.
- 2026-11-18 02:11 Claude: table lines removed via NSTableView bridge (gridStyleMask empty, intercell width 14) for schedule and downloads tables; schedule Download column is now a single status dot (green saved, blue in progress, orange needs review, red failed, grey waiting/stopped) with tooltip + VoiceOver label (StatusDot in Theme.swift). If lines persist they come from SwiftUI row separators, not the grid. Not visually checked.
- 2026-11-18 02:15 Claude: FIXED hang (100% CPU layout loop at launch, 'not responding'). Cause (from sample): NSTableView column autosave in TablePersistence fought SwiftUI TableColumnCustomization once columns were hidden (Source default-hidden, Division auto-hidden). Removed the autosave; the bridge now only clears grid lines; SwiftUI customization keeps widths/order/visibility. Idle CPU back to ~0-7%. Column widths saved under the old NSTableView autosave key are ignored.
- 2026-11-18 02:24 Claude: videos that can't be embedded (YouTube error 101/150/153 etc.): PreviewBridge.error now captures the player error; the preview window shows a card with the reason and a prominent 'Open in Browser at HH:MM:SS' button; links the player opens in a new window (Watch on YouTube) now go to the default browser at the match time (WKUIDelegate); 'Open in Browser' added to the schedule right-click menu and the match inspector. Files: PreviewView.swift, EventView.swift, Verification.swift (Coordinator init). Not tried against a real embed-blocked video.

## Quit keeps downloads going (2026-11-18)
- Engine: `POST /api/quit-when-idle` (only for an engine the app started, `MATCH_DOWNLOADER_MANAGED=1`). It keeps working, then exits once no clip is queued/downloading/analyzing/processing. Tests added in `tests/test_app.py`.
- App: Quit asks the engine to exit when idle instead of stopping it; reopening the app cancels that. If the engine cannot be asked, it is stopped as before.
- Verified on a throwaway library, port 8799: quit with an active download left the engine running, and it exited after the download finished. Not verified: a real download across a quit.
- Found while testing: `terminate` waits in the modal-panel run-loop mode, which the main dispatch queue does not serve, so the reply uses `RunLoop.main.perform(inModes:)`.

## Archive and remove events (2026-11-18)
- Engine: `POST /api/events/archive` and `/api/events/remove`; archived SKUs live in `library/events/archived.json`; the catalogue response gains `archived`. Remove deletes only the saved schedule and recordings, never clips.
- App: sidebar context menu and swipe actions on saved events (Archive, Unarchive, Remove from This Mac with a confirmation); an Archived section appears when needed.
- Verified: engine test, Swift decode test, release build. Not verified by clicking through the UI.

## Engine version check and speed-ups (2026-11-18)
- Engine API is now 2; the app refuses an older engine still running in the background (that is what caused a "not found" error on Archive) and tells the user how to stop it. A 404 now explains itself.
- Encodes use the Mac hardware encoder (h264_videotoolbox) with libx264 fallback; YouTube downloads prefer H.264/AAC at 30 fps or less, so the review window rarely needs re-encoding.
- Measured on a real 2-minute YouTube clip, temp library, port 8799: about 119 s total, of which about 99 s was the section download (1.2x real time) and 8 s was the hardware encode. The download is now the bottleneck.

## Collapsible sidebar sections (2026-11-18)
- Archived (collapsed by default) and Event Catalogue (open by default) can be collapsed; the choice is remembered, and both open while searching. Not verified by clicking.

## Download progress on hover (2026-11-18)
- Engine: `/api/library` adds `progress {fraction, eta}` for downloading/processing jobs, read from ffmpeg output of the running step only. Reading the match clock has no known length, so no fraction.
- App: Status cell shows a ring (filled when known) and a 2 pt hairline; hovering the cell expands it to a 5 pt bar with "42% · about 1 min left". Inspector shows the bar always. Row height does not change. Reduce Motion respected.
- Verified: real 2-minute download on a temp library reported steady fractions and ETA; Swift and Python tests. Not verified by looking at the hover in the app.

## Progress bar fix (2026-11-18)
- Engine: progress combines yt-dlp video and audio passes, never moves backwards within a step, and holds its place across automatic retries.
- App: the bar fill is a scaled shape (no GeometryReader, no layout animation); the inspector reserves a fixed-height block so nothing shifts.
- Could not reproduce the engine-side bounce on YouTube (raw ffmpeg times were monotone in a live match-detection download); the fixes cover the likely causes. Not verified by looking at the UI.

## New app icon (2026-11-18)
- Replaced the placeholder (flat systemBlue) with a graphite tile on the macOS 824 pt grid: white play triangle over a red/blue scrubber (the two alliances). Drawn by `mac/scripts/make-icon.swift`; `build-app.sh` installs it. Dock caches icons: relaunch, or `killall Dock`.

## Two downloads at once; Worlds folder (2026-11-18)
- Engine runs up to 2 jobs at once (`MATCH_DOWNLOADER_PARALLEL`, 1-4); OCR helper build is locked. Real test: three 90 s clips peaked at 2 running.
- Worlds: `worlds-season.json` picks the year and folder title; `worlds.json` holds each year (2026 SKUs filled in). Catalogue response gains `worlds`; those events leave the general lists. Sidebar folder "Worlds 26" is collapsible; right-click opens the vexworlds.tv channel. `tools/new_worlds_season.py <year> "<title>"` writes next year (reproduces the 2026 block exactly). Real test: RE-V5RC-26-4025 loaded with 2970 of 2982 matches positioned.
- Not verified by looking at the sidebar.

## Sidebar order and defaults (2026-11-18)
- Order: Library, On This Mac, Worlds, Archived, Event Catalogue. Worlds and Archived start collapsed (new storage keys, so earlier choices reset once). Not verified by looking.

## Start and end sliders for Quick Download (2026-11-18)
- Download sheet (and Settings): in Quick Download only, Start (-60 to +60 s) and End (-60 to +120 s) sliders in 5 s steps, a plain-words summary of the resulting clip, and Reset. Preview start includes the start slider.
- Engine: `startAdjust`/`endAdjust` on `/api/events/queue`, fixed mode only, validated, clip must stay at least 5 s. Test added.
- Not verified by looking at the sheet.

- Later the same day: the two sliders became one two-thumb range slider (`ClipRangeSlider`); left thumb is the clip start, right thumb the end, 5 s steps, at least 5 s apart, arrow keys and VoiceOver adjust the focused thumb. Engine unchanged. Not verified by dragging it.

## Adjust saved clips (2026-11-18)
- Engine: `POST /api/clips/<id>/adjust {start,end}` (source seconds). Inside the old range the saved file is trimmed locally; beyond it the wider range is downloaded again. The old file stays until the new one is complete; failure, cancel or an interrupted run restores the old range. Tests added.
- App: "Adjust Length…" (right-click and inspector) opens a sheet with the two-thumb slider: 0:00 is the current start, drag outward to add up to two minutes each side, inward to cut.
- Verified live on a temp library: 60 s download, trim to 40 s (4 s), extend to 90 s (90 s). Not verified by dragging the slider.
