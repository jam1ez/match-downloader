import SwiftUI
import MatchCore

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    var backend: BackendProcess?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let backend else { return .terminateNow }
        // Downloads keep going after quit: ask the engine to exit once it is idle. If it can't be asked, stop it.
        // Runs off the main actor so quitting works however it was triggered.
        let client = backend.configuration.client
        Task.detached {
            let keepRunning = (try? await client.quitWhenIdle(true))?.scheduled == true
            // AppKit waits for this reply in its modal-panel run-loop mode, which the main dispatch queue doesn't serve.
            RunLoop.main.perform(inModes: [.default, .modalPanel, .eventTracking]) {
                MainActor.assumeIsolated {
                    if keepRunning { backend.releaseEngine() } else { backend.stop() }
                    sender.reply(toApplicationShouldTerminate: true)
                }
            }
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { backend?.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct MatchDownloaderApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    @State private var message = "Connecting to your library…"
    @State private var ready = false
    @State private var store = LibraryStore()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup("Match Downloader", id: "workspace") {
            Group {
                if ready { WorkspaceView(library: store) }
                else { StartupMessage(message: message) }
            }.frame(minWidth: 700, minHeight: 440)
            .task(id: ready && scenePhase == .active) { if ready && scenePhase == .active { await store.poll() } }
            .safeAreaInset(edge: .bottom) { if let error = store.error { HStack { Text(error).textSelection(.enabled); Spacer(); Button("Dismiss") { store.error = nil } }.padding().background(.bar) } }
            .task {
                if let flag = CommandLine.arguments.firstIndex(of: "--verify-player"), CommandLine.arguments.indices.contains(flag + 1) {
                    do { try await PlayerVerification.run(url: URL(fileURLWithPath: CommandLine.arguments[flag + 1])); print("VERIFY_PLAYER_PASS") }
                    catch { print("VERIFY_FAILED: \(error)") }
                    NSApplication.shared.terminate(nil); return
                }
                guard delegate.backend == nil else { return }
                do {
                    let configuration = try BackendConfiguration()
                    if CommandLine.arguments.contains(where: { $0.hasPrefix("--verify-") || $0 == "--smoke-test" }) {
                        guard configuration.port == 8799, configuration.data.resolvingSymlinksInPath() != configuration.root.appendingPathComponent("library").resolvingSymlinksInPath() else {
                            throw APIError.badResponse("Verification requires a copied library and port 8799.")
                        }
                    }
                    let backend = BackendProcess(configuration: configuration)
                    delegate.backend = backend
                    try await backend.start()
                    store.client = backend.configuration.client
                    try await store.refresh()
                    let library = try await backend.configuration.client.library()
                    message = "\(library.clips.count) downloads in your library"; ready = true
                    if CommandLine.arguments.contains("--verify-recordings") {
                        try await Verification.recordings(backend.configuration.client)
                        print("VERIFY_RECORDINGS_PASS")
                        NSApplication.shared.terminate(nil)
                    }
                    if CommandLine.arguments.contains("--verify-schedule") {
                        try await Verification.schedule(backend.configuration.client)
                        print("VERIFY_SCHEDULE_PASS")
                        NSApplication.shared.terminate(nil)
                    }
                    if CommandLine.arguments.contains("--verify-downloads") {
                        try await Verification.downloads(backend.configuration.client)
                        print("VERIFY_DOWNLOADS_PASS")
                        NSApplication.shared.terminate(nil)
                    }
                    if CommandLine.arguments.contains("--smoke-test") {
                        print("MATCH_NATIVE_READY owned=\(backend.process != nil)")
                        try await Task.sleep(for: .seconds(1))
                        NSApplication.shared.terminate(nil)
                    }
                } catch { message = error.localizedDescription; if CommandLine.arguments.contains(where: { $0.hasPrefix("--verify-") || $0 == "--smoke-test" }) { print("VERIFY_FAILED: \(message)"); NSApplication.shared.terminate(nil) } }
            }
        }
        .defaultSize(width: 1280, height: 800)
        .commands { MatchCommands() }
        Settings { AppSettings(library: store) }
        WindowGroup(for: PreviewItem.self) { $item in if let item { PreviewWindow(item: item) } }
            .defaultSize(width: 960, height: 540).windowResizability(.contentMinSize)
        WindowGroup(for: Playback.self) { $item in if let item { PlaybackView(playback: item) } }
            .defaultSize(width: 1120, height: 630).windowResizability(.contentMinSize)
    }
}

/// What the window shows until the library is ready. A message with a Terminal command
/// ("… In Terminal: <command>") shows the command on its own, selectable, with a Copy button.
struct StartupMessage: View {
    let message: String
    @State private var copied = false
    private var parts: (text: String, command: String?) {
        guard let range = message.range(of: " In Terminal: ") else { return (message, nil) }
        return (String(message[..<range.lowerBound]), String(message[range.upperBound...]))
    }
    var body: some View {
        ContentUnavailableView {
            Label("Match Downloader", systemImage: "film")
        } description: {
            Text(parts.text).textSelection(.enabled)
        } actions: {
            if let command = parts.command {
                VStack(spacing: 10) {
                    Text("Paste this into Terminal:").font(.callout).foregroundStyle(.secondary)
                    Text(command).font(.body.monospaced()).textSelection(.enabled)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.quaternary, in: .rect(cornerRadius: 8))
                    Button(copied ? "Copied" : "Copy Command", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        copied = true
                    }.keyboardShortcut("c", modifiers: [.command, .shift])
                }
            }
        }
        .onChange(of: message) { copied = false }
    }
}
