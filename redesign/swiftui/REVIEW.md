# Design review: native Match Downloader

## Summary

Source review: Good, provisional. No Critical or High findings were found in the inspected native source; one Medium runtime diagnostic and two Medium verification gaps remain. This is a dense scouting workspace: select matches in a native schedule, check their recording position, and keep playable offline clips.

This review uses the project's `.claude/skills/apple-design/SKILL.md` and its accessibility, layout, typography, color, designing-for-macos, sidebars, lists-and-tables, sheets, alerts, buttons, writing and Liquid Glass references. It covers source and automated integration, not a visual or assistive-technology audit. The user declined computer use. No screenshots, VoiceOver session or system-setting changes were performed.

## Improvements

- **Medium — Startup table diagnostic.** AppKit emits “Application performed a reentrant operation in its NSTableView delegate” during native integration launches. All workflows completed without a crash. Persistence writes and initial selection restoration were deferred, but the warning remains. Its exact origin has not been isolated between SwiftUI's sidebar and download table. Relevant surfaces are `mac/Sources/MatchDownloader/WorkspaceView.swift` and `DownloadsView.swift`; further diagnosis requires a focused interaction run. `lists-and-tables.md › Desktop` calls for familiar selection, sorting and resizing. Treat the warning as an open compatibility concern, not a failed download or proof of visual breakage.
- **Medium — Accessibility acceptance remains unverified.** Controls use native text labels and SF Symbols; editable notes/import fields and alliance scores/winners have explicit accessibility descriptions. VoiceOver order, announcements and keyboard-only traversal still need a hands-on pass. `accessibility.md › Vision`: “Describe your app’s interface and content for VoiceOver.” Source labels do not establish successful screen-reader operation.
- **Medium — Appearance and restoration acceptance remains unverified.** Native colors, fonts, system materials and controls are used without custom content glass or app animations. Narrow layouts collapse the sidebar and allow horizontal filters; scopes have a menu fallback. Light/dark, Reduce Transparency, Increase Contrast, Reduce Motion, larger sidebar icons, narrow-window rendering and state restoration across real relaunches still need visual checks. `layout.md › Adaptability`: “Design a layout that adapts gracefully and consistently.”
- **Low — Width persistence uses an AppKit bridge.** `TablePersistence.swift` locates the underlying public NSTableView and enables its standard column autosave. SwiftUI TableColumnCustomization separately stores column order/visibility. This keeps native resizing but should be checked after SDK upgrades.

## What works

- NavigationSplitView, List, Table, inspectors, grouped forms, sheets and native commands retain Mac conventions. `designing-for-macos.md › Best practices` calls for the menu bar, resizable windows and keyboard shortcuts. Each workspace owns its event state; library polling is shared.
- Standard table selection and comparison preserve stable row IDs. Exact/range/list/team searches and empty-last sorting are tested, including descending KeyPathComparator behavior. `lists-and-tables.md › Desktop`: “Let people resize columns.”
- Glass is confined to system navigation/controls and the primary Download action. No custom glass is applied to schedule rows. `liquid-glass.md › The two layers` separates content from functional controls.
- Destructive actions have Cancel and no explicit destructive default shortcut; sheets put Cancel before the primary action. `alerts.md › Buttons`: “If there’s a destructive action, include a Cancel button”.
- System text styles and semantic colors avoid fixed small text and custom accent colors. Alliance winner information is available in words as well as weight. `typography.md › Using system fonts` and `accessibility.md › Vision` support these choices.
- Actual native integration verified no-clock review, local trim/playability, failure recovery, fixed downloads, calibration, recording mutations, JSON import, and YouTube Q67 at 3687 seconds. These establish data/media behavior, not untested UI gestures.

## Platform notes

The app targets macOS 26 and Swift 6. MatchCore imports Foundation only and builds for arm64 and x86_64 iOS Simulator. Saved/review media uses AVPlayer; the single recording-preview WKWebView reuses the existing provider player module. The icon is a development placeholder. Self-contained distribution and notarization remain Phase 5.
