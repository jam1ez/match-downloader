import SwiftUI
import MatchCore

/// Trim or extend a saved clip with the same two-thumb slider used for Quick Download.
/// 0:00 is where the saved clip starts now; dragging a thumb outward adds footage, inward removes it.
struct AdjustClipSheet: View {
    let clip: Clip
    @Bindable var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var startAdjust = 0.0
    @State private var endAdjust = 0.0
    @State private var busy = false
    @State private var error: String?

    private var length: Double { max(clip.end - clip.start, 5) }
    private var newLength: Double { length - startAdjust + endAdjust }
    private var extending: Bool { startAdjust < 0 || endAdjust > 0 }
    private var changed: Bool { startAdjust != 0 || endAdjust != 0 }
    private func clock(_ seconds: Double) -> String { let s = Int(abs(seconds).rounded()); return String(format: "%d:%02d", s / 60, s % 60) }

    private var summary: String {
        var parts: [String] = []
        if startAdjust < 0 { parts.append("adds \(clock(startAdjust)) before") }
        if startAdjust > 0 { parts.append("cuts \(clock(startAdjust)) from the start") }
        if endAdjust > 0 { parts.append("adds \(clock(endAdjust)) after") }
        if endAdjust < 0 { parts.append("cuts \(clock(endAdjust)) from the end") }
        guard !parts.isEmpty else { return "Drag either end to trim or extend. The clip is \(clock(length)) long now." }
        return parts.joined(separator: ", ").prefix(1).uppercased() + parts.joined(separator: ", ").dropFirst() + ". New length \(clock(newLength))."
    }
    private var note: String {
        extending ? "Adding footage downloads it again, so it needs internet. Your saved video stays as it is until the new one is ready."
                  : "Trimming happens on this Mac. The cut footage is removed from the saved video; you can extend it again later."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Adjust Clip").font(.title2)
            Text(clip.matchLabel + (clip.eventLabel.isEmpty ? "" : " · " + clip.eventLabel)).foregroundStyle(.secondary).lineLimit(1)
            ClipRangeSlider(startAdjust: $startAdjust, endAdjust: $endAdjust, baseStart: 0, baseEnd: length,
                            startLimits: -min(120, clip.start)...(length - 5), endLimits: -(length - 5)...120)
            HStack(alignment: .firstTextBaseline) {
                Text(summary).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if changed { Button("Reset") { startAdjust = 0; endAdjust = 0 }.buttonStyle(.borderless) }
            }
            if changed { Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Changes") { save() }.keyboardShortcut(.defaultAction).disabled(!changed || busy)
            }
        }
        .padding().frame(width: 480)
    }

    private func save() {
        guard let client = store.client else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await client.adjustClip(clipID: clip.id, start: clip.start + startAdjust, end: clip.end + endAdjust)
                try await store.refresh()
                store.message = extending ? "Downloading the longer clip…" : "Trimming the saved video…"
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
