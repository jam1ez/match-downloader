# Match Downloader for Mac: macOS 27 prototype

The interface in the macOS 27 design language (Liquid Glass), built on Apple's Human Interface Guidelines. It is now the app's default interface, and the app is called Match Downloader. All interfaces share the same local server and library:

| Address | What it is |
|---|---|
| `/` (also `/mac`) | This interface (`web/mac/`), the default |
| `/next` | First redesign (`web/next/`), unchanged |
| `/classic` | Original interface (`web/index.html`), unchanged |

## Run it

1. Open **Match Downloader.app**, or run `.venv/bin/python app.py`. It opens at **http://127.0.0.1:8766/**.
2. In a browser, Safari shows it closest to the Mac app, because both use WebKit with your system accent colour.

Deep links: `/#/event/RE-V5RC-25-0147`, `/#/downloads`, `/#/clip`. To try it on a copy of your library, run `MATCH_DOWNLOADER_DATA=/tmp/md-test .venv/bin/python app.py --port 8799`. Don't point two servers at the same library: each runs its own download queue.

## Sources

- Apple HIG pages read directly (JSON form): Sidebars, Toolbars, Lists and tables, Sheets, Alerts, Search fields, Typography, Color, Buttons, Keyboards, Menus, Context menus, Materials, Scroll views, Designing for macOS, and Adopting Liquid Glass (partly). The "What's new" page confirms the macOS 27 UI kits (Figma, Sept 17 2026) and the June 2026 updates to sidebars, scroll edge effects and menus.
- The `apple-design` skill (dickwu/apple-design-skill, installed in `.claude/skills/apple-design`): its offline HIG pages and its Liquid Glass guide, including the web translation and review checklist.
- Apple publishes no pixel values for macOS 27 radii, toolbar height or control sizes; those live in the Figma and Sketch kits. Every such number below is a judgment, chosen to be concentric and rounder as the HIG describes.

## Audit of the first redesign (`/next`) against the HIG

Severity follows the apple-design skill's scale.

**High**
- **Navigation isn't Mac-like.** Top tabs plus a separate event rail make two navigation systems. A Mac app uses one sidebar holding sections and items, at most two levels deep (`sidebars.md`).
- **Selection is web-style.** Checkboxes and a yellow highlighter, with no click, ⌘-click or ⇧-click selection, no arrow keys, no Space to preview, no ⌘A and no context menus. macOS highlights selected rows in the accent colour, grey when the list isn't focused (`focus-and-selection.md`, `context-menus.md`).
- **The primary action sits in a bottom bar.** Apple advises keeping critical actions out of the bottom of the window. The primary action belongs at the trailing end of the toolbar (`toolbars.md`, `sidebars.md › Desktop`).
- **Actions repeat on every row.** Preview and Adjust buttons appear on all 381 rows. Mac tables act on the selection through the toolbar, the inspector or a context menu.
- **Colours are hard-coded.** They ignore the user's accent colour, and the custom yellow selection contradicts the platform's selection colour (`color.md`).

**Medium**
- Pop-up toasts instead of feedback in the window (`feedback.md`).
- Dialogs close from a top-right "Close" button instead of Cancel and the primary action at the bottom trailing edge (`sheets.md`, `alerts.md`).
- Buttons and titles use sentence case where Apple uses title case (`writing.md`).
- Columns can't be sorted or resized (`lists-and-tables.md › Desktop`).
- 14 px body text instead of 13 pt (`typography.md`).
- The "Add an event" form sits at the bottom of the event list (`sidebars.md`).

**What worked and was kept:** the dense schedule, the alliance and score treatment, plain-language labels, deep links, light and dark modes, and live download status.

## What this prototype does

**Two layers** (`liquid-glass.md › The two layers`)
- **Content layer:** the schedule and download tables sit on an opaque canvas with no glass. Rows are 28 px with rounded ends and alternating fills, and selection uses the accent colour.
- **Functional layer:** regular Liquid Glass on the floating sidebar, the toolbar controls, the filter bar, the inspector, sheets, alerts, menus and the status capsule. Glass is never stacked on glass: controls inside panels use plain fills.
- **Scroll edge effect:** rows blur and fade as they pass under the floating controls, with no solid toolbar background (`scroll-views.md`).

**Layout**
- **Sidebar:** a floating glass panel holding Downloads, Clip from Link, On This Mac (events you've opened) and the Event Catalogue. It filters from the top and collapses automatically below 1000 px (`sidebars.md`).
- **Toolbar:**
  - leading edge: sidebar toggle, then the title and subtitle;
  - middle: one glass group of symbol buttons;
  - trailing edge: one prominent **Download…**, the search field and the inspector toggle (`toolbars.md`).
- **Filter bar:** a glass capsule with the division, round and day pop-ups and a "Has Video" chip.
- **Inspector:** a floating glass panel for the selected match, the event's recordings, or the selected download and its notes.

**Interaction**
- **Selection:** click, ⌘-click, ⇧-click, arrow keys, ⇧-arrow, Home, End, Page Up and Page Down, ⌘A, and Esc to deselect.
- **Shortcuts:** Space or double-click previews (Space closes it again), Delete removes with an alert, ⌥⌘I toggles the inspector, ⌃⌘S the sidebar, and ⌘F focuses search.
- **Search:** filters as you type, and Return selects the matches shown that have video.
- **Menus:** right-click menus with at most three groups and title-case labels.
- **Columns:** sortable and resizable, with empty values kept last in both directions.
- **Feedback:** a floating status capsule shows counts and results.
- **Sheets:** Cancel then the primary action, trailing. Alerts never make a destructive button the default (`buttons.md`).
- **Motion:** spring press feedback, a sliding segmented thumb, sheets that scale in, menus that grow from the pointer, and panels that slide in. All of it is off under Reduce Motion.

**Colour and type**
- **Text:** system font, with Body 13/16, Callout 12, Subheadline 11, Headline 13 semibold, Title 3 15 and Title 2 20 (`typography.md › macOS built-in text styles`).
- **Accent:** in WebKit (Safari and the Mac app) the page uses Apple's own system colours: your accent for icons, the selected-content colour for selection and filled buttons, and the system focus ring. WebKit can't blend system colours with `color-mix()`, which made selection and the Download button disappear in an earlier pass; the WebKit renders caught it.

**Contrast, measured**

| Element | Ratio |
|---|---|
| Secondary text on canvas, rows and panels | 4.8–4.9:1 |
| White on filled blue | 4.8–5.4:1 |
| Accent-coloured text | 4.7:1 |

Raw system blue under white text measures 3.5–4.0:1, so the page doesn't use it for text.

**Accessibility states:** Increase Contrast and Reduce Transparency replace glass with opaque surfaces and stronger edges. Reduce Motion removes animation.

## Deviations and limits

- **No menu bar.** A web page can't add native menu-bar commands, and the HIG wants every toolbar command in the menu bar. Right-click menus, the inspector and keyboard shortcuts stand in for now; real menu commands would need the Swift wrapper (`tools/Desktop.swift`) to forward them.
- **No SF Symbols.** The icons are original line drawings in a similar weight. Apple's resources page states no licence for using SF Symbols on the web.
- **Reduce Transparency in the Mac app.** WebKit doesn't report this setting to web pages, so inside Match Downloader.app it needs the Swift wrapper to pass it through. Chromium-based browsers report it.
- **Secondary text is darker than Apple's 50% grey,** which measures 3.9:1, so it passes WCAG.
- **Window chrome.** The Mac app still shows a standard title bar above the page. A unified, full-height look needs a change in `Desktop.swift`.

## Verified

The checks ran on a copy of the library, in Chrome and through a WKWebView render:
- Table selection, keyboard model, sorting, resizing and context menu.
- Filters, the "Has Video" chip, and search with Return to select.
- **Download sheet:** a real fixed-length YouTube download, saved and played back offline (10 s).
- Setting a video position.
- Recordings: add from a discovered link, add, edit and remove through the alert.
- **Downloads:**
  - inspector, notes and playback (Space);
  - Saved scope and search;
  - Delete key with an alert;
  - a failing source showing its real error, then retry, then stop.
- **Check Start and End:** a real detect-mode job on a video with no clock went to Needs Review, was trimmed from bounds marked in the sheet, and was saved.
- Clip from Link validation, JSON import preview, and Add Events reporting a bad code.
- Quick Look–style preview opening YouTube at Q67, with Space to close.
- Narrow windows at 900 px and below, and light and dark appearances.

The Python and Node test suites pass.

Not verified:
- screen-reader announcements;
- the in-editor sync player against every provider;
- Increase Contrast and Reduce Transparency rendering;
- interaction inside a focused Match Downloader.app window. The WebKit renders come from an off-screen view, which can't show focus colours or run transitions, so they were taken with transitions off.

## Screenshots

In `screenshots/`, at 1440×900 unless noted:

| File | Shows |
|---|---|
| `mac-1-event.png` | Q60–Q70 selected (accent selection), inspector summary |
| `mac-2-context-menu.png` | Right-click menu |
| `mac-3-download-sheet.png` | Download sheet |
| `mac-4-match-inspector.png` | One match in the inspector |
| `mac-5-recordings.png` | Recordings in the inspector |
| `mac-6-scroll-edge.png` | Rows passing under the floating controls |
| `mac-7-downloads.png` | Downloads with details and notes |
| `mac-8-recording-editor.png` | Add Recording sheet |
| `mac-9-dark.png`, `mac-10-dark-downloads.png` | Dark appearance |
| `mac-11-narrow.png`, `mac-13-narrow-sidebar.png` | 900 px window, sidebar as overlay |
| `mac-12-clip.png` | Clip from Link |
| `mac-14-webkit-light.png`, `mac-15-webkit-dark.png` | Rendered by WebKit (WKWebView), the Mac app's engine |
| `compare-next-vs-mac.png`, `compare-library-next-vs-mac.png` | First redesign (left) and this one (right) |
