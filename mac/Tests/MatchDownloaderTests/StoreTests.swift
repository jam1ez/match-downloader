import Foundation
import Testing
import MatchCore
@testable import MatchDownloader

private final class Responses: @unchecked Sendable {
    let lock = NSLock()
    private var held: [(StoreProtocol, String)] = []
    private var libraryCalls = 0
    private var ffmpeg = true
    func reset() { lock.lock(); defer { lock.unlock() }; held = []; libraryCalls = 0; ffmpeg = true }
    func setFFmpeg(_ value: Bool) { lock.lock(); defer { lock.unlock() }; ffmpeg = value }
    var pending: Int { lock.lock(); defer { lock.unlock() }; return held.count }
    var polls: Int { lock.lock(); defer { lock.unlock() }; return libraryCalls }
    func handle(_ request: StoreProtocol) {
        let path = request.request.url!.path
        if path == "/api/library" {
            lock.lock(); libraryCalls += 1; let count = libraryCalls; let installed = ffmpeg; lock.unlock()
            if count == 1 { request.reply(500, #"{"error":"Temporary connection failure"}"#) }
            else { request.reply(200, "{\"clips\":[],\"ffmpeg\":\(installed),\"storage\":\"/tmp/audit\",\"free\":123}") }
            return
        }
        if path == "/api/events/catalogue" { request.reply(200, #"{"events":[]}"#); return }
        var data = request.request.httpBody ?? Data()
        if data.isEmpty, let stream = request.request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let sku = body?["sku"] as? String ?? "A"
        if path == "/api/events/auto-time" {
            lock.lock(); held.append((request, sku)); lock.unlock(); return
        }
        if sku == "FAIL" { request.reply(400, #"{"error":"Event unavailable"}"#); return }
        request.reply(200, Self.event(sku, needsTiming: sku != "B"))
    }
    func releaseFirst() {
        lock.lock(); let (request, sku) = held.removeFirst(); lock.unlock()
        request.reply(200, Self.event(sku, needsTiming: false))
    }
    static func event(_ sku: String, needsTiming: Bool) -> String {
        let matches = needsTiming ? #"[{"key":"1:1","id":1,"name":"Q1","label":"Q1","divisionId":"1","division":"Main","available":false,"teams":[],"alliances":[]}]"# : "[]"
        return "{\"sku\":\"\(sku)\",\"name\":\"Event\",\"divisions\":[],\"matches\":\(matches),\"discovery\":{}}"
    }
}

private final class StoreProtocol: URLProtocol, @unchecked Sendable {
    static let responses = Responses()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.responses.handle(self) }
    override func stopLoading() {}
    func reply(_ status: Int, _ body: String) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized) @MainActor
struct StoreTests {
    private func setup() -> (APIClient, URLSession) {
        StoreProtocol.responses.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StoreProtocol.self]
        let session = URLSession(configuration: config)
        return (APIClient(port: 8799, token: "fixture", session: session), session)
    }
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw APIError.badResponse("Timed out waiting for fixture response")
    }
    @Test(arguments: ["B", "FAIL"])
    func eventSwitchReleasesBusyState(destination: String) async throws {
        let (client, session) = setup(); defer { session.invalidateAndCancel() }
        let store = EventStore(); store.client = client
        let first = Task { await store.load("A") }
        try await waitFor { StoreProtocol.responses.pending == 1 }
        #expect(store.working)
        await store.load(destination)
        StoreProtocol.responses.releaseFirst()
        await first.value
        #expect(!store.working)
        #expect(!store.loading)
        if destination == "B" { #expect(store.event?.sku == "B") }
        else { #expect(store.error == "Event unavailable") }
    }
    @Test func staleTimingDoesNotUnlockNewTiming() async throws {
        let (client, session) = setup(); defer { session.invalidateAndCancel() }
        let store = EventStore(); store.client = client
        let first = Task { await store.load("A") }
        try await waitFor { StoreProtocol.responses.pending == 1 }
        let second = Task { await store.load("C") }
        try await waitFor { StoreProtocol.responses.pending == 2 }
        StoreProtocol.responses.releaseFirst(); await first.value
        #expect(store.working)
        StoreProtocol.responses.releaseFirst(); await second.value
        #expect(!store.working)
        #expect(store.event?.sku == "C")
    }
    @Test func staleEditDoesNotUnlockTimingOrPublishItsError() async throws {
        let (client, session) = setup(); defer { session.invalidateAndCancel() }
        let store = EventStore(); store.client = client
        await store.load("B")
        var edit: CheckedContinuation<EventDetail, any Error>?
        var editReturned = false
        store.update { _, _ in
            defer { editReturned = true }
            return try await withCheckedThrowingContinuation { edit = $0 }
        }
        try await waitFor { edit != nil }
        let load = Task { await store.load("A") }
        try await waitFor { StoreProtocol.responses.pending == 1 }
        edit?.resume(throwing: APIError.server("Stale edit failure", status: 400))
        try await waitFor { editReturned }
        #expect(store.working)
        #expect(store.error == nil)
        StoreProtocol.responses.releaseFirst(); await load.value
        #expect(!store.working)
    }
    @Test func pollingClearsRecoveredErrorAndPreservesOtherErrors() async throws {
        let (client, session) = setup(); defer { session.invalidateAndCancel() }
        let store = LibraryStore(); store.client = client
        let poll = Task { await store.poll() }
        try await waitFor { store.error == "Temporary connection failure" }
        try await waitFor { store.ready }
        poll.cancel(); await poll.value
        #expect(store.error == nil)
        store.perform { _ = try await $0.loadEvent(sku: "FAIL") }
        try await waitFor { !store.busy }
        try await store.refresh()
        #expect(store.error == "Event unavailable")
        store.error = nil
        StoreProtocol.responses.setFFmpeg(false)
        try await store.refresh()
        #expect(store.error?.contains("FFmpeg") == true)
        StoreProtocol.responses.setFFmpeg(true)
        try await store.refresh()
        #expect(store.error == nil)
    }
}
