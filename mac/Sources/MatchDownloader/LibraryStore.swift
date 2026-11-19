import SwiftUI
import MatchCore
import UserNotifications

@MainActor @Observable
final class LibraryStore {
    var client: APIClient?
    var clips: [Clip] = []
    var storage = ""
    var free: Int64 = 0
    var message = "Connecting to your library…"
    private var connectionError: String?
    private var operationError: String?
    private var capabilityError: String?
    var error: String? {
        get { operationError ?? connectionError ?? capabilityError }
        set {
            operationError = newValue
            if newValue == nil { connectionError = nil; capabilityError = nil }
        }
    }
    var ready = false
    var busy = false
    private var pollingTask: Task<Void, Never>?
    private var pollingUsers: Set<UUID> = []
    var activeCount: Int { clips.filter(\.isActive).count }

    func refresh() async throws {
        guard let client else { return }
        let library: LibraryState
        do { library = try await client.library() }
        catch is CancellationError { throw CancellationError() }
        catch { connectionError = error.localizedDescription; throw error }
        connectionError = nil
        capabilityError = library.ffmpeg ? nil : "FFmpeg isn’t installed. Install FFmpeg, then reopen the app to download matches."
        let old = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0.status) })
        // Stable IDs preserve table selection and row identity while values update in place.
        if clips != library.clips { clips = library.clips }; storage = library.storage; free = library.free
        NSApplication.shared.dockTile.badgeLabel = activeCount == 0 ? nil : String(activeCount)
        if ready {
            for clip in clips where old[clip.id] != nil && old[clip.id] != clip.status && ["ready", "needs_review", "failed"].contains(clip.status) {
                await notify(clip)
            }
        }
        ready = true
        message = "\(Format.plural(clips.filter { $0.status == "ready" }.count, "saved match", "saved matches")), \(Format.size(free)) free"
    }
    func poll() async {
        let id = UUID(); pollingUsers.insert(id)
        if pollingTask == nil {
            pollingTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    do { try await self.refresh() }
                    catch is CancellationError { return }
                    catch { /* refresh records connection failures separately from operation errors. */ }
                    do { try await Task.sleep(for: .milliseconds(2500)) } catch { return }
                }
            }
        }
        while !Task.isCancelled { do { try await Task.sleep(for: .seconds(1)) } catch { break } }
        pollingUsers.remove(id)
        if pollingUsers.isEmpty { pollingTask?.cancel(); pollingTask = nil }
    }
    func perform(_ operation: @escaping @MainActor (APIClient) async throws -> Void) {
        guard let client, !busy else { return }
        busy = true; operationError = nil
        Task {
            defer { busy = false }
            do { try await operation(client) }
            catch { operationError = error.localizedDescription; return }
            do { try await refresh() }
            catch { /* refresh records the connection error. */ }
        }
    }
    private func notify(_ clip: Clip) async {
        guard DownloadNotifications.enabled() else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = clip.title; content.body = Labels.status(clip.status)
        if clip.status == "failed" { content.body += ": " + Labels.failure(clip.detail) }
        try? await center.add(UNNotificationRequest(identifier: clip.id + clip.status, content: content, trigger: nil))
    }
}
