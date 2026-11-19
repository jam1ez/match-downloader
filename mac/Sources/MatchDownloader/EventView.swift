import SwiftUI
import MatchCore

struct ScheduleRow: Identifiable {
    let match: Match
    let ordinal: Int
    let download: Clip?
    var id: String { match.key }
    var division: String { match.division }
    var redScore: Int? { match.red?.score }
    var blueScore: Int? { match.blue?.score }
    var source: String? { let text = Labels.source(match); return match.available && !text.isEmpty ? text : nil }
    var status: String? { download.map { Labels.status($0.status) } }
}
struct EventView: View {
    @Bindable var events: EventStore
    @Bindable var library: LibraryStore
    let showDownloads: (String?) -> Void
    @SceneStorage("event.selections") private var savedSelections = "{}"
    @State private var selectionSKU: String?
    @State private var selection: Set<String> = []
    @State private var search = ""
    @State private var division = "all"
    @State private var round = "all"
    @State private var day = "all"
    @State private var hasVideo = false
    @AppStorage("schedule.sort") private var savedSort = "[]"
    @State private var sort = [KeyPathComparator(\ScheduleRow.ordinal)]
    @SceneStorage("schedule.columns.v3") private var columns: TableColumnCustomization<ScheduleRow>
    @AppStorage("inspector.visible") private var inspector = true
    @AppStorage("filters.visible") private var filters = true
    @State private var downloadSheet = false
    @State private var position: Match?
    @State private var livestream: RecordingEdit?
    @State private var inspectorTab = "match"
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("download.before") private var before = 5.0
    @AppStorage("download.offset") private var offset = 0.0
    @AppStorage("download.mode") private var downloadMode = "fixed"
    @AppStorage("download.startAdjust") private var startAdjust = 0.0

    private var event: EventDetail? { events.event }
    private var selected: [Match] { event?.matches.filter { selection.contains($0.key) } ?? [] }
    private var rows: [ScheduleRow] {
        guard let event else { return [] }
        let downloads = Dictionary(library.clips.filter { $0.eventRef == event.sku && $0.status != "cancelled" }.map { ($0.matchRef ?? "", $0) }, uniquingKeysWith: { a, _ in a })
        return event.matches.enumerated().filter { _, m in
            (division == "all" || m.divisionId == division) && (round == "all" || Labels.round(m.label) == round) && (day == "all" || Labels.day(m) == day) && (!hasVideo || m.available) && MatchQuery.matches(m, query: search)
        }.map { ScheduleRow(match: $0.element, ordinal: $0.offset, download: downloads[$0.element.key]) }.sorted(using: sort)
    }
    var body: some View {
        VStack(spacing: 0) {
            if filters { filterBar }
            scheduleTable
        }
        .background(Theme.canvas)
        .overlay(alignment: .bottom) { statusLine.padding(.bottom, 12).allowsHitTesting(false) }
        .focusedSceneValue(\.matchActions, MatchActions(preview: { preview(selection) }, position: { position = selected.first }, download: { downloadSheet = true }, hasVideo: selected.contains(where: \.available), singleMatch: selected.count == 1))
        .navigationTitle(event?.name ?? "Choose an Event")
        .navigationSubtitle(event.map { "\($0.sku), \(Format.dateRange($0.allDays))" } ?? "")
        .searchable(text: $search, placement: .toolbar, prompt: "Match or Team")
        .onSubmit(of: .search) { selection = Set(rows.filter { $0.match.available }.map(\.id)) }
        .toolbar {
            ToolbarItemGroup {
                Button("Refresh Event", systemImage: "arrow.clockwise") { if let sku = event?.sku { Task { await events.load(sku, refresh: true) } } }.disabled(events.loading)
                Button("Preview", systemImage: "play") { preview(selection) }.disabled(!selected.contains(where: \.available))
            }
            ToolbarSpacer(.fixed)
            ToolbarItem { Button("Download…") { downloadSheet = true }.buttonStyle(.glassProminent).disabled(!selected.contains(where: \.available)) }
            ToolbarSpacer(.fixed)
            ToolbarItem { Button(inspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right") { inspector.toggle() } }
        }
        .inspector(isPresented: $inspector) {
            VStack(spacing: 0) {
                Picker("Inspector", selection: $inspectorTab) { Text("Match").tag("match"); Text("Recordings").tag("recordings") }.pickerStyle(.segmented).padding()
                if inspectorTab == "recordings", let event { RecordingsInspector(event: event, events: events) }
                else { matchInspector }
            }.inspectorColumnWidth(min: 280, ideal: 340, max: 480)
        }
        .sheet(isPresented: $downloadSheet) { if let event { DownloadSheet(event: event, selected: selected, library: library) } }
        .sheet(item: $position) { match in if let event { PositionSheet(event: event, match: match, events: events) } }
        .sheet(item: $livestream) { item in if let event { RecordingEditor(event: event, events: events, initial: item.draft) } }
        .task(id: event?.sku) {
            try? await Task.sleep(for: .milliseconds(150))
            sort = SortPreference.decode(savedSort, choices: sortChoices, fallback: sort)
            guard let sku = event?.sku else { return }
            selectionSKU = sku
            let saved = (try? JSONDecoder().decode([String: [String]].self, from: Data(savedSelections.utf8))) ?? [:]
            selection = Set(saved[sku] ?? []).intersection(Set(event?.matches.map(\.key) ?? []))
            division = "all"; day = "all"; round = "all"; search = ""
            // A single division adds nothing to every row; it stays in the inspector.
            columns[visibility: "division"] = (event?.divisions.count ?? 0) > 1 ? .visible : .hidden
        }
        .onChange(of: sort) { _, value in Task { @MainActor in await Task.yield(); savedSort = SortPreference.encode(value, choices: sortChoices) } }
        .onChange(of: selection) { _, value in
            guard let sku = selectionSKU, sku == event?.sku else { return }
            var saved = (try? JSONDecoder().decode([String: [String]].self, from: Data(savedSelections.utf8))) ?? [:]
            saved[sku] = value.sorted()
            if let data = try? JSONEncoder().encode(saved), let text = String(data: data, encoding: .utf8) { Task { @MainActor in await Task.yield(); savedSelections = text } }
        }
    }
    private var scheduleTable: some View {
            Table(rows, selection: $selection, sortOrder: $sort, columnCustomization: $columns) {
                TableColumn("Match", value: \.ordinal) { Text(Labels.show($0.match.label)).fontWeight(.semibold).padding(.vertical, 9) }.width(min: 60, ideal: 80, max: 120).customizationID("match")
                TableColumn("Division", value: \.division).width(min: 80, ideal: 130).customizationID("division")
                TableColumn("Red Alliance", value: \.redScore, comparator: OptionalLastComparator<Int>()) { row in AllianceCell(alliance: row.match.red, opponent: row.match.blue) }.width(min: 170, ideal: 240).customizationID("red")
                TableColumn("Blue Alliance", value: \.blueScore, comparator: OptionalLastComparator<Int>()) { row in AllianceCell(alliance: row.match.blue, opponent: row.match.red) }.width(min: 170, ideal: 240).customizationID("blue")
                TableColumn("Source", value: \.source, comparator: OptionalLastComparator<String>()) { Text($0.source ?? Labels.noPosition($0.match.timing)).foregroundStyle($0.source == nil ? .secondary : .primary) }.width(min: 110, ideal: 160).customizationID("source").defaultVisibility(.hidden)
                TableColumn("Download", value: \.status, comparator: OptionalLastComparator<String>()) { StatusDot(status: $0.download?.status) }.width(min: 64, ideal: 84, max: 130).customizationID("download")
            }
            .overlay { if rows.isEmpty { ContentUnavailableView("No Matching Matches", systemImage: "magnifyingglass", description: Text("Try another search, division, round or day.")).allowsHitTesting(false) } }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .scrollContentBackground(.hidden)
            .mutedSelection()
            .contentMargins(.bottom, 56, for: .scrollContent)
            .background(TablePersistence(name: "ScheduleTable.v3"))
            .contextMenu(forSelectionType: String.self) { ids in contextActions(ids) } primaryAction: { ids in preview(ids) }
            .onKeyPress(.space) { preview(selection); return .handled }
            .onKeyPress(.return) { preview(selection); return .handled }
            .onExitCommand { selection = [] }
    }
    private var sortChoices: [String: KeyPathComparator<ScheduleRow>] {
        ["match": KeyPathComparator(\.ordinal), "division": KeyPathComparator(\.division),
         "red": KeyPathComparator(\.redScore, comparator: OptionalLastComparator<Int>()),
         "blue": KeyPathComparator(\.blueScore, comparator: OptionalLastComparator<Int>()),
         "source": KeyPathComparator(\.source, comparator: OptionalLastComparator<String>()),
         "download": KeyPathComparator(\.status, comparator: OptionalLastComparator<String>())]
    }
    private var filterBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                Picker("Division", selection: $division) { Text("All Divisions").tag("all"); ForEach(event?.divisions ?? []) { Text($0.name).tag($0.id) } }
                Picker("Round", selection: $round) {
                    Text("All Rounds").tag("all")
                    ForEach([("P", "Practice"), ("Q", "Qualifications"), ("R16", "Round of 16"), ("QF", "Quarterfinals"), ("SF", "Semifinals"), ("F", "Finals")], id: \.0) { key, label in Text(label).tag(key) }
                }
                Picker("Day", selection: $day) { Text("All Days").tag("all"); ForEach(Array((event?.allDays ?? []).enumerated()), id: \.element) { Text("Day \($0.offset + 1), \(Format.dayName($0.element))").tag($0.element) } }
                Toggle("Has Video", isOn: $hasVideo).toggleStyle(.button)
            }.labelsHidden().pickerStyle(.menu).buttonStyle(.borderless).buttonBorderShape(.capsule).fixedSize()
            .padding(.horizontal, 12).padding(.vertical, 3).softCapsule()
            .padding(.horizontal, 12).padding(.vertical, 8)
        }.scrollIndicators(.hidden).disabled(events.loading)
    }
    /// Selection count, and the Return-to-select hint while a search is typed.
    private var statusLine: some View {
        let shown = rows
        let withVideo = shown.filter { $0.match.available }.count
        let text: String
        if !selected.isEmpty {
            let missing = selected.filter { !$0.available }.count
            text = "\(selected.count) of \(shown.count) selected" + (missing > 0 ? ", \(missing) without video" : "")
        } else if !search.trimmingCharacters(in: .whitespaces).isEmpty && withVideo > 0 {
            text = "Press Return to select \(Format.plural(withVideo, "match", "matches")) with video"
        } else { text = Format.plural(shown.count, "match", "matches") }
        return Text(text).font(.callout).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.vertical, 7).floatingCapsule()
    }
    @ViewBuilder private var matchInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if selected.count > 1 {
                    heading("\(selected.count) Matches Selected", "\(selected.filter(\.available).count) with video, \(selected.filter { !$0.available }.count) without")
                    VStack(alignment: .leading, spacing: 4) { ForEach(selected.prefix(30)) { Text("\(Labels.show($0.label)), \($0.division)") }
                        if selected.count > 30 { Text("and \(selected.count - 30) more").foregroundStyle(.secondary) } }
                    Button("Download…") { downloadSheet = true }.disabled(!selected.contains(where: \.available)).inspectorButton()
                } else if let match = selected.first {
                    heading(Labels.show(match.label), match.name)
                    facts([("Division", match.division), ("Day", dayText(match)), ("Field", match.field ?? ""), ("Started", startText(match))])
                    section("Alliances") {
                        VStack(spacing: 8) { AllianceCell(alliance: match.red, opponent: match.blue); AllianceCell(alliance: match.blue, opponent: match.red) }
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading).softCard()
                    }
                    section("Video") {
                        facts([("Position", match.videoPosition.map(Format.clock) ?? "None"), ("Source", match.available ? Labels.source(match) : Labels.noPosition(match.timing))])
                        if let options = match.streamOptions, !options.isEmpty {
                            Picker("Recording", selection: Binding(get: { match.streamId ?? "" }, set: { id in events.update { client, sku in try await client.chooseStream(sku: sku, key: match.key, id: id) } })) {
                                Text("Choose…").tag(""); ForEach(options) { Text($0.label).tag($0.id) }
                            }
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack { Button("Preview") { preview([match.key]) }.disabled(!match.available).inspectorButton(); Button("Open in Browser") { openInBrowser(match) }.disabled(!match.available).inspectorButton(); Button("Set Video Position…") { position = match }.inspectorButton() }
                            VStack(alignment: .leading) { Button("Preview") { preview([match.key]) }.disabled(!match.available).inspectorButton(); Button("Open in Browser") { openInBrowser(match) }.disabled(!match.available).inspectorButton(); Button("Set Video Position…") { position = match }.inspectorButton() }
                        }
                    }
                    section("Download") {
                        if let clip = library.clips.first(where: { $0.eventRef == event?.sku && $0.matchRef == match.key && $0.status != "cancelled" }) {
                            Text(Labels.status(clip.status))
                            Button("Show in Downloads") { showDownloads(clip.id) }.inspectorButton()
                        } else {
                            Text(match.available ? "Not downloaded." : "Set a video position before downloading.").foregroundStyle(.secondary)
                            if match.available { Button("Download…") { downloadSheet = true }.inspectorButton() }
                        }
                    }
                } else {
                    heading(event?.name ?? "Event", event.map { "\($0.sku), \(Format.dateRange($0.allDays))" } ?? "")
                    facts([("Matches", "\(event?.matches.count ?? 0)"), ("With video", "\(event?.matchesWithVideo ?? 0)"), ("Divisions", event?.divisions.map(\.name).joined(separator: ", ") ?? "")])
                    if !livestreamDays.isEmpty {
                        section("Livestream") {
                            Text("The video the app found for each day. Change it if a link doesn't play or is the wrong broadcast.").font(.callout).foregroundStyle(.secondary)
                            ForEach(livestreamDays) { livestreamRow($0) }
                            if let event { LivestreamShift(event: event, events: events) }
                        }
                    }
                    Text("Select a match to see its teams, video position and download. Shift-click or Command-click to select several.").foregroundStyle(.secondary)
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
        }.inspectorColumnWidth(min: 260, ideal: 330, max: 440)
    }
    private struct LivestreamDay: Identifiable {
        let day: String
        let url: String?
        let count: Int
        let manual: Recording?
        var id: String { day }
    }
    /// One row per event day: the broadcast most of that day's matches use, and whether you set it yourself.
    private var livestreamDays: [LivestreamDay] {
        guard let event else { return [] }
        return event.allDays.map { day in
            let matches = event.matches.filter { Labels.day($0) == day && $0.available }
            let top = Dictionary(grouping: matches, by: { $0.url ?? "" }).max { $0.value.count < $1.value.count }?.key
            let manual = event.recordings.first { $0.date == day && $0.divisionId == "*" && $0.isEnabled }
            return LivestreamDay(day: day, url: top, count: matches.count, manual: manual)
        }
    }
    private func platform(_ url: String?) -> String {
        guard let host = url.flatMap({ URL(string: $0)?.host?.lowercased() }) else { return "No video found" }
        if host.contains("youtu") { return "YouTube" }
        if host.contains("vimeo") { return "Vimeo" }
        if host.contains("boxcast") { return "BoxCast" }
        return host.replacingOccurrences(of: "www.", with: "")
    }
    @ViewBuilder private func livestreamRow(_ row: LivestreamDay) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(dayLabel(row.day)).font(.headline)
                Spacer()
                Text(row.manual == nil ? "Automatic" : "Manual").font(.callout).foregroundStyle(.secondary)
            }
            Text("\(platform(row.url)) · \(Format.plural(row.count, "match", "matches")) with video").font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Change") {
                    livestream = RecordingEdit(draft: row.manual.map { StreamDraft(editing: $0) } ?? StreamDraft(label: "Livestream", date: row.day, divisionId: "*"))
                }.inspectorButton()
                if let manual = row.manual {
                    Button("Use Automatic") { events.update { client, sku in try await client.deleteStream(sku: sku, id: manual.id) } }.inspectorButton().disabled(events.working)
                }
                if let url = row.url.flatMap(URL.init(string:)) { Link("Open", destination: url) }
            }
        }
        .accessibilityElement(children: .contain)
    }
    private func dayLabel(_ day: String) -> String {
        let number = (event?.allDays.firstIndex(of: day)).map { "Day \($0 + 1), " } ?? ""
        return number + Format.dayName(day)
    }
    private func heading(_ title: String, _ subtitle: String) -> some View { InspectorHeading(title: title, subtitle: subtitle) }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View { InspectorSection(title, content: content) }
    private func facts(_ rows: [(String, String)]) -> some View { InspectorFacts(rows) }
    private func dayText(_ match: Match) -> String {
        let day = Labels.day(match)
        guard !day.isEmpty else { return "—" }
        let number = (event?.allDays.firstIndex(of: day)).map { "Day \($0 + 1), " } ?? ""
        return number + Format.dayName(day)
    }
    private func startText(_ match: Match) -> String {
        func time(_ iso: String?) -> String? {
            guard let iso, let date = ISO8601DateFormatter().date(from: iso) else { return nil }
            return date.formatted(date: .omitted, time: .shortened)
        }
        if let started = time(match.started) { return started }
        if let scheduled = time(match.scheduled) { return "Scheduled \(scheduled)" }
        return "—"
    }
    @ViewBuilder private func contextActions(_ ids: Set<String>) -> some View {
        let matches = event?.matches.filter { ids.contains($0.key) } ?? []
        Button("Preview") { preview(ids) }.disabled(!matches.contains(where: \.available))
        Button("Open in Browser") { if let match = matches.first { openInBrowser(match) } }.disabled(matches.count != 1 || matches.first?.available != true)
        Button("Set Video Position…") { position = matches.first }.disabled(matches.count != 1)
        if let match = matches.first, let options = match.streamOptions, !options.isEmpty {
            Menu("Use Recording") { ForEach(options) { option in Button(option.label) { events.update { client, sku in try await client.chooseStream(sku: sku, key: match.key, id: option.id) } } } }
        }
        Divider()
        Button("Download…") { selection = ids; downloadSheet = true }.disabled(!matches.contains(where: \.available))
        Button("Copy Match Label") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(matches.map { Labels.show($0.label) + " " + $0.division }.joined(separator: "\n"), forType: .string) }
    }
    /// Opens the recording on its own site at the match, for videos that can't play inside the app.
    private func openInBrowser(_ match: Match) {
        guard let url = match.url else { return }
        let item = PreviewItem(title: "", url: url, target: max(0, (match.timestamp ?? 0) + offset - before + (downloadMode == "fixed" ? startAdjust : 0)), port: 0)
        if let link = item.recordingURL { NSWorkspace.shared.open(link) }
    }
    private func preview(_ ids: Set<String>) {
        guard let match = event?.matches.first(where: { ids.contains($0.key) && $0.available }), let url = match.url, let port = library.client?.baseURL.port else { return }
        let item = PreviewItem(title: Labels.show(match.label) + ", " + match.division, url: url, target: max(0, (match.timestamp ?? 0) + offset - before + (downloadMode == "fixed" ? startAdjust : 0)), port: port)
        if PreviewWindows.shared.open.contains(item.id) { dismissWindow(value: item) } else { openWindow(value: item) }
    }
}

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

struct AllianceCell: View {
    let alliance: Alliance?
    let opponent: Alliance?
    private var wins: Bool { (alliance?.score ?? Int.min) > (opponent?.score ?? Int.max) }
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(alliance?.color == "red" ? Theme.allianceRed : Theme.allianceBlue).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(alliance?.teams.isEmpty == false ? alliance!.teams.joined(separator: " ") : "TBD").lineLimit(1).help(alliance?.teams.joined(separator: ", ") ?? "Teams to be determined")
            Spacer(minLength: 6)
            if let score = alliance?.score {
                Text(String(score)).monospacedDigit().fontWeight(wins ? .bold : .regular).foregroundStyle(wins || opponent?.score == nil || opponent?.score == score ? .primary : .secondary)
            }
        }.accessibilityElement(children: .ignore)
        .accessibilityLabel("\(alliance?.color.capitalized ?? "") alliance, \(alliance?.teams.joined(separator: ", ") ?? "teams to be determined"), score \(alliance?.score.map(String.init) ?? "not available")\(wins ? ", winner" : "")")
    }
}

/// One slider for the whole clip: the left thumb is where it starts, the right thumb is where it ends, and the
/// filled stretch between them is what gets saved. The thin mark is the official match start. Thumbs move in
/// 5 second steps and stay at least 5 seconds apart (Sliders.md: min on the leading side, a label, live feedback).
struct ClipRangeSlider: View {
    @Binding var startAdjust: Double
    @Binding var endAdjust: Double
    let baseStart: Double   // seconds from the match start where the clip would start with no adjustment
    let baseEnd: Double
    private let step = 5.0
    var startLimits: ClosedRange<Double> = -60...60
    var endLimits: ClosedRange<Double> = -60...120
    private enum Edge: Hashable { case start, end }
    @FocusState private var focus: Edge?
    @State private var dragging: Edge?

    private var lower: Double { baseStart + startLimits.lowerBound }
    private var upper: Double { baseEnd + endLimits.upperBound }
    private var startT: Double { baseStart + startAdjust }
    private var endT: Double { baseEnd + endAdjust }

    private func move(_ edge: Edge, toSeconds t: Double) {
        switch edge {
        case .start:
            let value = ((t - baseStart) / step).rounded() * step
            startAdjust = min(max(value, startLimits.lowerBound), min(startLimits.upperBound, endT - step - baseStart))
        case .end:
            let value = ((t - baseEnd) / step).rounded() * step
            endAdjust = max(min(value, endLimits.upperBound), max(endLimits.lowerBound, startT + step - baseEnd))
        }
    }
    private func nudge(_ edge: Edge, by amount: Double) { move(edge, toSeconds: (edge == .start ? startT : endT) + amount) }
    private func name(_ edge: Edge) -> String { edge == .start ? "Clip start" : "Clip end" }
    private func spoken(_ t: Double) -> String { t < 0 ? "\(Int(-t)) seconds before the match" : "\(Int(t)) seconds into the match" }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let span = max(upper - lower, 1)
            let position: (Double) -> CGFloat = { CGFloat(($0 - lower) / span) * width }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.14)).frame(height: 4)
                Rectangle().fill(Color.primary.opacity(0.4)).frame(width: 1.5, height: 14).offset(x: position(0) - 0.75)
                Capsule().fill(Color.accentColor).frame(width: max(0, position(endT) - position(startT)), height: 4).offset(x: position(startT))
                thumb(.start).offset(x: position(startT) - 11)
                thumb(.end).offset(x: position(endT) - 11)
            }
            .frame(maxHeight: .infinity)
            .coordinateSpace(name: "clipTrack")
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("clipTrack")).onChanged { drag in
                    let t = lower + Double(drag.location.x / max(width, 1)) * span
                    // Grab whichever thumb is closer to where the pointer went down.
                    let edge: Edge = dragging ?? (abs(t - startT) <= abs(t - endT) ? .start : .end)
                    dragging = edge; focus = edge; move(edge, toSeconds: t)
                }.onEnded { _ in dragging = nil }
            )
        }
        .frame(height: 28)
    }

    private func thumb(_ edge: Edge) -> some View {
        Circle().fill(.white).frame(width: 22, height: 22)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
            .focusable().focused($focus, equals: edge)
            .onKeyPress(.leftArrow) { nudge(edge, by: -step); return .handled }
            .onKeyPress(.rightArrow) { nudge(edge, by: step); return .handled }
            .accessibilityElement()
            .accessibilityLabel(name(edge))
            .accessibilityValue(spoken(edge == .start ? startT : endT))
            .accessibilityAdjustableAction { direction in nudge(edge, by: direction == .increment ? step : -step) }
    }
}

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
