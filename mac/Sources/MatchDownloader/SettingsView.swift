import SwiftUI
import MatchCore
import UserNotifications

/// Defaults for the Download sheet. The sheet shows only the per-download choices;
/// these set-once values live in Settings → Downloads.
enum DownloadDefaults {
    static let duration = 180.0
    static let before = 5.0
    static let tail = 5.0
    static let window = 480.0
    static let windows: [Double] = [180, 300, 480, 600, 1200]
    /// Keys Reset to Defaults clears, so the @AppStorage defaults apply again.
    static let keys = ["download.mode", "download.duration", "download.before", "download.tail", "download.window", "download.offset", "download.startAdjust", "download.endAdjust"]
}

/// How many downloads the engine runs at once. Passed to the engine as MATCH_DOWNLOADER_PARALLEL when the app starts it.
enum EngineSettings {
    static let parallelKey = "engine.parallel"
    static let parallelRange = 1...4
    static func parallel(_ defaults: UserDefaults = .standard) -> Int? {
        let value = defaults.integer(forKey: parallelKey)
        return parallelRange.contains(value) ? value : nil
    }
}

/// The event catalogue refreshes by itself once a day; Settings → Events can refresh it now.
enum CatalogueRefresh {
    static let key = "catalogue.updated"
    static let interval: TimeInterval = 24 * 60 * 60
    static let updated = Notification.Name("MatchDownloader.catalogueUpdated")
    static func isStale(_ updated: Double, now: Date = .now) -> Bool { now.timeIntervalSince1970 - updated > interval }
}

enum DownloadNotifications {
    /// Ask once, the first time something is added to Downloads, rather than making people find the setting.
    static func askIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }
}

struct AppSettings: View {
    @Bindable var library: LibraryStore
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings(library: library) }
            Tab("Downloads", systemImage: "arrow.down.circle") { DownloadSettings() }
            Tab("Events", systemImage: "calendar") { EventSettings(library: library) }
            Tab("Advanced", systemImage: "wrench.and.screwdriver") { AdvancedSettings(library: library) }
        }
        .scenePadding()
        .frame(width: 520)
    }
}

private struct GeneralSettings: View {
    @Bindable var library: LibraryStore
    @AppStorage(EngineSettings.parallelKey) private var parallel = 2
    @State private var notifications: UNAuthorizationStatus?
    var body: some View {
        Form {
            Section("Library") {
                LabeledContent("Location") { Text(library.storage).textSelection(.enabled).truncationMode(.middle).lineLimit(1) }
                Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: library.storage) }.disabled(library.storage.isEmpty)
            }
            Section {
                Stepper("Downloads at Once: \(parallel)", value: $parallel, in: EngineSettings.parallelRange)
            } footer: {
                Text(ProcessInfo.processInfo.environment["MATCH_DOWNLOADER_PARALLEL"] != nil
                     ? "MATCH_DOWNLOADER_PARALLEL is set, so it is used instead."
                     : "Takes effect the next time Match Downloader starts its engine. If downloads were still running when you quit, that happens after they finish.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Notifications") {
                switch notifications {
                case .authorized, .provisional, .ephemeral:
                    LabeledContent("Download Notifications", value: "On")
                case .denied:
                    LabeledContent("Download Notifications", value: "Off")
                    Button("Open System Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
                    }
                default:
                    Button("Turn On Download Notifications…") {
                        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]); await refreshNotifications() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await refreshNotifications() }
    }
    private func refreshNotifications() async { notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
}

private struct DownloadSettings: View {
    @AppStorage("download.mode") private var mode = "fixed"
    @AppStorage("download.duration") private var duration = DownloadDefaults.duration
    @AppStorage("download.before") private var before = DownloadDefaults.before
    @AppStorage("download.tail") private var tail = DownloadDefaults.tail
    @AppStorage("download.window") private var window = DownloadDefaults.window
    private var quick: Binding<Bool> { Binding(get: { mode == "fixed" }, set: { mode = $0 ? "fixed" : "dynamic" }) }
    var body: some View {
        Form {
            Section {
                Toggle("Use Quick Download", isOn: quick)
            } footer: {
                Text("You can still switch for each download.").font(.callout).foregroundStyle(.secondary)
            }
            Section("Quick Download") {
                TextField("Clip Length (seconds)", value: $duration, format: .number)
                TextField("Start Before Match (seconds)", value: $before, format: .number)
            }
            Section("Find Start and End") {
                Picker("Search Window", selection: $window) { ForEach(DownloadDefaults.windows, id: \.self) { Text("\(Int($0 / 60)) minutes").tag($0) } }
                TextField("Keep After Match (seconds)", value: $tail, format: .number)
            }
            Section {
                Button("Reset to Defaults") { DownloadDefaults.keys.forEach(UserDefaults.standard.removeObject(forKey:)) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct EventSettings: View {
    @Bindable var library: LibraryStore
    @AppStorage(CatalogueRefresh.key) private var updated = 0.0
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                LabeledContent("Last Updated") {
                    Text(updated > 0 ? Date(timeIntervalSince1970: updated).formatted(.relative(presentation: .named)) : "Never")
                }
                HStack {
                    Button("Update Now") { update() }.disabled(busy || library.client == nil)
                    if busy { ProgressView().controlSize(.small) }
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            } header: {
                Text("Event Catalogue")
            } footer: {
                Text("The list of events in the sidebar. It updates by itself once a day.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
    private func update() {
        guard let client = library.client else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                let result = try await client.catalogue(refresh: true)
                if result.offline == true { error = "Couldn’t reach the event list. Showing the copy saved on this Mac." }
                else { updated = Date().timeIntervalSince1970 }
                NotificationCenter.default.post(name: CatalogueRefresh.updated, object: nil)
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct AdvancedSettings: View {
    @Bindable var library: LibraryStore
    @AppStorage("download.offset") private var offset = 0.0
    var body: some View {
        Form {
            Section {
                TextField("Shift Every Download (seconds)", value: $offset, format: .number)
            } header: {
                Text("Video Positions")
            } footer: {
                Text("Moves every match in every event. To fix one event, use Shift All Matches in its event panel instead.").font(.callout).foregroundStyle(.secondary)
            }
            Section("Troubleshooting") {
                Button("Open Log") {
                    let log = URL(fileURLWithPath: library.storage).appendingPathComponent("desktop.log")
                    NSWorkspace.shared.open(log)
                }.disabled(library.storage.isEmpty)
                Button("Open Web Version in Browser") { if let url = library.client?.baseURL { NSWorkspace.shared.open(url) } }.disabled(library.client == nil)
            }
        }
        .formStyle(.grouped)
    }
}
