import SwiftUI
import MatchCore

/// The per-download choices: Quick Download on or off, and the clip's start and end. The set-once
/// values (length, lead-in, search window, global shift) are in Settings → Downloads and Advanced.
struct DownloadOptions: View {
    @AppStorage("download.mode") private var mode = "fixed"
    @AppStorage("download.duration") private var duration = DownloadDefaults.duration
    @AppStorage("download.before") private var before = DownloadDefaults.before
    @AppStorage("download.window") private var window = DownloadDefaults.window
    @AppStorage("download.offset") private var offset = 0.0
    @AppStorage("download.startAdjust") private var startAdjust = 0.0
    @AppStorage("download.endAdjust") private var endAdjust = 0.0
    private func clock(_ seconds: Double) -> String { let s = Int(abs(seconds).rounded()); return String(format: "%d:%02d", s / 60, s % 60) }
    /// Where the clip starts and ends, in plain words, relative to the official match start.
    private var span: String {
        let start = offset - before + startAdjust, end = offset - before + duration + endAdjust
        func edge(_ t: Double) -> String { t < 0 ? "\(clock(t)) before the match" : "\(clock(t)) into the match" }
        return end - start < 5 ? "The end must come after the start." : "From \(edge(start)) to \(edge(end)), \(clock(end - start)) in all."
    }
    private var quick: Binding<Bool> { Binding(get: { mode == "fixed" }, set: { mode = $0 ? "fixed" : "dynamic" }) }
    private func minutes(_ seconds: Double) -> String { String(format: seconds.truncatingRemainder(dividingBy: 60) == 0 ? "%.0f" : "%.1f", seconds / 60) }
    var body: some View {
        // Toggles.md: a switch for an on/off choice, labelled with what it does, with a short explanation beneath.
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Quick Download", isOn: quick).toggleStyle(.switch)
            Text(mode == "fixed"
                 ? "Trusts the official match time and saves about \(minutes(before + duration)) minutes per match. Choose Find Start and End if a match is off."
                 : "Searches around the match to find its start and end. Downloads about \(minutes(90 + window)) minutes per match.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if mode == "fixed" {
            LabeledContent("Clip") {
                ClipRangeSlider(startAdjust: $startAdjust, endAdjust: $endAdjust, baseStart: offset - before, baseEnd: offset - before + duration)
            }
            HStack {
                Text(span).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if startAdjust != 0 || endAdjust != 0 { Button("Reset") { startAdjust = 0; endAdjust = 0 }.buttonStyle(.borderless) }
            }
        }
        if offset != 0 {
            Text("Every download is shifted by \(Int(offset)) seconds (Settings → Advanced).").font(.callout).foregroundStyle(.secondary)
        }
        SettingsLink { Text("Change Download Defaults…") }.buttonStyle(.link)
    }
}
struct DownloadSheet: View {
    let event: EventDetail
    let selected: [Match]
    @Bindable var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("download.mode") private var mode = "fixed"
    @AppStorage("download.duration") private var duration = DownloadDefaults.duration
    @AppStorage("download.before") private var before = DownloadDefaults.before
    @AppStorage("download.tail") private var tail = DownloadDefaults.tail
    @AppStorage("download.window") private var window = DownloadDefaults.window
    @AppStorage("download.offset") private var offset = 0.0
    @AppStorage("download.startAdjust") private var startAdjust = 0.0
    @AppStorage("download.endAdjust") private var endAdjust = 0.0
    @State private var error: String?
    @State private var busy = false
    private var available: [Match] { selected.filter(\.available) }
    var body: some View {
        VStack(alignment: .leading) {
            Text("Download \(Format.plural(available.count, "Match", "Matches"))").font(.title2)
            Text(available.prefix(6).map { Labels.show($0.label) + " " + $0.division }.joined(separator: ", "))
            if selected.count > available.count { Text("\(selected.count - available.count) selected matches have no video position and will be skipped.").foregroundStyle(.secondary) }
            Form { DownloadOptions() }.formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Download") { queue() }.keyboardShortcut(.defaultAction).disabled(busy || available.isEmpty)
            }
        }.padding().frame(width: 480)
    }
    private func queue() {
        guard let client = library.client else { return }; busy = true
        Task {
            defer { busy = false }
            do {
                let result = try await client.queue(QueueRequest(sku: event.sku, keys: available.map(\.key), mode: mode, duration: duration, before: before, tail: tail, window: window, offset: offset, startAdjust: startAdjust, endAdjust: endAdjust))
                try await library.refresh(); library.message = "\(result.added.count) added to Downloads; \(result.skipped.count) already there."; dismiss()
                await DownloadNotifications.askIfNeeded()
            } catch { self.error = error.localizedDescription }
        }
    }
}
