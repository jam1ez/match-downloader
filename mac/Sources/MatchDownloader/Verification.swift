import Foundation
import AVFoundation
import WebKit
import MatchCore

/// Opt-in integration checks; requires a copied library prepared by scripts/verify-native.py.
@MainActor
enum Verification {
    static func wait(_ client: APIClient, id: String, for statuses: Set<String>, seconds: Int = 100) async throws -> Clip {
        for _ in 0..<(seconds * 2) {
            if let clip = try await client.library().clips.first(where: { $0.id == id }), statuses.contains(clip.status) { return clip }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw APIError.badResponse("Timed out waiting for \(id) to become \(statuses).")
    }
    static func downloads(_ client: APIClient) async throws {
        let sku = "RE-V5RC-25-9999"
        let event = try await client.loadEvent(sku: sku)
        guard event.name == "Native integration fixture" else { throw APIError.badResponse("Verification requires the prepared test event.") }
        let reviewID = try await client.queue(QueueRequest(sku: sku, keys: ["1:1"], mode: "dynamic")).added.first!
        let review = try await wait(client, id: reviewID, for: ["needs_review", "failed"])
        guard review.status == "needs_review", review.analysis?.sourceDuration != nil else {
            throw APIError.badResponse("Detect fixture failed: \(review.detail ?? "")")
        }
        print("VERIFY detect without clock -> Needs Review: PASS")
        let playable = try await AVURLAsset(url: client.videoURL(clipID: reviewID, review: true)).load(.isPlayable)
        guard playable else { throw APIError.badResponse("Review window is not playable.") }
        try await client.setBounds(clipID: reviewID, start: "1", end: "4")
        let saved = try await wait(client, id: reviewID, for: ["ready", "failed"])
        guard saved.status == "ready" else { throw APIError.badResponse(saved.detail ?? "Trim failed") }
        let asset = AVURLAsset(url: client.videoURL(clipID: saved.id))
        let duration = try await asset.load(.duration).seconds
        guard try await asset.load(.isPlayable), abs(duration - 3) < 0.5 else { throw APIError.badResponse("Saved clip playback check failed.") }
        try await client.setNotes(clipID: saved.id, notes: "Native integration notes")
        guard try await client.library().clips.first(where: { $0.id == saved.id })?.notes == "Native integration notes" else { throw APIError.badResponse("Notes did not save.") }
        print("VERIFY reviewed bounds, saved AVFoundation playback and notes: PASS")
        let failedID = try await client.addClip(NewClip(title: "Native failing source", url: "http://127.0.0.1:8799/missing.mp4", start: "0", end: "3"))
        let failed = try await wait(client, id: failedID, for: ["failed"])
        guard !Labels.failure(failed.detail).isEmpty else { throw APIError.badResponse("Missing real error") }
        print("VERIFY failing source error: \(Labels.failure(failed.detail))")
        try await client.retry(clipID: failedID)
        try await client.cancel(clipID: failedID)
        _ = try await wait(client, id: failedID, for: ["cancelled"])
        print("VERIFY Retry then Stop: PASS")
        // Give the worker a chance to acknowledge cancellation before deleting.
        try await Task.sleep(for: .seconds(1))
        try await client.delete(clipID: failedID)
        print("VERIFY Delete: PASS")
    }

    static func recordings(_ client: APIClient) async throws {
        let sku = "RE-V5RC-25-9999"
        let url = "http://127.0.0.1:8799/video/" + String(repeating: "0", count: 32)
        var draft = StreamDraft(label: "Native recording", url: url, date: "2026-11-18", syncMode: "anchor", anchorKey: "1:3", anchorPosition: 2, duration: 8)
        var event = try await client.saveStream(sku: sku, stream: draft)
        guard let recording = event.recordings.first(where: { $0.label == draft.label }), event.matchesByKey["1:3"]?.timestamp == 2 else { throw APIError.badResponse("Anchor mapping failed") }
        draft.id = recording.id; draft.label = "Edited recording"; draft.offset = 1
        event = try await client.saveStream(sku: sku, stream: draft)
        guard event.matchesByKey["1:3"]?.timestamp == 3 else { throw APIError.badResponse("Edited shift did not persist") }
        let second = StreamDraft(label: "Alternate", url: url, date: "2026-11-18", syncMode: "anchor", anchorKey: "1:3", anchorPosition: 4, duration: 8)
        event = try await client.saveStream(sku: sku, stream: second)
        let secondID = try event.recordings.first(where: { $0.label == "Alternate" }).unwrap("Second recording missing").id
        event = try await client.chooseStream(sku: sku, key: "1:3", id: secondID)
        guard event.matchesByKey["1:3"]?.timestamp == 4 else { throw APIError.badResponse("Recording choice failed") }
        event = try await client.calibrate(sku: sku, key: "1:4", url: url, timestamp: "5")
        guard event.matchesByKey["1:4"]?.timestamp == 5 else { throw APIError.badResponse("Calibration failed") }
        event = try await client.deleteStream(sku: sku, id: secondID)
        event = try await client.deleteStream(sku: sku, id: recording.id)
        guard event.recordings.isEmpty else { throw APIError.badResponse("Remove failed") }
        print("VERIFY recording Add/Edit/Choose/Remove and Set Video Position: PASS")
        do {
            _ = try await client.addClip(NewClip(title: "Invalid", url: "file:///private/test", start: "3", end: "1"))
            throw APIError.badResponse("Invalid clip accepted")
        } catch APIError.server(_, status: 400) { print("VERIFY Clip from Link validation: PASS") }
        do {
            _ = try await client.loadEvent(sku: "not-an-event")
            throw APIError.badResponse("Invalid event accepted")
        } catch APIError.server(let message, status: 400) {
            guard message.contains("event code") else { throw APIError.badResponse(message) }
            print("VERIFY Add Events bad-code feedback: PASS")
        }
        let imports = try JSONDecoder().decode([NewClip].self, from: Data("[{\"title\":\"Imported clip\",\"url\":\"\(url)\",\"start\":1,\"end\":4}]".utf8))
        let id = try await client.addClip(imports[0])
        let clip = try await wait(client, id: id, for: ["ready", "failed"])
        guard clip.status == "ready" else { throw APIError.badResponse(clip.detail ?? "Imported clip failed") }
        print("VERIFY numeric JSON import through native client: PASS")
    }
    static func schedule(_ client: APIClient) async throws {
        let event = try await client.loadEvent(sku: "RE-V5RC-25-9904")
        for (query, expected) in [("Q67", 2), ("QF1-1", 2), ("Q60–Q70", 10)] {
            let matches = event.matches.filter { MatchQuery.matches($0, query: query) }
            guard matches.count == expected else { throw APIError.badResponse("Query parity failed: \(query), \(matches.count)") }
        }
        let result = try await client.queue(QueueRequest(sku: "RE-V5RC-25-9999", keys: ["1:2"], mode: "fixed", duration: 3, before: 0))
        let id = try result.added.first.unwrap("No fixed download queued")
        let clip = try await wait(client, id: id, for: ["ready", "failed"])
        guard clip.status == "ready" else { throw APIError.badResponse(clip.detail ?? "Download failed") }
        let asset = AVURLAsset(url: client.videoURL(clipID: id))
        guard try await asset.load(.isPlayable), abs(try await asset.load(.duration).seconds - 3) < 0.5 else { throw APIError.badResponse("Fixed MP4 playback failed") }
        print("VERIFY fixed-length download and playback: PASS")
        let probe = try await client.probeStream(url: "http://127.0.0.1:8799/video/" + String(repeating: "0", count: 32))
        guard probe.metadata.title != nil else { throw APIError.badResponse("Probe missing title") }
        print("VERIFY real stream probe: PASS")
        let match = try event.matches.first { $0.label == "Q67" && $0.available }.unwrap("No Q67 fixture")
        let item = PreviewItem(title: "Q67", url: match.url!, target: match.timestamp!, port: client.baseURL.port!)
        let bridge = PreviewBridge()
        let coordinator = EmbeddedPreview.Coordinator(bridge: bridge, port: item.port, external: item.recordingURL)
        let config = WKWebViewConfiguration()
        config.userContentController.add(coordinator, name: "preview")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 960, height: 540), configuration: config)
        view.navigationDelegate = coordinator; bridge.webView = view
        defer { view.stopLoading(); config.userContentController.removeScriptMessageHandler(forName: "preview"); bridge.webView = nil }
        view.load(URLRequest(url: item.pageURL))
        for _ in 0..<120 {
            if bridge.ready, let position = bridge.position, abs(position - item.target) < 3 {
                print("VERIFY YouTube Q67 bridge ready at \(position): PASS"); return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw APIError.badResponse("YouTube preview verification failed: initialized=\(bridge.initialized), ready=\(bridge.ready), position=\(String(describing: bridge.position)); \(bridge.message)")
    }

}

private extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let value = self else { throw APIError.badResponse(message) }; return value
    }
}
