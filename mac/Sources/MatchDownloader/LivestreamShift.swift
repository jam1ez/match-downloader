import SwiftUI
import MatchCore

/// One slider that moves every match's video position in the event at once, for a livestream whose times
/// are all early or late by the same amount. Saved on release; the stepper nudges by a second.
/// Matches you positioned yourself (Set Video Position…) don't move.
struct LivestreamShift: View {
    let event: EventDetail
    @Bindable var events: EventStore
    @State private var draft = 0.0
    private let limit = 300.0
    private var saved: Double { event.timingOffset ?? 0 }

    static func describe(_ seconds: Double) -> String {
        let s = Int(abs(seconds).rounded())
        guard s > 0 else { return "No shift" }
        let amount = s >= 60 ? String(format: "%d:%02d", s / 60, s % 60) : "\(s) s"
        return seconds > 0 ? "\(amount) later" : "\(amount) earlier"
    }
    private func commit(_ value: Double) {
        let value = min(max(value.rounded(), -limit), limit)
        draft = value
        guard value != saved else { return }
        events.update { client, sku in try await client.setTimingOffset(sku: sku, offset: value) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Shift All Matches").font(.headline)
                Spacer()
                Text(Self.describe(draft)).font(.callout).monospacedDigit().foregroundStyle(draft == 0 ? .secondary : .primary)
            }
            HStack(spacing: 8) {
                Slider(value: $draft, in: -limit...limit, step: 1) { Text("Shift All Matches") }
                    minimumValueLabel: { Text("−5m").font(.caption2) } maximumValueLabel: { Text("+5m").font(.caption2) }
                    onEditingChanged: { editing in if !editing { commit(draft) } }
                    .labelsHidden()
                    .accessibilityValue(Self.describe(draft))
                Stepper("Shift by One Second", value: Binding(get: { draft }, set: { commit($0) }), in: -limit...limit, step: 1).labelsHidden()
            }
            HStack {
                Text("Moves every video position if the livestream is early or late. Positions you set yourself stay.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if saved != 0 { Button("Reset") { commit(0) }.buttonStyle(.borderless) }
            }
        }
        .disabled(events.working)
        .onChange(of: saved, initial: true) { _, value in draft = value }
        // A save that failed leaves the slider where the engine still has it.
        .onChange(of: events.working) { _, working in if !working { draft = saved } }
    }
}
