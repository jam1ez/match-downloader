import Foundation
import Testing
@testable import MatchCore

private final class StubState: @unchecked Sendable {
    let lock = NSLock()
    var attempt = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; attempt += 1; return attempt }
}
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let token = request.value(forHTTPHeaderField: "X-Scout-Token")
        let status: Int
        let body: String
        if request.url!.path == "/api/events/catalogue" && token == "fresh" {
            status = 200; body = #"{"events":[]}"#
        } else if request.url!.path == "/api/events/catalogue" {
            status = 403; body = #"{"error":"Forbidden"}"#
        } else {
            status = 400; body = #"{"error":"Choose a match with an official start time"}"#
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func refreshesTokenOnceOnForbiddenAndPreservesEngineErrors() async throws {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
    let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
    let state = StubState()
    let client = APIClient(baseURL: URL(string: "http://native-fixture.invalid")!, session: session) { refresh in
        let n = state.next()
        #expect(refresh == (n == 2))
        return refresh ? "fresh" : "stale"
    }
    #expect(try await client.catalogue().events.isEmpty)
    #expect(state.attempt == 2)
    do {
        try await client.setNotes(clipID: "fixture", notes: "Notes")
        Issue.record("Expected engine error")
    } catch APIError.server(let message, status: 400) {
        #expect(message == "Choose a match with an official start time")
    }
}

@Test func permanentlyForbiddenStopsAfterOneRefresh() async throws {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
    let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
    let state = StubState()
    let client = APIClient(baseURL: URL(string: "http://native-fixture.invalid")!, session: session) { _ in _ = state.next(); return "stale" }
    do { _ = try await client.catalogue(); Issue.record("Expected forbidden response") }
    catch APIError.server(_, status: 403) { #expect(state.attempt == 2) }
}
