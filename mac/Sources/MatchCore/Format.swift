import Foundation

public enum Format {
    public static func clock(_ seconds: Double) -> String {
        let n = seconds.isFinite ? Int(max(0, seconds).rounded(.down)) : 0
        return String(format: "%02d:%02d:%02d", n / 3600, n % 3600 / 60, n % 60)
    }
    public static func parseClock(_ text: String) -> Double? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let n = Double(part), n.isFinite, n >= 0 else { return nil }
            total = total * 60 + n
        }
        return total < 604800 ? total : nil
    }
    public static func size(_ bytes: Int64) -> String {
        if bytes >= 1_073_741_824 { return String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
        if bytes >= 1_048_576 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        return bytes > 0 ? "\(max(1, Int((Double(bytes) / 1024).rounded()))) KB" : ""
    }
    public static func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String {
        "\(n) \(n == 1 ? one : many ?? one + "s")"
    }
    public static func dayName(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        guard let d = parser.date(from: iso + "T12:00:00Z") else { return iso }
        return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
    public static func dateRange(_ days: [String]) -> String {
        guard let first = days.first, let last = days.last else { return "" }
        return first == last ? dayName(first) : "\(dayName(first)) – \(dayName(last))"
    }
}

public enum Labels {
    public static func show(_ label: String) -> String {
        label.replacingOccurrences(of: "^R16([0-9]+-[0-9]+)$", with: "R16 $1", options: .regularExpression)
    }
    public static func round(_ label: String) -> String {
        if label.range(of: "^Q[0-9]+$", options: .regularExpression) != nil { return "Q" }
        if label.hasPrefix("R16") { return "R16" }
        return String(label.prefix { $0.isLetter })
    }
    public static func day(_ match: Match) -> String { String((match.started ?? match.scheduled ?? "").prefix(10)) }
    public static func status(_ status: String) -> String {
        ["ready": "Saved", "needs_review": "Needs review", "queued": "Waiting", "downloading": "Downloading",
         "analyzing": "Reading match clock", "processing": "Processing", "failed": "Failed", "cancelled": "Stopped"][status] ?? status
    }
    public static func failure(_ detail: String?) -> String {
        let lines = (detail ?? "").components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let raw = lines.last { $0.hasPrefix("ERROR:") } ?? lines.last ?? "Download failed"
        // Vimeo (and some other hosts) only serve certain videos to signed-in viewers; say so plainly.
        if raw.localizedCaseInsensitiveContains("only works when logged-in") || raw.contains("HTTP Error 401") {
            return "The video's host wants a login for this recording, so it can't be downloaded here. You can still watch it in your browser (Open Recording), or choose another livestream for the event under Livestream in the event panel."
        }
        return raw.replacingOccurrences(of: "^ERROR:\\s*(\\[[^\\]]+\\]\\s*)?", with: "", options: .regularExpression)
    }
    public static func source(_ match: Match) -> String {
        if let label = match.streamLabel, !label.isEmpty { return label }
        let t = match.timing ?? ""
        return ["Jumper": "Event feed", "BoxCast estimate": "Worlds broadcast", "Manual calibration": "Set by you",
                "Recording calibration": "Set by you", "Auto timing (broadcast start)": "Broadcast start time", "Stream sync": "Your recording"][t]
            ?? t.replacingOccurrences(of: " (same recording)", with: "")
    }
    public static func noPosition(_ timing: String?) -> String {
        ["Needs timing": "No position", "Choose recording": "Choose a recording", "Needs sync or another recording": "Recording not lined up"][timing ?? ""] ?? "No position"
    }
}

public extension Clip {
    var matchLabel: String { eventRef != nil && title.components(separatedBy: " · ").count > 2 ? Labels.show(title.components(separatedBy: " · ").last ?? title) : title }
    var divisionLabel: String { let parts = title.components(separatedBy: " · "); return eventRef != nil && parts.count > 2 ? parts[parts.count - 2] : "" }
    var eventLabel: String { let parts = title.components(separatedBy: " · "); return eventRef != nil && parts.count > 2 ? parts.dropLast(2).joined(separator: " · ") : "From a link" }
    var duration: Double { end - start }
    var statusLabel: String { Labels.status(status) }
    var recordingRange: String { clipMode == "dynamic" && status != "ready" ? "Near " + Format.clock(detectAnchor ?? start) : Format.clock(start) + "–" + Format.clock(end) }
}
