import SwiftUI
import AVKit
import UniformTypeIdentifiers
import MatchCore

struct DownloadsView: View {
    @Bindable var store: LibraryStore
    @SceneStorage("downloads.selection") private var savedSelection = ""
    @State private var selection: Set<String> = []
    @State private var search = ""
    @State private var scope = "all"
    @AppStorage("downloads.sort") private var savedSort = "[]"
    @State private var sort = [KeyPathComparator(\Clip.created, order: .reverse)]
    @SceneStorage("downloads.columns") private var columns: TableColumnCustomization<Clip>
    @AppStorage("inspector.visible") private var inspector = true
    @State private var confirmation: String?
    @State private var actionIDs: Set<String> = []
    @State private var review: Clip?
    @Environment(\.openWindow) private var openWindow

    private var selected: [Clip] { store.clips.filter { selection.contains($0.id) } }
    private func inScope(_ clip: Clip, _ scope: String) -> Bool {
        switch scope {
        case "active": clip.isActive
        case "ready": clip.status == "ready"
        case "needs_review": clip.status == "needs_review"
        case "failed": clip.status == "failed" || clip.status == "cancelled"
        default: true
        }
    }
    private var rows: [Clip] {
        store.clips.filter { inScope($0, scope) && (search.isEmpty || ($0.title + " " + ($0.notes ?? "") + " " + Labels.status($0.status)).localizedCaseInsensitiveContains(search)) }.sorted(using: sort)
    }
    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
            scopePicker.pickerStyle(.segmented)
            scopePicker.pickerStyle(.menu)
            }.padding(.horizontal, 14).padding(.vertical, 10)
            Table(rows, selection: $selection, sortOrder: $sort, columnCustomization: $columns) {
                TableColumn("Match", value: \.matchLabel).width(min: 80, ideal: 140).customizationID("title")
                TableColumn("Division", value: \.divisionLabel).width(min: 80, ideal: 110).customizationID("division")
                TableColumn("Event", value: \.eventLabel).width(min: 140, ideal: 240).customizationID("event")
                TableColumn("Status", value: \.statusLabel) { clip in
                    StatusCell(clip: clip)
                }.width(min: 100, ideal: 150).customizationID("status")
                TableColumn("Part of Recording") { Text($0.recordingRange).monospacedDigit() }.customizationID("range")
                TableColumn("Size", value: \.bytes) { Text(Format.size(Int64($0.bytes))).monospacedDigit() }.customizationID("size")
                TableColumn("Added", value: \.created) { Text($0.createdDate, style: .date) }.customizationID("added")
            }
            .overlay { if rows.isEmpty { ContentUnavailableView(store.clips.isEmpty ? "No Downloads Yet" : "No Matching Downloads", systemImage: "arrow.down.circle", description: Text(store.clips.isEmpty ? "Select matches in an event and choose Download, or choose Clip from Link." : "Try another search or download scope.")).allowsHitTesting(false) } }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
            .mutedSelection()
            .background(TablePersistence(name: "DownloadsTable"))
            .contextMenu(forSelectionType: String.self) { ids in actions(ids) } primaryAction: { ids in play(ids) }
            .onKeyPress(.space) { play(selection); return .handled }
            .onKeyPress(.return) { play(selection); return .handled }
            .onDeleteCommand { ask("Delete", selection) }
            .onExitCommand { selection = [] }
        }
        .background(Theme.canvas)
        .navigationTitle("Downloads")
        .navigationSubtitle(store.message)
        .searchable(text: $search, placement: .toolbar, prompt: "Search Downloads")
        .toolbar {
            Button("Play", systemImage: "play") { play(selection) }.disabled(!selected.contains { $0.status == "ready" })
            Menu { actions(selection) } label: { Label("Download Actions", systemImage: "ellipsis.circle") }.disabled(selection.isEmpty)
            Button(inspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right") { inspector.toggle() }
        }
        .inspector(isPresented: $inspector) {
            if let clip = selected.first { DownloadInspector(clip: clip, store: store, review: { review = clip }, play: { play([clip.id]) }) }
            else { ContentUnavailableView("Select a Download", systemImage: "arrow.down.circle", description: Text("Choose a download to see details and notes.")) }
        }
        .confirmationDialog("\(confirmation ?? "") \(actionIDs.count) Download(s)?", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
            Button(confirmation ?? "", role: confirmation == "Retry" ? nil : .destructive) {
                let action = confirmation ?? ""; let ids = actionIDs
                store.perform { client in
                    for id in ids {
                        switch action {
                        case "Retry": try await client.retry(clipID: id)
                        case "Stop": try await client.cancel(clipID: id)
                        default: try await client.delete(clipID: id)
                        }
                    }
                }; confirmation = nil
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: { Text(confirmation == "Delete" ? "Saved files and notes will be removed permanently." : "This applies to the selected downloads.") }
        .sheet(item: $review) { clip in ReviewSheet(clip: clip, store: store) }
        .task {
            try? await Task.sleep(for: .milliseconds(150))
            sort = SortPreference.decode(savedSort, choices: sortChoices, fallback: sort)
            selection = Set(savedSelection.split(separator: "\n").map(String.init))
            if let id = UserDefaults.standard.string(forKey: "downloads.reveal") { selection = [id]; scope = "all"; search = ""; UserDefaults.standard.removeObject(forKey: "downloads.reveal") }
        }
        .onChange(of: sort) { _, value in Task { @MainActor in await Task.yield(); savedSort = SortPreference.encode(value, choices: sortChoices) } }
        .onChange(of: selection) { _, value in Task { @MainActor in await Task.yield(); savedSelection = value.sorted().joined(separator: "\n") } }
    }
    private var sortChoices: [String: KeyPathComparator<Clip>] {
        ["match": KeyPathComparator(\.matchLabel), "division": KeyPathComparator(\.divisionLabel),
         "event": KeyPathComparator(\.eventLabel), "status": KeyPathComparator(\.statusLabel),
         "size": KeyPathComparator(\.bytes), "added": KeyPathComparator(\.created)]
    }
    private var scopePicker: some View {
Picker("Show Downloads", selection: $scope) {
                ForEach([("all", "All"), ("active", "Active"), ("ready", "Saved"), ("needs_review", "Needs Review"), ("failed", "Failed / Stopped")], id: \.0) { key, title in
                    Text("\(title) (\(store.clips.filter { inScope($0, key) }.count))").tag(key)
                }
            }
    }
    @ViewBuilder private func actions(_ ids: Set<String>) -> some View {
        let items = store.clips.filter { ids.contains($0.id) }
        Button("Play") { play(ids) }.disabled(!items.contains { $0.status == "ready" })
        Button("Save MP4 As…") { if let clip = items.first { save(clip) } }.disabled(items.count != 1 || items.first?.status != "ready")
        Button("Check Start and End…") { review = items.first }.disabled(items.count != 1 || items.first?.status != "needs_review")
        Divider()
        Button("Retry…") { ask("Retry", ids) }.disabled(items.isEmpty || !items.allSatisfy { $0.state?.canRetry == true })
        Button("Stop…") { ask("Stop", ids) }.disabled(items.isEmpty || !items.allSatisfy(\.isActive))
        Divider()
        Button("Delete…", role: .destructive) { ask("Delete", ids) }.disabled(items.isEmpty || items.contains(where: \.isActive))
    }
    private func ask(_ action: String, _ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let items = store.clips.filter { ids.contains($0.id) }
        guard action != "Delete" || !items.contains(where: \.isActive) else { store.error = "Stop active downloads before deleting them."; return }
        actionIDs = ids; confirmation = action
    }
    private func play(_ ids: Set<String>) {
        guard let clip = store.clips.first(where: { ids.contains($0.id) && ["ready", "needs_review"].contains($0.status) }), let client = store.client else { return }
        if clip.status == "needs_review" { review = clip; return }
        openWindow(value: Playback(id: clip.id, title: clip.title, url: client.videoURL(clipID: clip.id)))
    }
    private func save(_ clip: Clip) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Movie]; panel.nameFieldStringValue = clip.title.replacingOccurrences(of: "/", with: "-") + ".mp4"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let source = URL(fileURLWithPath: store.storage).appendingPathComponent(clip.id).appendingPathComponent("clip.mp4")
            // NSSavePanel has confirmed replacement; an atomic write preserves an existing destination if reading fails.
            try Data(contentsOf: source, options: .mappedIfSafe).write(to: destination, options: .atomic)
        } catch { store.error = error.localizedDescription }
    }
}

struct DownloadInspector: View {
    let clip: Clip
    @Bindable var store: LibraryStore
    let review: () -> Void
    let play: () -> Void
    @State private var notes = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                InspectorHeading(title: clip.matchLabel + (clip.divisionLabel.isEmpty ? "" : ", " + clip.divisionLabel), subtitle: clip.eventLabel)
                InspectorFacts([("Status", Labels.status(clip.status)), ("Length", Format.clock(clip.end - clip.start)), ("Size", Format.size(Int64(clip.bytes)))])
                InspectorProgress(clip: clip)
                if clip.status == "failed" { Text(Labels.failure(clip.detail)).foregroundStyle(.red).textSelection(.enabled) }
                else if let detail = clip.detail, !detail.isEmpty { Text(detail).foregroundStyle(.secondary).textSelection(.enabled) }
                HStack {
                    if clip.status == "ready" { Button("Play", action: play).inspectorButton() }
                    if clip.status == "needs_review" { Button("Check Start and End…", action: review).inspectorButton() }
                    if let url = URL(string: clip.url) { Link("Open Recording", destination: url) }
                }
                InspectorSection("Notes") {
                    TextEditor(text: $notes).scrollContentBackground(.hidden).frame(minHeight: 110).padding(6).softCard(radius: 10)
                        .accessibilityLabel("Download notes")
                    Button("Save Notes") { let text = notes; store.perform { try await $0.setNotes(clipID: clip.id, notes: text) } }
                        .disabled(notes == (clip.notes ?? "")).inspectorButton()
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
        }.inspectorColumnWidth(min: 250, ideal: 300, max: 440)
        .onChange(of: clip.id, initial: true) { notes = clip.notes ?? "" }
    }
}

/// AVKit's own player view. SwiftUI's `VideoPlayer` links only the private _AVKit_SwiftUI overlay, not
/// AVKit itself, and the app aborted at launch of any player window (a missing AVPlayerView superclass).
struct NativePlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

struct Playback: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let url: URL
}
struct PlaybackView: View {
    let playback: Playback
    @State private var player = AVPlayer()
    @State private var ratio: CGFloat = 16.0 / 9.0
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some View {
        NativePlayerView(player: player)
            .ignoresSafeArea()
            .background(WindowAspect(ratio: ratio))
            .navigationTitle(playback.title).frame(minWidth: 480, minHeight: 270)
            .onKeyPress(.space) { dismissWindow(value: playback); return .handled }
            .onAppear { player.replaceCurrentItem(with: AVPlayerItem(url: playback.url)); player.play() }
            .onDisappear { player.pause(); player.replaceCurrentItem(with: nil) }
            .task {
                // Match the window to the clip's real shape.
                let asset = AVURLAsset(url: playback.url)
                if let track = try? await asset.loadTracks(withMediaType: .video).first,
                   let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
                    let shape = size.applying(transform)
                    if shape.height != 0 { ratio = abs(shape.width / shape.height) }
                }
            }
    }
}
struct ReviewSheet: View {
    let clip: Clip
    @Bindable var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()
    @State private var start = "0"
    @State private var end = "0"
    @State private var error: String?
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading) {
            Text("Check Start and End").font(.title2)
            Text(clip.title).foregroundStyle(.secondary)
            NativePlayerView(player: player).aspectRatio(16.0 / 9.0, contentMode: .fit)
            Form {
                HStack { TextField("Start", text: $start); Button("Use Current Time") { start = String(max(0, player.currentTime().seconds)) } }
                HStack { TextField("End", text: $end); Button("Use Current Time") { end = String(max(0, player.currentTime().seconds)) } }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Match") { save() }.keyboardShortcut(.defaultAction).disabled(saving || !valid)
            }
        }.padding().frame(width: 620)
        .onAppear {
            if let client = store.client { player.replaceCurrentItem(with: AVPlayerItem(url: client.videoURL(clipID: clip.id, review: true))) }
            start = String(clip.analysis?.start ?? 0); end = String(clip.analysis?.end ?? clip.analysis?.sourceDuration ?? 0)
        }.onDisappear { player.pause(); player.replaceCurrentItem(with: nil) }
    }
    private var valid: Bool {
        guard let a = Format.parseClock(start), let b = Format.parseClock(end) else { return false }
        return b > a && b <= (clip.analysis?.sourceDuration ?? 0) + 0.1
    }
    private func save() {
        guard let client = store.client else { return }; saving = true
        Task {
            defer { saving = false }
            do { try await client.setBounds(clipID: clip.id, start: start, end: end); try await store.refresh(); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}
