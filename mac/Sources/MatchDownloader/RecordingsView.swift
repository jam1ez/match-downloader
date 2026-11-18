import SwiftUI
import MatchCore

struct RecordingEdit: Identifiable { let id = UUID(); var draft: StreamDraft }
struct RecordingsInspector: View {
    let event: EventDetail
    @Bindable var events: EventStore
    @State private var edit: RecordingEdit?
    @State private var removing: Recording?
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Form {
            Section("Video Positions") {
                Text("\(event.matchesWithVideo) of \(event.matches.count) matches have a position.")
                if let summary = event.streamSummary { Text("\(summary.estimated ?? 0) estimated; \(summary.ambiguous ?? 0) need a recording choice.").foregroundStyle(.secondary) }
                ForEach(event.autoTiming?.messages ?? [], id: \.self) { Text($0) }
                Button("Find Positions Again") { events.update { client, sku in try await client.autoTime(sku: sku) } }.disabled(events.working)
                if events.working { ProgressView("Finding video positions…") }
            }
            Section("Recordings") {
                ForEach(event.recordings) { recording in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(recording.label).font(.headline)
                        Text("\(Format.dayName(recording.date)), \(event.divisions.first { $0.id == recording.divisionId }?.name ?? "All divisions")").foregroundStyle(.secondary)
                        Text(syncText(recording)).foregroundStyle(.secondary)
                        HStack {
                            Button("Edit…") { edit = RecordingEdit(draft: StreamDraft(editing: recording)) }
                            Button("Preview") { preview(recording) }
                            Button("Remove…", role: .destructive) { removing = recording }
                        }
                    }
                }
                if event.recordings.isEmpty { Text("None added. Add a recording when the event feed has no video positions.").foregroundStyle(.secondary) }
                Button("Add Recording…") { edit = RecordingEdit(draft: StreamDraft(date: event.allDays.first ?? "")) }
            }
            Section("Links on the Event Page") {
                if let description = event.discovery?.description, !description.isEmpty { Text(description).textSelection(.enabled) }
                ForEach(Array((event.discovery?.candidates ?? []).enumerated()), id: \.offset) { _, candidate in
                    VStack(alignment: .leading) {
                        Text(candidate.label ?? candidate.url).font(.headline)
                        Text("\(candidate.platform), \(candidate.source ?? "event page")").foregroundStyle(.secondary)
                        if event.recordings.contains(where: { $0.url == candidate.url }) { Text("Added") }
                        else { Button("Add…") { editCandidate(candidate) } }
                    }
                }
                ForEach(event.discovery?.errors ?? [], id: \.self) { Text($0).foregroundStyle(.secondary) }
                Button("Check Event Page Again") { events.update { client, sku in try await client.discoverStreams(sku: sku, refresh: true) } }.disabled(events.working)
            }
        }.formStyle(.grouped)
        .sheet(item: $edit) { item in RecordingEditor(event: event, events: events, initial: item.draft) }
        .confirmationDialog("Remove “\(removing?.label ?? "Recording")”?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let recording = removing { events.update { client, sku in try await client.deleteStream(sku: sku, id: recording.id) } }; removing = nil }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { Text("Matches lose the positions this recording provided. Downloaded videos stay on this Mac.") }
    }
    private func preview(_ recording: Recording) {
        guard let port = events.client?.baseURL.port else { return }
        openWindow(value: PreviewItem(title: recording.label, url: recording.url, target: 0, port: port))
    }
    private func editCandidate(_ candidate: DiscoveryCandidate) {
        let index = candidate.dayIndex ?? 0
        let date = event.allDays.indices.contains(index) ? event.allDays[index] : event.allDays.first ?? ""
        var metadata: [String: JSONValue] = [:]
        if let start = candidate.streamStartTime { metadata["startEstimate"] = .string(start) }
        edit = RecordingEdit(draft: StreamDraft(label: candidate.label ?? "", url: candidate.url, date: date, divisionId: candidate.divisionId ?? "*", metadata: .object(metadata)))
    }
    private func syncText(_ r: Recording) -> String {
        if !r.isEnabled { return "Not used" }
        switch r.syncMode {
        case "none": return "Not lined up"
        case "auto": return r.metadata?.startEstimate.map { "Broadcast began \($0)" } ?? "No broadcast start found"
        case "anchor": return "Lined up on \(event.matchesByKey[r.anchorKey ?? ""]?.label ?? "a match") at \(Format.clock(r.anchorPosition ?? 0))"
        default: return "Began \(r.wallStart ?? "")"
        }
    }
}

struct RecordingEditor: View {
    let event: EventDetail
    @Bindable var events: EventStore
    @State private var draft: StreamDraft
    @State private var duration = ""
    @State private var position = "0"
    @State private var error: String?
    @State private var busy = false
    @State private var channels: [ChannelRecording] = []
    @State private var channel = ""
    @State private var playerItem: PreviewItem?
    @State private var bridge = PreviewBridge()
    @Environment(\.dismiss) private var dismiss
    init(event: EventDetail, events: EventStore, initial: StreamDraft) {
        self.event = event; self.events = events; _draft = State(initialValue: initial)
        _duration = State(initialValue: initial.duration.map { String($0) } ?? "")
        _position = State(initialValue: Format.clock(initial.anchorPosition))
    }
    private var scoped: [Match] {
        event.matches.filter { (draft.divisionId == "*" || $0.divisionId == draft.divisionId) && Labels.day($0) == draft.date && (draft.field.isEmpty || $0.field == draft.field) }.sorted {
            (draft.basis == "scheduled" ? $0.scheduled : $0.started ?? $0.scheduled) ?? "9999" < (draft.basis == "scheduled" ? $1.scheduled : $1.started ?? $1.scheduled) ?? "9999"
        }
    }
    private var anchorMatches: [Match] {
        var matches = scoped
        if let index = matches.firstIndex(where: { $0.key == draft.firstMatch }) { matches = Array(matches[index...]) }
        if let index = matches.firstIndex(where: { $0.key == draft.lastMatch }) { matches = Array(matches[...index]) }
        return matches
    }
    var body: some View {
        VStack(alignment: .leading) {
            Text(draft.id == nil ? "Add Recording" : "Edit Recording").font(.title2)
            Form {
                Section("Recording") {
                    TextField("Link", text: $draft.url)
                    Button("Read Details") { probe() }.disabled(busy || draft.url.isEmpty)
                    if !channels.isEmpty {
                        Picker("Recording from Channel", selection: $channel) { Text("Choose…").tag(""); ForEach(channels) { Text($0.title ?? $0.url).tag($0.url) } }
                        Button("Use Recording") { draft.url = channel; channels = []; probe() }.disabled(channel.isEmpty)
                    }
                    TextField("Name", text: $draft.label)
                    if let title = draft.metadata["title"]?.string { Text(title).foregroundStyle(.secondary) }
                    TextField("Day (YYYY-MM-DD)", text: $draft.date)
                    Picker("Division", selection: $draft.divisionId) { Text("All Divisions").tag("*"); ForEach(event.divisions) { Text($0.name).tag($0.id) } }
                    Picker("Field", selection: $draft.field) { Text("All Fields").tag(""); ForEach(Array(Set(event.matches.compactMap(\.field).filter { !$0.isEmpty })).sorted(), id: \.self) { Text($0).tag($0) } }
                    Picker("Match Times", selection: $draft.basis) { Text("Actual Start").tag("actual"); Text("Scheduled Start").tag("scheduled") }
                    Picker("First Match", selection: $draft.firstMatch) { Text("Start of the Day").tag(""); ForEach(scoped) { Text("\(Labels.show($0.label)), \($0.division)").tag($0.key) } }
                    Picker("Last Match", selection: $draft.lastMatch) { Text("End of the Day").tag(""); ForEach(scoped) { Text("\(Labels.show($0.label)), \($0.division)").tag($0.key) } }
                }
                Section("Line Up Recording") {
                    Picker("Sync Method", selection: $draft.syncMode) {
                        Text("Broadcast Start").tag("auto"); Text("A Match").tag("anchor"); Text("Start Time").tag("wallclock"); Text("Nothing Yet").tag("none")
                    }
                    if draft.syncMode == "anchor" {
                        Picker("Sync Match", selection: $draft.anchorKey) { Text("Choose a Match").tag(""); ForEach(anchorMatches) { Text("\(Labels.show($0.label)), \($0.division)").tag($0.key) } }
                        TextField("Position (HH:MM:SS)", text: $position)
                    }
                    if draft.syncMode == "wallclock" {
                        TextField("Recording Began", text: $draft.wallStart, prompt: Text("2026-11-18T09:00:00-08:00"))
                        Button("Use Broadcast Start") { draft.wallStart = draft.metadata["startEstimate"]?.string ?? "" }.disabled(draft.metadata["startEstimate"]?.string == nil)
                    }
                    Button(playerItem == nil ? "Show Player" : "Hide Player") {
                        if playerItem != nil { playerItem = nil }
                        else if let port = events.client?.baseURL.port { playerItem = PreviewItem(title: draft.label, url: draft.url, target: Format.parseClock(position) ?? 0, port: port) }
                    }.disabled(draft.url.isEmpty)
                    if let item = playerItem {
                        EmbeddedPreview(item: item, bridge: bridge).frame(height: 260)
                        Text(bridge.message).foregroundStyle(.secondary)
                        HStack {
                            Button("Back 10 Seconds", systemImage: "gobackward.10") { step(-10) }
                            Button("Use Player Time") { Task { do { position = Format.clock(try await bridge.currentTime()) } catch { self.error = error.localizedDescription } } }
                            Button("Forward 10 Seconds", systemImage: "goforward.10") { step(10) }
                        }.disabled(!bridge.ready)
                    }
                    TextField("Shift (seconds)", value: $draft.offset, format: .number)
                    TextField("Length (seconds, optional)", text: $duration)
                    Toggle("Use This Recording", isOn: $draft.enabled)
                    Toggle("Fill Gaps Only", isOn: $draft.fillOnly)
                }
            }.formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack { if busy { ProgressView().controlSize(.small) }; Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Recording") { save() }.keyboardShortcut(.defaultAction).disabled(busy || draft.url.isEmpty)
            }
        }.padding().frame(width: 620).frame(minHeight: 440, idealHeight: 660, maxHeight: 720)
        .onChange(of: draft.url) { _, _ in draft.metadata = .object([:]); playerItem = nil; channels = []; duration = ""; position = ""; draft.wallStart = "" }
        .onChange(of: draft.divisionId) { _, _ in clearScope() }
        .onChange(of: draft.date) { _, _ in clearScope() }
        .onChange(of: draft.field) { _, _ in clearScope() }
    }
    private func clearScope() { draft.firstMatch = ""; draft.lastMatch = ""; draft.anchorKey = "" }
    private func step(_ seconds: Double) {
        Task { do { bridge.seek(try await bridge.currentTime() + seconds) } catch { self.error = error.localizedDescription } }
    }
    private func probe() {
        guard let client = events.client else { return }; busy = true; error = nil
        let url = draft.url
        Task {
            defer { busy = false }
            do {
                let info = try await client.probeStream(url: url).metadata
                guard draft.url == url else { return }
                draft.metadata = info.raw
                if draft.label.isEmpty { draft.label = info.title ?? "" }
                duration = info.duration.map { String($0) } ?? ""
                channels = info.recordings
            } catch { self.error = error.localizedDescription }
        }
    }
    private func save() {
        guard let client = events.client else { return }
        guard (draft.syncMode != "anchor" || Format.parseClock(position) != nil), duration.isEmpty || Format.parseClock(duration) != nil else { error = "Enter seconds or HH:MM:SS for the position and length."; return }
        draft.anchorPosition = Format.parseClock(position) ?? 0; draft.duration = duration.isEmpty ? nil : Format.parseClock(duration)
        busy = true; error = nil
        let saving = draft
        Task {
            defer { busy = false }
            do { let result = try await client.saveStream(sku: event.sku, stream: saving); if events.event?.sku == event.sku { events.apply(result) }; dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}
