# Plan: a native SwiftUI Match Downloader

> Historical record of the SwiftUI rewrite. Files it mentions that no longer exist (`PROMPT.md`, `REVIEW.md`, `redesign/mac/`, the screenshots, `tools/Desktop.swift`, and the `/next` and `/classic` web pages) were removed in a later cleanup and remain in git history.

Status: plan only, nothing built. Written 2026-11-18. Decisions settled the same day (see Decisions); to be built in one session with `PROMPT.md`.

## Goal

Replace the web interface inside the Mac app with a native SwiftUI interface that does everything `/` (`web/mac/`) does today, while keeping the Python engine unchanged. The result is a Mac-only app that uses real system components: sidebar, toolbar, table, inspector, sheets, alerts, menu bar, Liquid Glass and accessibility.

**Not in scope:**
- Rewriting downloads, video positions, auto-timing or match-clock detection in Swift.
- Windows or Linux.
- Changing how the library is stored.

## Starting point

| Part | Today | After |
|---|---|---|
| Mac app | `tools/Desktop.swift`: 158 lines of AppKit that start `app.py` and show the web page in a WKWebView | SwiftUI app that starts `app.py` and talks to it over its JSON API |
| Interface | `web/mac/` (HTML, CSS, JS; about 1,200 lines) | SwiftUI views. The web interfaces stay available in a browser as a frozen fallback |
| Engine | `app.py`, `events.py`, `event_streams.py`, `auto_timing.py`, `boundaries.py`, `webcast.py`, `worlds.py`; yt-dlp, FFmpeg, Apple Vision OCR | Unchanged, apart from one small token change (below) |

**Machine:**
- macOS 26.6.2 (Tahoe), Xcode 26.6, Swift 6.3.3, macOS SDK 26.5.
- No xcodegen or tuist installed.

**Dependency:** finish the rename to Match Downloader first. It was still in progress in another session: the bundle hadn't been rebuilt as `Match Downloader.app`, and the health check must report `Match Downloader`.

## Architecture

```text
Match Downloader.app (SwiftUI, macOS 26)
├─ BackendProcess   starts .venv/bin/python app.py --no-browser (or attaches to a running one),
│                   waits for /api/health, stops it on quit, logs to library/desktop.log
├─ APIClient        async/await URLSession, X-Scout-Token header, Codable models
├─ Stores           @Observable LibraryStore (polls /api/library), EventStore, CatalogueStore
└─ Views            NavigationSplitView + Table + inspector + sheets + commands
            │  HTTP JSON on 127.0.0.1:8766
            ▼
app.py (unchanged engine) → yt-dlp / FFmpeg / Vision helper → library/
```

### Decisions (settled)

1. **Keep the Python engine** and talk to it over the existing local API. yt-dlp is Python, and the engine is the tested part.
2. **Token handoff.** The server makes a random token per run and only puts it into the HTML page, so a native client can't see it. The one backend change: on start, `app.py` writes the token to `<library>/.session-token` with permissions 0600 and deletes it on exit; the Swift app reads it. That also works when the server was started by `Start.command`. `MATCH_DOWNLOADER_TOKEN` in the environment overrides it. Keep the `X-Scout-Token` header name so the web interfaces keep working.
3. **Project format:** a Swift package plus a build script, not a hand-written `.xcodeproj`.
   - `swift build` and `swift test` work from the terminal, and Xcode opens `Package.swift` for editing and previews.
   - `scripts/build-app.sh` assembles `Match Downloader.app`: release binary, `Info.plist`, `.icns` icon, ad-hoc signature.
   - The bundle is needed for notifications and a stable bundle identifier.
4. **Deployment target macOS 26 only.** Liquid Glass, `.glassProminent`, inspectors and tables come straight from the SDK.
5. **Previewing recordings.** YouTube and Vimeo need their web players, and `web/preview.js` already handles their seek quirks (tested in `tests/test_preview.mjs`).
   - Add one small page, `web/embed/preview.html`, served at `/embed/preview`, that runs `preview.js` and reports state to Swift through `WKScriptMessageHandler`.
   - Swift sends Jump and Get Current Time through `evaluateJavaScript`.
   - The same page covers MP4, HLS and BoxCast, through `hls.js` and `/api/preview/source`.
   - Saved clips and review windows play natively with AVPlayer from the library files.
6. **Live updates:** poll `/api/library` every 2.5 s while the app is active, and stop when it's inactive. A push endpoint (server-sent events) can come later.
7. **Web interfaces stay as a frozen fallback:** `/`, `/next` and `/classic` stay served by `app.py` for browser use (fixes only). The menu bar gets "Open in Browser".
8. **Bundle identifier `org.matchdownloader.app`,** switched now, before anyone installs the app. The old WebKit wrapper's local settings (last event, column widths) don't carry over; the library is unaffected.
9. **Phase 5 (self-contained, signed app) is out of scope** for now; there is one user.
10. **iOS later, not now.** An iPhone/iPad viewer is planned for later. This build stays iOS-ready but builds nothing for iOS (see iOS readiness).

## Package layout

```text
mac/
  Package.swift                    macOS 26; targets below
  Sources/MatchCore/               no UI: models, API client, backend process, match query, formatting
    Models.swift                   Event, Match, Alliance, Clip, Library, Stream (+ JSONValue for metadata)
    APIClient.swift                one async function per endpoint (table below)
    BackendProcess.swift           launch/attach, health, token file, log, termination
    MatchQuery.swift               Q67, QF1-1, R16 1-1, ranges, lists, team search (port of web/mac/app.js)
    Labels.swift, Format.swift     showLabel, clock, sizes, date ranges, plain-language source names
  Sources/MatchDownloader/         SwiftUI app
    App.swift                      @main, WindowGroup, Settings scene, commands
    Stores/                        LibraryStore, EventStore, CatalogueStore (@Observable, @MainActor)
    Views/Sidebar/, Views/Event/, Views/Downloads/, Views/Clip/, Views/Inspector/, Views/Sheets/, Views/Preview/
  Tests/MatchCoreTests/            query parser, decoding fixtures, formatting
    Fixtures/                      real JSON captured from a test server (event, library, catalogue)
  Resources/Info.plist, AppIcon.icns
  scripts/build-app.sh             swift build -c release → "Match Downloader.app" beside app.py
```

`tools/Desktop.swift` stays as source for reference. The built app replaces the WebKit wrapper at cutover.

## API surface to wrap

| Method | Endpoint | Used by |
|---|---|---|
| GET | `/api/health` | backend start or attach |
| GET | `/api/library` | Downloads table, status, sidebar badge (poll) |
| GET | `/video/<id>`, `/review/<id>` | AVPlayer (or read the files under `storage`) |
| POST | `/api/events/catalogue` `{refresh}` | sidebar lists |
| POST | `/api/events/load` `{sku, refresh}` | open, refresh or add events |
| POST | `/api/events/queue` `{sku, keys, mode, duration, before, tail, window, offset}` | Download sheet |
| POST | `/api/events/calibrate` `{sku, key, url, timestamp}` | Set Video Position |
| POST | `/api/events/streams/save`, `delete`, `choose`, `discover`, `probe` | Recordings inspector and editor |
| POST | `/api/events/auto-time` `{sku, search}` | Find Positions Again, auto-run on load |
| POST | `/api/preview/source` `{url}` | embedded preview page |
| POST | `/api/clips` `{title, url, start, end, notes}` | Clip from Link, import |
| POST | `/api/clips/<id>/retry, cancel, delete, notes, bounds` | Downloads actions, Check Start and End |

`/api/events/recording` belongs to an unused dialog in the classic interface; skip it.

## SwiftUI mapping (HIG)

| Feature in `web/mac` | SwiftUI |
|---|---|
| Floating glass sidebar: Library, On This Mac, Event Catalogue, filter, + | `NavigationSplitView` sidebar `List` with `Section`s, `.searchable` in the sidebar, `SidebarCommands()` |
| Toolbar title and subtitle | `.navigationTitle`, `.navigationSubtitle` |
| Download… (prominent) | `ToolbarItem(placement: .primaryAction)` with `.buttonStyle(.glassProminent)` |
| Search with Return to select | `.searchable(placement: .toolbar)`, `.onSubmit(of: .search)` |
| Division, Round and Day filters; Has Video | toolbar `Picker`s (menu style) and a `Toggle`; or `.searchScopes` |
| Schedule table: sort, resize, select | `Table(rows, selection: $selection, sortOrder: $sortOrder)`, `TableColumnCustomization` stored with `@SceneStorage` |
| Right-click menu and double-click | `.contextMenu(forSelectionType:menu:primaryAction:)` |
| Space for Quick Look preview | `.onKeyPress(.space)` on the table, opening a preview window or sheet |
| Inspector (Match / Recordings / Download) | `.inspector(isPresented:)`, `InspectorCommands()` |
| Sheets: Download, Set Video Position, Add Events, Recording editor, Check Start and End | `.sheet(item:)` with `Form` (`.formStyle(.grouped)`), Cancel and a default action |
| Delete, Stop and Remove alerts | `.confirmationDialog` or `.alert` with `.destructive` and `.cancel` roles, no destructive default |
| Status capsule | in-window feedback: a small overlay with `.glassEffect()`, plus toolbar progress |
| Downloads scope tabs | `Picker(.segmented)` in the toolbar or `.searchScopes` |
| Notes | inspector `TextEditor`, saved on commit |
| Save MP4 As… | `NSSavePanel` (or `.fileExporter`) copying `clip.mp4` |
| Import a List | `.fileImporter` for JSON |
| Light/dark, accent, Reduce Transparency, Increase Contrast, Reduce Motion | automatic with system components |
| Missing on the web: menu bar | `CommandMenu("Match")` (Preview, Set Video Position…, Download…), `CommandGroup(replacing: .newItem)` (Add Events…, Clip from Link…), View (sidebar, inspector, filters), Help |
| Missing on the web: notifications and Dock badge | `UNUserNotificationCenter` when a job becomes Saved, Needs Review or Failed; `NSApp.dockTile.badgeLabel` = active jobs |
| Missing on the web: Settings | `Settings` scene: library folder, default download options, Open in Browser |
| Missing on the web: SF Symbols and app icon | SF Symbols throughout; icon built with Icon Composer or as `.icns` |

## Phases

Each phase ends in a working, installable app, with the web interface still available for anything not yet ported.

### Phase 0: Groundwork (about 1 session)
- **Backend token file:** write and delete `<library>/.session-token` (0600); honour `MATCH_DOWNLOADER_TOKEN`; add backend tests.
- **Package and build:** create `mac/Package.swift` and `scripts/build-app.sh`. The app runs, starts or attaches to the backend, and shows an empty `NavigationSplitView`.
- **`MatchCore`:**
  - models decoding real fixtures;
  - `APIClient` for every endpoint;
  - `MatchQuery` with tests ported from the JS behaviour (exact Q67, lists, `Q60-Q70` ranges, team search, `R16 1-1`, case-insensitive);
  - formatting helpers.
- **Done when:**
  - `swift test` passes and the Python and Node suites still pass;
  - the app bundle launches against a library copy;
  - quitting the app stops the backend it started.

### Phase 1: Downloads (about 1 session)
- **Sidebar:** Downloads; events listed but not opened yet.
- **Downloads table:** columns, sorting, selection, scope picker, search.
- **Actions:** toolbar and right-click Play (AVPlayer window), Save MP4 As…, Retry, Stop, Delete; Delete key with confirmation.
- **Inspector:** details, the error line for failures, notes.
- **Check Start and End:** AVPlayer, Use Current Time, saving bounds.
- **Feedback:** polling with incremental updates, sidebar badge, Dock badge, notifications.
- **Done when:** every Downloads behaviour listed in `redesign/mac/README.md › Verified` works natively.

### Phase 2: Events and the schedule (1–2 sessions)
- **Sidebar:** On This Mac and Event Catalogue, filtering, Update Catalogue, Add Events sheet (one or many codes or links).
- **Schedule table:** match, division, day, alliances with scores (winner bold), video position, source, download status. Native selection and sorting, with empty values last.
- **Filters and search:** filter pickers, Has Video, search with Return to select.
- **Download sheet:** fixed vs find start and end, search window, before and after, shift; remembered in `@AppStorage`.
- **Match inspector:** alliances, video, choosing a recording, download status, Show in Downloads.
- **Preview window:** the embedded preview page, Go to Match Start, Open in Browser…; Space toggles it.
- **Set Video Position sheet.**
- **Done when:** Q67, QF1-1 and Q60–Q70 selection, a real download from the sheet, and preview at the right time all match the web interface.

### Phase 3: Recordings, Clip from Link, cutover (1–2 sessions)
- **Recordings inspector:**
  - video-position summary, Find Positions Again (auto-run on load as today), Check Event Page Again;
  - discovered links, list of recordings, Add, Edit and Remove.
- **Recording editor:** link, Read Details (probe; choosing from a channel), day, division, field, covers range, match-times basis, sync method (broadcast start, a match, start time, nothing yet), embedded player with Use Player Time and ±10 s, shift, length, use and fill-only options.
- **Other screens:** Clip from Link form, Import a List (`.fileImporter`) with a checklist.
- **Commands and settings:** full menu bar commands and shortcuts, Settings window.
- **Cutover:** `scripts/build-app.sh` produces `Match Downloader.app` from SwiftUI; the WebKit wrapper is retired; README updated.
- **Done when:** the whole verification checklist in `redesign/mac/README.md` passes in the native app.

### Phase 4: Polish and accessibility (about 1 session)
- **VoiceOver:** labels for every icon button and table column; rotor-friendly headings.
- **System settings:** checked with Reduce Transparency, Increase Contrast, Reduce Motion and larger sidebar icon sizes.
- **Window behaviour:** state restoration (last event, selection, column layout, inspector), multiple windows, auto-collapsing the sidebar in narrow windows.
- **Copy:** pass with the apple-design skill (title case for commands, sentence case for messages).

### Phase 5 (later, not in this build): Shareable app (1–2 sessions)
- Bundle a standalone Python with yt-dlp and FFmpeg inside `Contents/Resources`, and move the library to `~/Library/Application Support/Match Downloader` (with migration).
- Developer ID signing and notarization, which needs a paid Apple Developer account. Check FFmpeg build licensing before redistributing.

## iOS readiness (no iOS work now)

An iPhone/iPad app for viewing saved matches is planned later. This build only avoids closing that door:

- **`MatchCore` is platform-neutral.** Models, `APIClient`, `MatchQuery`, labels and formatting import only Foundation (plus Observation if needed), with no AppKit, no `NSWorkspace` and no file-path assumptions about the Mac. `Package.swift` lists `.iOS(.v26)` for `MatchCore`, and the build checks it compiles for iOS: `xcodebuild -scheme MatchCore -destination 'generic/platform=iOS Simulator' build` from `mac/`.
- **`BackendProcess` (starting Python) is Mac-only.** It lives in the app target or behind `#if os(macOS)`, not in the shared core's public surface that an iOS app would use.
- **Small SwiftUI pieces may be portable.** The alliance and score row, status dot and formatted times use SwiftUI only. Mac-only features (`NSSavePanel`, Dock badge, `Table` column customization, menu commands, `Settings`) stay in the Mac app target.
- **Keep the JSON stable.** Add a version field to `/api/health` (for example `"api": 1`) so a future client can check compatibility.
- **Not now:** opening the server to the local network, accounts, iCloud sync, or deciding how the phone gets videos (Mac over Wi-Fi with authentication, iCloud Drive, AirDrop, or a shared folder). That's the first decision of the iOS project, because it changes the security model.

## Testing and verification

- **Unit (`swift test`):**
  - `MatchQuery` cases;
  - model decoding against fixtures captured from a test server;
  - formatting;
  - empty-last sorting.
- **Integration (opt-in):** `APIClient` against `app.py` started on port 8799 with `MATCH_DOWNLOADER_DATA` pointing at a copy of the library.
- **Existing suites must stay green:** `python -m unittest discover -s tests` and `node --test tests/test_preview.mjs`.
- **App checks:** build the bundle, launch it against the library copy (the app accepts `--port` and an `MATCH_DOWNLOADER_DATA` override for this), and drive and screenshot it with the computer-use skill. That needs your approval to control the Mac and Screen Recording permission. Compare against the `redesign/mac/screenshots` set.
- **Never test against the real `library/`,** and never run two servers on the same library.

## Risks

| Risk | Mitigation |
|---|---|
| YouTube/Vimeo previews can't play in AVPlayer | embed the existing `preview.js` page (Decision 5) |
| Python environment missing on another Mac | same requirement as today; Phase 5 removes it |
| Server already running from an old copy or `Start.command` | attach through the token file; if the health check shows another app name, explain how to quit it |
| Loosely structured JSON (stream metadata, analysis) | `JSONValue` for open-ended fields; decode the rest strictly, with fixtures |
| Keeping web and native in sync during migration | web interfaces frozen; native reaches parity phase by phase |
| SwiftUI Table edge cases (custom sort, focus) | `KeyPathComparator`s with optional handling; test keyboard paths early in Phase 1 |

## Settled questions

1. Deployment target: macOS 26 only.
2. Web interfaces: kept as a frozen browser fallback.
3. Bundle identifier: `org.matchdownloader.app`, now.
4. Phase 5: later, not in this build.
5. iOS viewer: later; this build stays iOS-ready only.
