import SwiftUI
import MatchCore

struct WorkspaceView: View {
    @Bindable var library: LibraryStore
    @State private var events = EventStore()
    @SceneStorage("workspace.route") private var route = ""
    @AppStorage("workspace.lastRoute") private var lastRoute = "downloads"
    @State private var sidebarSearch = ""
    @State private var addEvents = false
    @State private var removing: CatalogueEvent?
    @AppStorage("sidebar.archivedExpanded") private var archivedExpanded = false
    @AppStorage("sidebar.catalogueExpanded") private var catalogueExpanded = true
    @State private var visibility = NavigationSplitViewVisibility.automatic
    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            List(selection: Binding<String?>(get: { route }, set: { route = $0 ?? "downloads" })) {
                Section("Library") {
                    Label("Downloads", systemImage: "arrow.down.circle").badge(library.activeCount).tag("downloads")
                    Label("Clip from Link", systemImage: "scissors").tag("clip")
                }
                Section("On This Mac") { ForEach(filtered.filter { $0.saved && !$0.isArchived }) { item in savedRow(item) } }
                if filtered.contains(where: \.isArchived) {
                    Section("Archived", isExpanded: expansion($archivedExpanded)) { ForEach(filtered.filter(\.isArchived)) { item in savedRow(item) } }
                }
                Section("Event Catalogue", isExpanded: expansion($catalogueExpanded)) { ForEach(filtered.filter { !$0.saved }) { item in Label(item.name, systemImage: "calendar").tag(item.sku) } }
            }.searchable(text: $sidebarSearch, placement: .sidebar, prompt: "Filter Events")
            .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 360)
            .toolbar {
                Button("Add Events…", systemImage: "plus") { addEvents = true }
                Button("Update Catalogue", systemImage: "arrow.clockwise") { Task { await events.catalogue(refresh: true) } }
            }
        } detail: {
            if route == "downloads" { DownloadsView(store: library) }
            else if route == "clip" { ClipLinkView(library: library) }
            else if events.loading && events.event?.sku != route { ProgressView("Opening event…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if events.event != nil { EventView(events: events, library: library) { id in if let id { UserDefaults.standard.set(id, forKey: "downloads.reveal") }; route = "downloads" } }
            else { ContentUnavailableView(events.error == nil ? "Choose an Event" : "Can’t Open Event", systemImage: "calendar", description: Text(events.error ?? "Choose an event in the sidebar, or add an event code.")) }
        }
        // HIG sidebars.md > Desktop: collapse at narrow window widths, retain the
        // standard sidebar toggle so people can reveal navigation again.
        .onGeometryChange(for: Bool.self) { $0.size.width < 1000 } action: { narrow in Task { @MainActor in await Task.yield(); visibility = narrow ? .detailOnly : .automatic } }
        .focusedSceneValue(\.workspaceActions, WorkspaceActions(addEvents: { addEvents = true }, clipFromLink: { route = "clip" }))
        .confirmationDialog("Remove \(removing?.name ?? "this event") from this Mac?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { item in
            Button("Remove Event", role: .destructive) {
                Task { if await events.remove(item.sku), route == item.sku { route = "downloads" } }
            }
        } message: { _ in
            Text("Its schedule and recordings are deleted from this Mac. Matches you already downloaded stay in your library, and you can add the event again later.")
        }
        .sheet(isPresented: $addEvents) { AddEventsSheet(events: events) { route = $0 } }
        .task {
            await Task.yield()
            events.client = library.client
            if route.isEmpty { route = lastRoute }
            await events.catalogue(); if route != "downloads", route != "clip" { await events.load(route) } }
        .onChange(of: route) { _, sku in Task { @MainActor in await Task.yield(); lastRoute = sku }; if sku != "downloads", sku != "clip", sku != events.event?.sku { Task { await events.load(sku) } } }
        .safeAreaInset(edge: .bottom) {
            if let error = events.error { HStack { Text(error).textSelection(.enabled); Spacer(); Button("Dismiss") { events.error = nil } }.padding().background(.bar) }
        }
    }
    /// Collapsible sections stay open while searching so matches are never hidden.
    private func expansion(_ stored: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { stored.wrappedValue || !sidebarSearch.isEmpty }, set: { stored.wrappedValue = $0 })
    }
    /// A saved event: archive or remove it from this Mac with a swipe or right-click.
    private func savedRow(_ item: CatalogueEvent) -> some View {
        Label(item.name, systemImage: item.isArchived ? "archivebox" : "calendar").tag(item.sku)
            .contextMenu {
                if item.isArchived { Button("Unarchive", systemImage: "tray.and.arrow.up") { Task { await events.archive(item.sku, false) } } }
                else { Button("Archive", systemImage: "archivebox") { Task { await events.archive(item.sku, true) } } }
                Divider()
                Button("Remove from This Mac…", systemImage: "trash", role: .destructive) { removing = item }
            }
            .swipeActions(edge: .trailing) {
                Button("Remove", systemImage: "trash", role: .destructive) { removing = item }
                if item.isArchived { Button("Unarchive", systemImage: "tray.and.arrow.up") { Task { await events.archive(item.sku, false) } }.tint(.gray) }
                else { Button("Archive", systemImage: "archivebox") { Task { await events.archive(item.sku, true) } }.tint(.gray) }
            }
    }
    private var filtered: [CatalogueEvent] { events.catalogue.filter { sidebarSearch.isEmpty || ($0.name + " " + $0.sku).localizedCaseInsensitiveContains(sidebarSearch) } }
}
struct AddEventsSheet: View {
    @Bindable var events: EventStore
    let opened: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var results: [String] = []
    @State private var busy = false
    @State private var last: String?
    var body: some View {
        VStack(alignment: .leading) {
            Text("Add Events").font(.title2)
            Text("Paste event codes or event page links, one per line.").foregroundStyle(.secondary)
            TextEditor(text: $text).frame(height: 130).accessibilityLabel("Event codes or links")
            ForEach(results, id: \.self) { Text($0).textSelection(.enabled) }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if let last { Button("Open Event") { opened(last); dismiss() }.keyboardShortcut(.defaultAction) }
                else { Button("Add Events") { add() }.keyboardShortcut(.defaultAction).disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
        }.padding().frame(width: 480)
    }
    private func add() {
        guard let client = events.client else { return }; busy = true; results = []
        let codes = text.components(separatedBy: CharacterSet(charactersIn: ",;\n")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        Task {
            defer { busy = false }
            for code in codes {
                do { let event = try await client.loadEvent(sku: code); results.append("Added \(event.name)"); last = event.sku }
                catch { results.append("\(code): \(error.localizedDescription)") }
            }
            await events.catalogue()
        }
    }
}
