import SwiftUI
import MatchCore

struct PositionSheet: View {
    let event: EventDetail
    let match: Match
    @Bindable var events: EventStore
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var time = ""
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading) {
            Text("Set Video Position for \(Labels.show(match.label))").font(.title2)
            Form { TextField("Recording Link", text: $url); TextField("Position (HH:MM:SS)", text: $time) }.formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Position") { save() }.keyboardShortcut(.defaultAction).disabled(busy || Format.parseClock(time) == nil || url.isEmpty)
            }
        }.padding().frame(width: 480)
        .onAppear { url = match.url ?? ""; time = match.timestamp.map(Format.clock) ?? "" }
    }
    private func save() {
        guard let client = events.client else { return }; busy = true
        Task {
            defer { busy = false }
            do { let result = try await client.calibrate(sku: event.sku, key: match.key, url: url, timestamp: time); if events.event?.sku == event.sku { events.apply(result) }; dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}
