import SwiftUI
import UniformTypeIdentifiers
import MatchCore

struct ClipLinkView: View {
    @Bindable var library: LibraryStore
    @State private var title = ""
    @State private var url = ""
    @State private var start = "0:00"
    @State private var end = "3:00"
    @State private var notes = ""
    @State private var chooseFile = false
    @State private var imports: [NewClip] = []
    @State private var selected: Set<Int> = []
    @State private var error: String?
    @State private var message = ""
    @State private var busy = false
    var body: some View {
        Form {
            Section("Save Part of a Recording") {
                TextField("Match Name", text: $title)
                TextField("Recording Link", text: $url)
                TextField("Start (HH:MM:SS)", text: $start)
                TextField("End (HH:MM:SS)", text: $end)
                TextField("Notes", text: $notes, axis: .vertical)
                Button("Add to Downloads") { queueClip() }.disabled(busy || !valid)
            }
            Section("Import a List") {
                Text("Choose a JSON list of up to 200 clips, then choose which clips to download.").foregroundStyle(.secondary)
                Button("Choose List…") { chooseFile = true }.disabled(busy)
                ForEach(Array(imports.enumerated()), id: \.offset) { index, clip in
                    Toggle(isOn: Binding(get: { selected.contains(index) }, set: { if $0 { selected.insert(index) } else { selected.remove(index) } })) {
                        Text("\(clip.title), \(clip.start) to \(clip.end)")
                    }
                }
                if !imports.isEmpty { Button("Add Selected to Downloads") { queueList() }.disabled(busy || selected.isEmpty) }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if !message.isEmpty { Text(message).textSelection(.enabled) }
            if busy { ProgressView("Adding downloads…") }
        }.formStyle(.grouped).navigationTitle("Clip from Link")
        .fileImporter(isPresented: $chooseFile, allowedContentTypes: [.json]) { result in
            do {
                let file = try result.get(); let access = file.startAccessingSecurityScopedResource(); defer { if access { file.stopAccessingSecurityScopedResource() } }
                let list = try JSONDecoder().decode([NewClip].self, from: Data(contentsOf: file))
                guard list.count <= 200 else { throw APIError.badResponse("The file must contain a list of up to 200 entries.") }
                imports = list; selected = Set(list.indices); error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
    private var valid: Bool {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let parsed = URLComponents(string: url), ["http", "https"].contains(parsed.scheme), parsed.host != nil, parsed.user == nil, parsed.password == nil,
              let a = Format.parseClock(start), let b = Format.parseClock(end) else { return false }
        return b > a && b - a <= 3600
    }
    private func queueClip() {
        guard let client = library.client else { return }; busy = true; error = nil
        let clip = NewClip(title: title, url: url, start: start, end: end, notes: notes)
        Task { defer { busy = false }; do { try await client.addClip(clip); title = ""; notes = ""; message = "Added to Downloads"; try await library.refresh() } catch { self.error = error.localizedDescription } }
    }
    private func queueList() {
        guard let client = library.client else { return }; busy = true; error = nil
        let indices = selected.sorted()
        Task {
            defer { busy = false }
            var added = 0
            do {
                for index in indices { try await client.addClip(imports[index]); selected.remove(index); added += 1 }
                message = "\(Format.plural(added, "clip")) added to Downloads"; try await library.refresh()
            } catch { self.error = "Stopped after \(added): \(error.localizedDescription)"; try? await library.refresh() }
        }
    }
}
