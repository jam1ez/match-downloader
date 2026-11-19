import SwiftUI
import MatchCore

@MainActor @Observable
final class EventStore {
    var client: APIClient?
    var event: EventDetail?
    var catalogue: [CatalogueEvent] = []
    var worlds: WorldsSeason?
    var loading = false
    private var workingID: UUID?
    var working: Bool { workingID != nil }
    var error: String?
    var message = ""
    private var loadID = UUID()
    private var revision = 0
    func apply(_ value: EventDetail) { revision += 1; event = value }

    func catalogue(refresh: Bool = false) async {
        guard let client else { return }
        do { let result = try await client.catalogue(refresh: refresh); catalogue = result.events; worlds = result.worlds }
        catch { self.error = error.localizedDescription }
    }
    /// A background refresh: no error banner if the network is down. Returns true when a fresh list arrived.
    func refreshCatalogueQuietly() async -> Bool {
        guard let client, let result = try? await client.catalogue(refresh: true) else { return false }
        catalogue = result.events; worlds = result.worlds
        return result.offline != true
    }
    func archive(_ sku: String, _ archived: Bool) async {
        guard let client else { return }
        do { try await client.archiveEvent(sku: sku, archived: archived); await catalogue() }
        catch { self.error = error.localizedDescription }
    }
    /// Returns true when the event was removed from this Mac.
    func remove(_ sku: String) async -> Bool {
        guard let client else { return false }
        do {
            try await client.removeEvent(sku: sku)
            if event?.sku == sku { event = nil }
            await catalogue()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func load(_ sku: String, refresh: Bool = false) async {
        guard let client else { return }
        let id = UUID(); loadID = id; workingID = nil; loading = true; error = nil
        defer { if id == loadID { loading = false } }
        do {
            let result = try await client.loadEvent(sku: sku, refresh: refresh)
            guard loadID == id else { return }
            apply(result)
            await catalogue()
            guard loadID == id else { return }
            if result.discovery == nil {
                let rev = revision
                if let discovered = try? await client.discoverStreams(sku: result.sku), loadID == id {
                    if revision == rev { event = discovered } else { event?.discovery = discovered.discovery }
                }
            }
            guard loadID == id, let current = event else { return }
            if current.matches.contains(where: { !$0.available }), current.autoTiming == nil || (current.cached != true && (current.autoTiming?.checked ?? 0) < (current.fetched ?? 0)) {
                let rev = revision
                workingID = id
                defer { if workingID == id { workingID = nil } }
                if let timed = try? await client.autoTime(sku: result.sku), loadID == id, revision == rev { apply(timed) }
            }
        } catch { if loadID == id { event = nil; self.error = error.localizedDescription } }
    }
    func update(_ operation: @escaping @MainActor (APIClient, String) async throws -> EventDetail) {
        guard let client, let sku = event?.sku, !working else { return }
        let id = UUID(); workingID = id; error = nil; revision += 1
        let rev = revision
        Task {
            defer { if workingID == id { workingID = nil } }
            do {
                let result = try await operation(client, sku)
                if event?.sku == sku && revision == rev { apply(result) }
            } catch { if workingID == id { self.error = error.localizedDescription } }
        }
    }
}
