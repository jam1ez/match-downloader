# One-shot prompt: native SwiftUI Match Downloader

Paste everything below the line into a new Claude Code session opened in the project folder (`…/outputs/ScoutVault`). It builds Phases 0 to 4 of `redesign/swiftui/PLAN.md` in one go, checking each phase before moving on, and stops only for the reasons listed under "When to stop". Expect a long session.

---

You're building the native macOS version of **Match Downloader**, a Mac-only app for VEX robotics scouts. It finds matches in event schedules, works out where each match is in a livestream recording, and downloads trimmed MP4 clips for offline review.

Today it's a Python engine (`app.py` and friends; yt-dlp, FFmpeg, Apple Vision OCR) serving a local JSON API on `127.0.0.1:8766`, with a web interface (`web/mac/`) shown inside a thin AppKit/WebKit wrapper (`tools/Desktop.swift`). Your job: replace that interface with **native SwiftUI**, keeping the Python engine, and reach full parity in this session.

## Read first, in this order

1. `redesign/swiftui/PLAN.md`: architecture, settled decisions, package layout, API table, SwiftUI mapping, phases, iOS readiness, risks. Follow it. If you find something it didn't foresee, choose the option closest to its intent, note it in your final report, and continue.
2. `redesign/mac/README.md`: the current interface's behaviour, the HIG reasoning, and the **Verified** checklist, which is the parity target.
3. `web/mac/app.js`: reference behaviour for search parsing (Q67, QF1-1, `Q60-Q70` ranges, lists, team numbers, `R16 1-1`), sorting with empty values last, selection, sheets, the inspector, and the plain-language labels.
4. `app.py`: the JSON API and the token check (`X-Scout-Token`).
5. The project skill `apple-design` (`.claude/skills/apple-design`) for HIG questions. Cite the pages you rely on in code comments where a choice isn't obvious.

## Decisions (already made, don't ask again)

- macOS 26 only. Swift 6 with strict concurrency.
- Keep the Python engine. The only engine changes allowed:
  - the token file (`<library>/.session-token`, 0600, removed on exit; `MATCH_DOWNLOADER_TOKEN` overrides);
  - an `"api": 1` field in `/api/health`.
- Keep the web interfaces (`/`, `/next`, `/classic`) working as a frozen browser fallback, and add "Open in Browser" to the menu bar.
- Bundle identifier `org.matchdownloader.app`.
- Swift package in `mac/` plus `mac/scripts/build-app.sh`, which produces `Match Downloader.app` beside `app.py` with an ad-hoc signature. No hand-written `.xcodeproj`.
- Phase 5 (self-contained, notarized app) is **not** part of this build.
- **iOS later, not now:** follow PLAN.md › iOS readiness.
  - `MatchCore` imports only Foundation (and Observation if needed) and lists `.iOS(.v26)` in `Package.swift`.
  - It must build for iOS: `xcodebuild -scheme MatchCore -destination 'generic/platform=iOS Simulator' build` from `mac/`.
  - Mac-only code (`BackendProcess`, `NSSavePanel`, Dock badge, menu commands, Settings) stays in the app target.
  - Don't open the server to the network, and build nothing for iOS.

## Preconditions (check before writing code)

- The rename to Match Downloader is finished: `/api/health` returns `"app": "Match Downloader"`, and `README.md` and `tools/Desktop.swift` use the new name. If it isn't finished, stop and tell me; another session may be doing it.
- Toolchain: Xcode 26.x and Swift 6.x. Use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` for `xcodebuild` and `swift` if `xcode-select` points at the Command Line Tools.
- **Computer use:** ask me **once**, at the start, for permission to drive and screenshot the built app with the computer-use skill. It needs my approval and Screen Recording permission. If I say no, skip the visual checks and list them in the final report for me to do.
- **Test library:** copy `library/` to your scratchpad (events, `library.sqlite`, `ocr-tools`, and any clip folders you need). Run every test server as `MATCH_DOWNLOADER_DATA=<copy> .venv/bin/python app.py --port 8799 --no-browser`. The app must accept a port and data override (launch argument or environment) so you can point it at that server. **Never touch the real `library/`, and never run two servers on one library.**

## Build, in order, checking each phase before the next

**Phase 0: Groundwork**
- **Engine:** add the token file and the `api` version to `app.py`, with Python tests.
- **Package:**
  - `mac/Package.swift` with targets `MatchCore` (no UI; macOS 26 and iOS 26) and `MatchDownloader` (SwiftUI app), plus `MatchCoreTests`;
  - `mac/scripts/build-app.sh` writing Info.plist, the bundle id, an icon placeholder and the ad-hoc signature.
- **`MatchCore`:**
  - Codable models decoded from **real fixtures** captured from the test server: event, library, catalogue, stream probe. Use `JSONValue` for open-ended fields.
  - An async `APIClient` for every endpoint in PLAN.md's API table.
  - `MatchQuery` and formatting helpers, with unit tests ported from the web behaviour.
- **App target:**
  - `BackendProcess` starts or attaches through the token file, waits for `/api/health`, stops on quit, and logs to `library/desktop.log`.
  - The app opens a `NavigationSplitView` window.
- **Done when:**
  - `swift test` passes, as do the Python and Node suites;
  - the iOS build of `MatchCore` succeeds;
  - the bundle launches against the test server;
  - quitting stops a backend the app started.

**Phase 1: Downloads.** Build everything in PLAN.md › Phase 1:
- `Table` with sortable, resizable columns, the layout remembered, and native multi-selection; the scope picker with counts; search.
- Play in an AVPlayer window, opened with Space, Return or double-click; Save MP4 As….
- Retry, Stop and Delete through confirmation dialogs with no destructive default. The Delete key deletes.
- Inspector details, the real error line for failures, notes.
- The Check Start and End sheet.
- Polling with in-place updates, the Dock badge, notifications.

Done when every Downloads item in `redesign/mac/README.md › Verified` works natively, including:
- a real Needs Review job: queue detect mode on a short video with no match clock, served locally;
- a failing source showing its real error, then Retry, then Stop.

**Phase 2: Events and the schedule.** Everything in PLAN.md › Phase 2:
- **Sidebar:** On This Mac and Event Catalogue, filtering, Update Catalogue, the Add Events sheet.
- **Schedule table:** alliances with scores (winner bold), empty values sorted last.
- **Filters and search:** the filter pickers, Has Video, search with Return to select.
- **Right-click menu:** Preview, Set Video Position…, Use Recording, Download…, Copy Match Label.
- **Download sheet,** with settings remembered.
- **Match inspector.**
- **Preview window:** add `web/embed/preview.html` at `/embed/preview` (this is the one new web file allowed), reuse `web/preview.js`, and bridge to Swift with `WKScriptMessageHandler` and `evaluateJavaScript`. Space toggles the window.
- **Set Video Position sheet.**

Done when:
- Q67, QF1-1 and Q60–Q70 select exactly what the web interface selects;
- a real short fixed-length download from the sheet saves and plays;
- preview opens a real YouTube match at the right time.

**Phase 3: Recordings, Clip from Link, cutover.** Everything in PLAN.md › Phase 3:
- **Recordings inspector:** auto-timing on load as today, Find Positions Again, Check Event Page Again, discovered links, and Add, Edit and Remove for recordings.
- **Recording editor:** every field and sync method, Read Details including choosing from a channel, and the embedded player with Use Player Time and ±10 s.
- **Clip from Link and Import a List.**
- **The full menu bar and shortcuts:**
  - Add Events…, Clip from Link…, Preview, Set Video Position…, Download…;
  - Show/Hide Sidebar and Inspector, filters, Open in Browser.
- **Settings window:** default download options, library location display.
- **Cutover:** `build-app.sh` produces the SwiftUI `Match Downloader.app`, replacing the WebKit wrapper bundle. Keep `tools/Desktop.swift` as source. Update `README.md` (Start on this Mac, Interfaces, the browse walkthrough) to describe the native app.
- **Done when:** the entire `redesign/mac/README.md › Verified` list passes in the native app.

**Phase 4: Polish and accessibility.** Everything in PLAN.md › Phase 4:
- **VoiceOver:** labels for every icon button and column.
- **System settings:** checked under Reduce Transparency, Increase Contrast and Reduce Motion, in light and dark.
- **State restoration:** last event, selection, column layout and inspector.
- **Narrow windows** behave sensibly.
- **Copy:** a pass with the apple-design skill.
- **Done when:** a short review with the apple-design skill, written to `redesign/swiftui/REVIEW.md`, finds nothing above Medium.

## Rules

- Native components first: no custom glass in table content, no fake window chrome, SF Symbols throughout. Light and dark, accent colour and accessibility settings come from the system.
- Other sessions may edit this folder. Touch only the files this work needs, commit nothing, and don't switch branches.
- Run commands likely to take more than about two minutes in the background.
- Keep the existing suites green throughout: `.venv/bin/python -m unittest discover -s tests` and `node --test tests/test_preview.mjs`.

## When to stop and ask me

- A precondition fails, especially the rename not being finished.
- A phase's checks fail and you can't fix them after a real attempt. Report the output.
- Finishing would need an engine change beyond the two allowed, a network-exposed server, or anything touching the real `library/`.
- A decision would change what the user sees and isn't covered by PLAN.md or the web interface's behaviour.

## Final report

Cover:
- What was built, phase by phase.
- Every check run, with its result, including the iOS build of `MatchCore`.
- Screenshots: native next to the `redesign/mac/screenshots` equivalents.
- Anything not verified, and why.
- Deviations from PLAN.md.
- Exact steps to install: quit the old app and open the new `Match Downloader.app`.
