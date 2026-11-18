import SwiftUI
import MatchCore

@MainActor @Observable
final class EventStore {
    var client: APIClient?
    var event: EventDetail?
    var catalogue: [CatalogueEvent] = []
    var loading = false
    var working = false
    var error: String?
    var message = ""
    private var loadID = UUID()
    private var revision = 0
    func apply(_ value: EventDetail) { revision += 1; event = value }

    func catalogue(refresh: Bool = false) async {
        guard let client else { return }
        do { catalogue = try await client.catalogue(refresh: refresh).events }
        catch { self.error = error.localizedDescription }
    }
    func load(_ sku: String, refresh: Bool = false) async {
        guard let client else { return }
        let id = UUID(); loadID = id; loading = true; error = nil
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
                working = true
                defer { if loadID == id { working = false } }
                if let timed = try? await client.autoTime(sku: result.sku), loadID == id, revision == rev { apply(timed) }
            }
        } catch { if loadID == id { event = nil; self.error = error.localizedDescription } }
    }
    func update(_ operation: @escaping @MainActor (APIClient, String) async throws -> EventDetail) {
        guard let client, let sku = event?.sku, !working else { return }
        working = true; error = nil; revision += 1
        let rev = revision
        Task {
            defer { working = false }
            do {
                let result = try await operation(client, sku)
                if event?.sku == sku && revision == rev { apply(result) }
            } catch { self.error = error.localizedDescription }
        }
    }
}
