import Foundation

public enum APIError: Error, LocalizedError, Sendable, Equatable {
    /// The engine answered with an error message meant for people.
    case server(String, status: Int)
    /// The engine could not be reached at all.
    case unreachable(String)
    /// The engine answered with something that isn't the expected JSON.
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .server(let m, _): m
        case .unreachable(let m): m
        case .badResponse(let m): m
        }
    }
}

/// Reads the per-run token the engine writes to `<library>/.session-token`.
public enum SessionToken {
    public static func fileURL(dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent(".session-token")
    }

    /// `MATCH_DOWNLOADER_TOKEN` wins, as it does for the engine.
    public static func read(dataDirectory: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let t = environment["MATCH_DOWNLOADER_TOKEN"], !t.isEmpty { return t }
        guard let text = try? String(contentsOf: fileURL(dataDirectory: dataDirectory), encoding: .utf8) else { return nil }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// One async function per engine endpoint (redesign/swiftui/PLAN.md > API surface).
public struct APIClient: Sendable {
    public typealias TokenProvider = @Sendable (_ refresh: Bool) async throws -> String

    public let baseURL: URL
    private let session: URLSession
    private let tokenProvider: TokenProvider

    public init(baseURL: URL, session: URLSession = .shared, tokenProvider: @escaping TokenProvider) {
        self.baseURL = baseURL; self.session = session; self.tokenProvider = tokenProvider
    }

    public init(port: Int, token: String, session: URLSession = .shared) {
        self.init(baseURL: URL(string: "http://127.0.0.1:\(port)")!, session: session, tokenProvider: { _ in token })
    }

    // MARK: Reads

    public func health() async throws -> Health { try await get("api/health", timeout: 2) }
    public func library() async throws -> LibraryState { try await get("api/library") }

    /// URL for a saved clip (or its review window) that AVPlayer can stream.
    public func videoURL(clipID: String, review: Bool = false) -> URL {
        baseURL.appendingPathComponent(review ? "review" : "video").appendingPathComponent(clipID)
    }

    // MARK: Events

    public func catalogue(refresh: Bool = false) async throws -> Catalogue {
        try await post("api/events/catalogue", ["refresh": refresh])
    }
    public func loadEvent(sku: String, refresh: Bool = false) async throws -> EventDetail {
        try await post("api/events/load", Body(["sku": .string(sku), "refresh": .bool(refresh)]))
    }
    @discardableResult
    public func queue(_ request: QueueRequest) async throws -> QueueResult { try await post("api/events/queue", request) }

    public func calibrate(sku: String, key: String, url: String, timestamp: String) async throws -> EventDetail {
        try await post("api/events/calibrate", ["sku": sku, "key": key, "url": url, "timestamp": timestamp])
    }
    public func saveStream(sku: String, stream: StreamDraft) async throws -> EventDetail {
        try await post("api/events/streams/save", SaveStream(sku: sku, stream: stream))
    }
    public func deleteStream(sku: String, id: String) async throws -> EventDetail {
        try await post("api/events/streams/delete", ["sku": sku, "id": id])
    }
    public func chooseStream(sku: String, key: String, id: String) async throws -> EventDetail {
        try await post("api/events/streams/choose", ["sku": sku, "key": key, "id": id])
    }
    public func discoverStreams(sku: String, refresh: Bool = false) async throws -> EventDetail {
        try await post("api/events/streams/discover", Body(["sku": .string(sku), "refresh": .bool(refresh)]))
    }
    public func probeStream(url: String) async throws -> StreamProbe { try await post("api/events/streams/probe", ["url": url]) }
    public func autoTime(sku: String, search: Bool = true) async throws -> EventDetail {
        try await post("api/events/auto-time", Body(["sku": .string(sku), "search": .bool(search)]))
    }

    // MARK: Preview

    public func previewSource(url: String) async throws -> PreviewSource { try await post("api/preview/source", ["url": url]) }

    // MARK: Clips

    /// Returns the new clip's id.
    @discardableResult
    public func addClip(_ clip: NewClip) async throws -> String {
        struct Created: Decodable { var id: String }
        let created: Created = try await post("api/clips", clip)
        return created.id
    }
    public func retry(clipID: String) async throws { try await clipAction(clipID, "retry") }
    public func cancel(clipID: String) async throws { try await clipAction(clipID, "cancel") }
    public func delete(clipID: String) async throws { try await clipAction(clipID, "delete") }
    public func setNotes(clipID: String, notes: String) async throws { try await clipAction(clipID, "notes", ["notes": notes]) }
    /// Saves the start and end chosen in the review window (seconds into the review recording).
    public func setBounds(clipID: String, start: String, end: String) async throws {
        try await clipAction(clipID, "bounds", ["start": start, "end": end])
    }

    // MARK: Plumbing

    private struct Body: Encodable {
        var values: [String: JSONValue]
        init(_ values: [String: JSONValue]) { self.values = values }
        func encode(to encoder: Encoder) throws { try values.encode(to: encoder) }
    }
    private struct SaveStream: Encodable { var sku: String; var stream: StreamDraft }
    private struct OK: Decodable { var ok: Bool? }

    private func clipAction(_ id: String, _ action: String, _ body: [String: String] = [:]) async throws {
        let _: OK = try await post("api/clips/\(id)/\(action)", body)
    }

    private func get<T: Decodable>(_ path: String, timeout: TimeInterval = 15) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = timeout
        return try await send(request)
    }

    private func post<T: Decodable, B: Encodable>(_ path: String, _ body: B) async throws -> T {
        let data = try JSONEncoder().encode(body)
        var forceRefresh = false
        while true {
            var request = URLRequest(url: baseURL.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalCacheData)
            request.httpMethod = "POST"
            request.httpBody = data
            request.timeoutInterval = 120
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(try await tokenProvider(forceRefresh), forHTTPHeaderField: "X-Scout-Token")
            do { return try await send(request) }
            catch APIError.server(_, 403) where !forceRefresh {
                // The engine may have restarted with a new token: read it again once.
                forceRefresh = true
            }
        }
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let e as URLError where e.code == .cancelled { throw CancellationError() }
        catch {
            throw APIError.unreachable("Match Downloader’s engine isn’t responding. Reopen the app to restart it.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw APIError.server(message ?? "The request failed.", status: status)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw APIError.badResponse("The engine sent something this version of the app can’t read.") }
    }
}
