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
    var error: String?
    var ready = false
    var busy = false
    private var pollingTask: Task<Void, Never>?
    private var pollingUsers: Set<UUID> = []
    var activeCount: Int { clips.filter(\.isActive).count }

    func refresh() async throws {
        guard let client else { return }
        let library = try await client.library()
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
        if !library.ffmpeg { error = "FFmpeg isn’t installed. Install FFmpeg, then reopen the app to download matches." }
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
                    catch { self.error = error.localizedDescription }
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
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { try await operation(client); try await refresh() }
            catch { self.error = error.localizedDescription }
        }
    }
    private func notify(_ clip: Clip) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = clip.title; content.body = Labels.status(clip.status)
        if clip.status == "failed" { content.body += ": " + Labels.failure(clip.detail) }
        try? await center.add(UNNotificationRequest(identifier: clip.id + clip.status, content: content, trigger: nil))
    }
}
