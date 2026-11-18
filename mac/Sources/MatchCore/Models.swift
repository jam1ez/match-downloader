import Foundation

// Models decoded from the engine's JSON (see app.py and events.py). Fields that are
// sometimes absent or null in real data are optional, so one odd record never makes a
// whole event fail to open. Open-ended fields use JSONValue.

// MARK: Health

public struct Health: Codable, Sendable, Hashable {
    public var app: String
    public var status: String
    /// Version of the JSON API. Absent on engines older than the native app.
    public var api: Int?
}

// MARK: Downloads (clips)

public enum ClipStatus: String, Sendable, Hashable, CaseIterable {
    case ready, needsReview = "needs_review", queued, downloading, analyzing, processing, failed, cancelled

    public var isActive: Bool {
        switch self {
        case .queued, .downloading, .analyzing, .processing: true
        default: false
        }
    }
    public var canRetry: Bool { self == .failed || self == .cancelled }
}

public struct Clip: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var url: String
    public var start: Double
    public var end: Double
    public var notes: String?
    public var status: String
    public var detail: String?
    public var created: Double
    public var eventRef: String?
    public var matchRef: String?
    public var clipMode: String?
    public var sourceStart: Double?
    public var analysisJSON: String?
    public var detectSettings: String?
    public var bytes: Int
    /// How far a running download has got. Present only while the job is active.
    public var progress: ClipProgress?

    enum CodingKeys: String, CodingKey {
        case id, title, url, start, end, notes, status, detail, created, bytes, progress
        case eventRef = "event_ref", matchRef = "match_ref", clipMode = "clip_mode"
        case sourceStart = "source_start", analysisJSON = "analysis_json", detectSettings = "detect_settings"
    }

    public var state: ClipStatus? { ClipStatus(rawValue: status) }
    public var isActive: Bool { state?.isActive ?? false }
    public var createdDate: Date { Date(timeIntervalSince1970: created) }

    /// Analysis written by match-clock detection (empty when the job has none).
    public var analysis: ClipAnalysis? {
        guard let analysisJSON, let data = analysisJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ClipAnalysis.self, from: data)
    }

    public var detectAnchor: Double? {
        guard let detectSettings, let data = detectSettings.data(using: .utf8),
              let v = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return v["anchor"]?.double
    }
}

public struct ClipProgress: Codable, Sendable, Hashable {
    /// 0...1, or nil when the length of the current step isn't known (reading the match clock).
    public var fraction: Double?
    /// Seconds left at the current speed.
    public var eta: Double?
}

public struct ClipAnalysis: Codable, Sendable, Hashable {
    public var start: Double?
    public var end: Double?
    public var sourceDuration: Double?
    public var sourceStart: Double?
    public var confidence: String?
    public var reason: String?
    public var pause: Double?

    enum CodingKeys: String, CodingKey {
        case start, end, confidence, reason, pause
        case sourceDuration = "source_duration", sourceStart = "source_start"
    }
}

public struct LibraryState: Codable, Sendable, Hashable {
    public var clips: [Clip]
    public var ffmpeg: Bool
    public var storage: String
    public var free: Int64
}

public struct QueueResult: Codable, Sendable, Hashable {
    public var added: [String]
    public var skipped: [String]
}

// MARK: Catalogue

public struct CatalogueEvent: Codable, Sendable, Hashable, Identifiable {
    public var sku: String
    public var name: String
    public var saved: Bool
    public var custom: Bool
    /// Put away by the user: still saved on this Mac, listed under Archived.
    public var archived: Bool?
    public var isArchived: Bool { saved && archived == true }
    public var id: String { sku }
    public init(sku: String, name: String, saved: Bool, custom: Bool = false, archived: Bool? = nil) {
        self.sku = sku; self.name = name; self.saved = saved; self.custom = custom; self.archived = archived
    }
}

/// The Worlds folder: which Worlds it is comes from the engine's worlds-season.json, never from the interface.
public struct WorldsSeason: Codable, Sendable, Hashable {
    public var title: String
    public var year: String
    public var events: [WorldsEvent]
}
public struct WorldsEvent: Codable, Sendable, Hashable, Identifiable {
    public var sku: String
    public var label: String
    public var program: String
    public var start: String?
    public var end: String?
    public var channelId: String?
    public var saved: Bool?
    public var id: String { sku }
    /// The event's channel on vexworlds.tv.
    public var channelURL: URL? { channelId.flatMap { $0.isEmpty ? nil : URL(string: "https://www.vexworlds.tv/#/channels/\($0)") } }
}

public struct Catalogue: Codable, Sendable, Hashable {
    public var events: [CatalogueEvent]
    public var worlds: WorldsSeason?
    public var offline: Bool?
    public var cached: Bool?
}

// MARK: Event schedule

public struct Division: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
}

public struct Alliance: Codable, Sendable, Hashable {
    public var color: String
    public var teams: [String]
    public var score: Int?
}

public struct StreamOption: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var url: String?
    public var timestamp: Double?
    public var score: Double?
    public var automatic: Bool?
}

public struct Match: Codable, Sendable, Hashable, Identifiable {
    public var key: String
    public var matchID: Int
    public var name: String
    public var label: String
    public var divisionId: String
    public var division: String
    public var timestamp: Double?
    public var url: String?
    public var available: Bool
    public var teams: [String]
    public var alliances: [Alliance]
    public var field: String?
    public var scheduled: String?
    public var started: String?
    public var timing: String?
    public var streamOptions: [StreamOption]?
    public var streamId: String?
    public var streamLabel: String?

    public var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, name, label, divisionId, division, timestamp, url, available, teams, alliances
        case field, scheduled, started, timing, streamOptions, streamId, streamLabel
        case matchID = "id"
    }

    public func alliance(_ color: String) -> Alliance? { alliances.first { $0.color == color } }
    public var red: Alliance? { alliance("red") }
    public var blue: Alliance? { alliance("blue") }

    /// Video position in seconds, only when the match has a usable position.
    public var videoPosition: Double? { available ? timestamp : nil }
}

public struct Program: Codable, Sendable, Hashable {
    public var id: Int?
    public var name: String?
    public var code: String?
}

/// A recording added to an event (a YouTube video, a stream, …) and how it lines up with matches.
public struct Recording: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var url: String
    public var divisionId: String
    public var date: String
    public var field: String?
    public var syncMode: String
    public var basis: String?
    public var offset: Double?
    public var duration: Double?
    public var enabled: Bool?
    public var firstMatch: String?
    public var lastMatch: String?
    public var anchorKey: String?
    public var anchorPosition: Double?
    public var wallStart: String?
    public var fillOnly: Bool?
    public var metadata: StreamMetadata?

    public var isEnabled: Bool { enabled != false }
}

/// What the engine learned about a recording by reading its page (title, length, start time).
public struct StreamMetadata: Codable, Sendable, Hashable {
    public var raw: JSONValue

    public init(raw: JSONValue = .object([:])) { self.raw = raw }
    public init(from decoder: Decoder) throws { raw = try JSONValue(from: decoder) }
    public func encode(to encoder: Encoder) throws { try raw.encode(to: encoder) }

    public var title: String? { raw["title"]?.string }
    public var channel: String? { raw["channel"]?.string }
    public var duration: Double? { raw["duration"]?.double }
    public var startEstimate: String? { raw["startEstimate"]?.string }
    public var startSource: String? { raw["startSource"]?.string }
    /// Other recordings found when the link was a channel.
    public var recordings: [ChannelRecording] {
        (raw["recordings"]?.array ?? []).compactMap { v in
            guard let url = v["url"]?.string else { return nil }
            return ChannelRecording(title: v["title"]?.string, url: url)
        }
    }
}

public struct ChannelRecording: Sendable, Hashable, Identifiable {
    public var title: String?
    public var url: String
    public var id: String { url }
}

public struct DiscoveryCandidate: Codable, Sendable, Hashable {
    public var url: String
    public var label: String?
    public var platform: String
    public var source: String?
    public var divisionId: String?
    public var dayIndex: Int?
    public var streamStartTime: String?
}

public struct Discovery: Codable, Sendable, Hashable {
    public var candidates: [DiscoveryCandidate]?
    public var description: String?
    public var checked: Double?
    public var errors: [String]?
}

public struct AutoTiming: Codable, Sendable, Hashable {
    public var checked: Double?
    public var added: Int?
    public var updated: Int?
    public var available: Int?
    public var total: Int?
    public var messages: [String]?
}

public struct StreamSummary: Codable, Sendable, Hashable {
    public var recordings: Int?
    public var mapped: Int?
    public var ambiguous: Int?
    public var estimated: Int?
}

public struct EventDetail: Codable, Sendable, Hashable, Identifiable {
    public var sku: String
    public var name: String
    public var divisions: [Division]
    public var matches: [Match]
    public var fetched: Double?
    public var warning: String?
    public var cached: Bool?
    public var eventID: Int?
    public var start: String?
    public var end: String?
    public var program: Program?
    public var location: JSONValue?
    public var sourceUrl: String?
    public var streams: [Recording]?
    public var streamChoices: [String: String]?
    public var discovery: Discovery?
    public var autoTiming: AutoTiming?
    public var recordingDurations: [String: Double]?
    public var days: [String]?
    public var streamSummary: StreamSummary?

    public var id: String { sku }

    enum CodingKeys: String, CodingKey {
        case sku, name, divisions, matches, fetched, warning, cached, start, end, program, location
        case sourceUrl, streams, streamChoices, discovery, autoTiming, recordingDurations, days, streamSummary
        case eventID = "id"
    }

    public var recordings: [Recording] { streams ?? [] }
    public var allDays: [String] { days ?? [] }
    public var matchesByKey: [String: Match] { Dictionary(matches.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a }) }
    public var matchesWithVideo: Int { matches.filter(\.available).count }
}

// MARK: Probe

/// The result of reading a recording's page. Open-ended, so it stays a JSONValue.
public struct StreamProbe: Codable, Sendable, Hashable {
    public var metadata: StreamMetadata
    public init(metadata: StreamMetadata) { self.metadata = metadata }
    public init(from decoder: Decoder) throws { metadata = try StreamMetadata(from: decoder) }
    public func encode(to encoder: Encoder) throws { try metadata.encode(to: encoder) }
}

public struct PreviewSource: Codable, Sendable, Hashable {
    public var url: String
}

// MARK: Requests

public struct QueueRequest: Encodable, Sendable {
    public var sku: String
    public var keys: [String]
    public var mode: String
    public var duration: Double
    public var before: Double
    public var tail: Double
    public var window: Double
    public var offset: Double

    public init(sku: String, keys: [String], mode: String = "dynamic", duration: Double = 180, before: Double = 5,
                tail: Double = 5, window: Double = 480, offset: Double = 0) {
        self.sku = sku; self.keys = keys; self.mode = mode; self.duration = duration
        self.before = before; self.tail = tail; self.window = window; self.offset = offset
    }
}

/// A recording as edited in the sheet, sent to /api/events/streams/save.
public struct StreamDraft: Encodable, Sendable, Hashable {
    public var id: String?
    public var label: String
    public var url: String
    public var date: String
    public var divisionId: String
    public var field: String
    public var basis: String
    public var firstMatch: String
    public var lastMatch: String
    public var syncMode: String
    public var anchorKey: String
    public var anchorPosition: Double
    public var wallStart: String
    public var offset: Double
    public var duration: Double?
    public var enabled: Bool
    public var fillOnly: Bool
    public var metadata: JSONValue

    public init(id: String? = nil, label: String = "", url: String = "", date: String = "", divisionId: String = "*",
                field: String = "", basis: String = "actual", firstMatch: String = "", lastMatch: String = "",
                syncMode: String = "auto", anchorKey: String = "", anchorPosition: Double = 0, wallStart: String = "",
                offset: Double = 0, duration: Double? = nil, enabled: Bool = true, fillOnly: Bool = false,
                metadata: JSONValue = .object([:])) {
        self.id = id; self.label = label; self.url = url; self.date = date; self.divisionId = divisionId
        self.field = field; self.basis = basis; self.firstMatch = firstMatch; self.lastMatch = lastMatch
        self.syncMode = syncMode; self.anchorKey = anchorKey; self.anchorPosition = anchorPosition
        self.wallStart = wallStart; self.offset = offset; self.duration = duration
        self.enabled = enabled; self.fillOnly = fillOnly; self.metadata = metadata
    }

    public init(editing r: Recording) {
        self.init(id: r.id, label: r.label, url: r.url, date: r.date, divisionId: r.divisionId, field: r.field ?? "",
                  basis: r.basis ?? "actual", firstMatch: r.firstMatch ?? "", lastMatch: r.lastMatch ?? "",
                  syncMode: r.syncMode, anchorKey: r.anchorKey ?? "", anchorPosition: r.anchorPosition ?? 0,
                  wallStart: r.wallStart ?? "", offset: r.offset ?? 0, duration: r.duration,
                  enabled: r.isEnabled, fillOnly: r.fillOnly ?? false, metadata: r.metadata?.raw ?? .object([:]))
    }

    // Omit a nil id and duration rather than sending null.
    enum CodingKeys: String, CodingKey {
        case id, label, url, date, divisionId, field, basis, firstMatch, lastMatch, syncMode
        case anchorKey, anchorPosition, wallStart, offset, duration, enabled, fillOnly, metadata
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(label, forKey: .label); try c.encode(url, forKey: .url); try c.encode(date, forKey: .date)
        try c.encode(divisionId, forKey: .divisionId); try c.encode(field, forKey: .field)
        try c.encode(basis, forKey: .basis); try c.encode(firstMatch, forKey: .firstMatch)
        try c.encode(lastMatch, forKey: .lastMatch); try c.encode(syncMode, forKey: .syncMode)
        try c.encode(anchorKey, forKey: .anchorKey); try c.encode(anchorPosition, forKey: .anchorPosition)
        try c.encode(wallStart, forKey: .wallStart); try c.encode(offset, forKey: .offset)
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encode(enabled, forKey: .enabled); try c.encode(fillOnly, forKey: .fillOnly)
        try c.encode(metadata, forKey: .metadata)
    }
}

/// A new clip from a link or a list file (/api/clips). Times are "seconds" or "HH:MM:SS" text.
public struct NewClip: Codable, Sendable, Hashable {
    public var title: String
    public var url: String
    public var start: String
    public var end: String
    public var notes: String

    public init(title: String, url: String, start: String, end: String, notes: String = "") {
        self.title = title; self.url = url; self.start = start; self.end = end; self.notes = notes
    }

    enum CodingKeys: String, CodingKey { case title, url, start, end, notes }

    // Import files may give numbers or text, and may leave notes out.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        url = try c.decode(String.self, forKey: .url)
        start = try Self.timeText(c, .start)
        end = try Self.timeText(c, .end)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
    private static func timeText(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> String {
        if let s = try? c.decode(String.self, forKey: key) { return s }
        let n = try c.decode(Double.self, forKey: key)
        return n == n.rounded() ? String(Int(n)) : String(n)
    }
}
