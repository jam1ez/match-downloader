# Debugging criteria

For anyone (human or Claude session) fixing or verifying a change in this project. It is built from bugs that
actually happened here; each rule names the failure that taught it.

## 0. Ground rules

- **Never touch the real `library/`.** Test against a copy or a temp directory: `MATCH_DOWNLOADER_DATA=<dir>`
  and port **8799**. Never run two engines on one library.
- **Don't switch branches.** Other work is often uncommitted in the same tree. Stage only your own hunks
  (`git hash-object -w` + `git update-index --cacheinfo` for files with mixed edits) and commit only when asked.
- **No screenshots or computer use** unless the user asks; they send their own. Say plainly what you could not
  look at ("not verified by eye").
- Keep command output short (`tail`, `grep`).

## 1. Reproduce before fixing

A fix is only trusted if the failure was reproduced first and the same check passes afterwards.

- Write the check so it fails on the old code (the arrow-key bug: a headless test that sends real key events
  failed with a one-frame step until the key monitor existed).
- Prefer a headless check over reading code: a unit test, a `--verify-*` run, or an HTTP call to a temp engine.
- For a user-reported symptom, find the layer first: **Swift UI → `MatchCore` client → Python engine → yt-dlp /
  ffmpeg / the stream site.** Check the engine with `curl` before blaming the UI.

## 2. Checks to run, by change

| Change | Run |
|---|---|
| Python engine (`app.py`, `events.py`, `event_streams.py`, `worlds.py`, `boundaries.py`, `webcast.py`, `auto_timing.py`) | `python3 -m unittest discover -s tests` |
| Preview page (`web/preview.js`, `web/embed/preview.html`) | `node --test tests/test_preview.mjs` |
| Swift model / client / math (`mac/Sources/MatchCore`) | `cd mac && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --disable-sandbox` |
| Swift app target | `swift build --disable-sandbox` — the build must have **no warnings** (Swift 6 strict concurrency) |
| Player keys / playback | `.build/debug/MatchDownloader --verify-player <short.mp4>` → `VERIFY_PLAYER_PASS` |
| Native client against an engine | `--verify-recordings`, `--verify-schedule`, `--verify-downloads`, `--smoke-test` (temp library, port 8799) |
| Anything shipped | `mac/scripts/build-app.sh`, then `codesign --verify --deep --strict` on the bundle |

Toolchain: `swift` needs `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (the command-line tools alone
fail with "cannot infer contextual base … v26").

Before committing, check the **staged** state, not the working tree: `git checkout-index -a --prefix=<tmp>/` and
build/test that copy, because other uncommitted files can hide a missing dependency.

## 3. Known failure patterns

Look here first when a symptom matches.

| Symptom | Cause | Check / fix |
|---|---|---|
| App says engine is too old, or a new endpoint returns "not found" | A stale engine from an earlier app is still on 8766 | Compare `API_VERSION` (app `engineAPI`) with the engine; stop it with `pkill -f "app.py --port 8766"`; bump `API_VERSION` when adding endpoints |
| Wrong video in preview/download, "match time is beyond the end" | Vimeo event links `/event/<eventId>/video/<videoId>`: the event id was used as the video id | Use the id after `/video/` (`event_streams.media_url`, `preview.js`, Swift link) |
| "Login required" / 401 from Vimeo player, yt-dlp "web client only works when logged-in" | Recording is login/embed restricted | Not a bug to bypass: show the friendly message, offer Open in Browser. Don't add cookie/referer workarounds |
| Progress bar jumps or sits below its track | Per-pass progress not monotone; fill drawn outside the track with an implicit animation | Clamp monotone, combine passes (`job_progress`), draw `BarFill` in the track rect, no animation |
| Arrow keys move one frame / space does nothing in a player | `AVPlayerView` (or a web page) hands focus to an inner view | Window-scoped key monitor (`KeyRouter`), not `keyDown` overrides |
| Quit hangs with "Quit" pending | `.terminateLater` and the GCD main queue not served in modal mode | `RunLoop.main.perform(inModes:)` |
| Engine keeps running or dies at the wrong time | Managed engine (`MATCH_DOWNLOADER_MANAGED=1`) exits when idle after quit; attach cancels that | Check `quitWhenIdle` and the job queue |
| App bundle won't sign | File Provider xattrs | `xattr -cr`, `xattr -d com.apple.FinderInfo`, then verify in a loop |
| Download slower than expected | Software encode or non-H.264 source | `video_encoders()` (VideoToolbox first), the `avc1` format selector, `MAX_PARALLEL` |
| Positions off for a whole event | Livestream offset or a wrong recording | `timingOffset` per event; Livestream section "Change…" |

## 4. What counts as verified

State each in the report; do not blur them.

- **Verified**: a test, headless check or HTTP call that ran, and what it showed (numbers, not "looks fine").
- **Built only**: compiles, not exercised.
- **Not verified by eye**: anything visual (layout, hover bars, sheets, window sizes) — say so.
- **Not verified live**: real YouTube/Vimeo/BoxCast behaviour that tests fake out.

A fix is done when: the repro now passes, the relevant checks in section 2 pass, no new warnings, and the
progress log `redesign/swiftui/PROGRESS.md` has a short entry (cause, fix, what was and wasn't verified).

## 5. When stuck

- Read the job's `detail` and its `<library>/<job id>/job.log` before guessing.
- Check yt-dlp/ffmpeg directly on the URL with the same arguments the engine uses.
- One hypothesis at a time; remove temporary logging; leave no debug code in a commit.
- If a request needs bypassing a site's access controls, stop and tell the user instead.

## 6. Open findings from the 2026-11-19 audit (no fixes applied)

Scope: current working tree, including existing uncommitted edits. The checks used a fresh temporary
`MATCH_DOWNLOADER_DATA` directory and called `Handler.do_POST` directly with in-memory JSON requests.
No server, download worker, network request, or real media encode was started. The real `library/`
and port 8766 were not used. These are focused findings, not an exhaustive audit.

### DBG-001 - Cancelling a queued adjustment leaves the saved clip in an inconsistent state

- Priority: P2. Status: reproduced through the Python request handler.
- Location: `app.py`, `/api/clips/<id>/adjust`, `/cancel`, and `process_adjust`.
- Trigger: a ready clip has bounds 100-200. Submit an adjustment to 110-190, then cancel while it is
  still queued (before a worker claims it).
- Observed: both operations return 200. The database retains `start=110`, `end=190`,
  `clip_mode=adjust`, and `status=cancelled`; the original `clip.mp4` bytes remain unchanged.
- Cause: adjustment overwrites the bounds immediately and stores the old values in `detect_settings`.
  Cancel only changes status. Restoration happens inside `process_adjust` or startup recovery for
  active statuses; a queued adjustment cancelled before execution reaches neither path.
- Impact: the saved video survives, but the ready state and bounds no longer describe it. Startup
  recovery excludes cancelled rows, so restarting does not restore this case either.
- Future verification: repeat this sequence with a real short MP4 and assert original bounds, mode,
  saved status, and file bytes after cancellation and after restarting the temporary engine.

### DBG-002 - Switching events during automatic timing can leave editing disabled

- Priority: P2. Status: source-supported hypothesis; not exercised in the native app.
- Location: `mac/Sources/MatchDownloader/EventStore.swift:38-64`; route changes launch loads from
  `mac/Sources/MatchDownloader/WorkspaceView.swift:61`.
- Trigger: event A reaches automatic timing and sets `working=true`. Open event B before A's timing
  response returns. B already has timing, or its load fails, so B never enters its automatic-timing block.
- Cause: B replaces `loadID`. A's deferred cleanup clears `working` only if A still owns `loadID`.
  B's load does not reset `working` on entry or on its ordinary completion/error paths.
- Expected consequence: `working` can remain true after both requests finish. `update` rejects edits
  while it is true, and recording controls bound to that flag remain disabled.
- Future verification: use delayed responses for A's auto-time and an already-timed B. Complete both
  responses and assert that `working` is false and an edit to B can run. Also cover B load failure.

### DBG-003 - A successful library poll does not clear a previous connection error

- Priority: P2. Status: source-supported hypothesis; not exercised in the native app.
- Location: `mac/Sources/MatchDownloader/LibraryStore.swift:19-44`.
- Trigger: a polling request fails once, then the next request succeeds with FFmpeg available.
- Cause: polling writes the failure into `error`; `refresh()` updates library contents and readiness
  but never clears that error on success. `perform()` clears it only when another operation starts.
- Expected consequence: the error can remain visible even while clip data and storage values update
  normally, making a recovered connection appear broken.
- Future verification: script one failed library response followed by a successful response; assert
  recovered data and cleared connection error. Keep missing-FFmpeg and operation errors distinct.

### DBG-004 - Manual clip creation accepts less than the documented minimum duration

- Priority: P3. Status: reproduced through the Python request handler.
- Location: `app.py`, POST `/api/clips`.
- Trigger: submit `title="tiny"`, `url="https://example.com/video"`, `start=0`, `end=0.1`.
- Observed: HTTP response status 201 and a queued clip, despite validation text saying to choose a
  clip between 1 second and 1 hour.
- Cause: validation rejects `end<=start` and durations over 3600, but accepts every positive fraction.
- Impact: API callers can queue intervals below the stated minimum. Actual encoding success or failure
  for such intervals was not tested.
- Future verification: check durations 0, 0.1, 0.999, 1, 3600, and 3600.001 against the agreed limits.

Verification limits: no fixes, builds, full test suites, live provider checks, screenshots, or computer
use were performed for this audit. Native findings are not verified by eye. Python reproductions used
sentinel file bytes, not playable video. Preserve these distinctions when working on the findings.


### Resolution update - 2026-11-19

DBG-001 through DBG-004 have fixes and regression coverage. Both native hypotheses were reproduced
with controlled responses before applying their fixes. See the 2026-11-19 audit-fixes entry in
`redesign/swiftui/PROGRESS.md` for implementation and verification details. The original observations
above describe the pre-fix tree and remain here as reproduction history. No visual checks were run.
