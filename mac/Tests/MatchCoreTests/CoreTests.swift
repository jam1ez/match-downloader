import Foundation
import Testing
@testable import MatchCore

func fixture<T: Decodable>(_ name: String, as: T.Type = T.self) throws -> T {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
}

@Test func fixtureDecoding() throws {
    let health: Health = try fixture("health")
    #expect(health.app == "Match Downloader" && health.api == 1)
    let library: LibraryState = try fixture("library")
    #expect(library.clips.count == 1)
    #expect(library.clips[0].analysis != nil)
    let catalogue: Catalogue = try fixture("catalogue")
    #expect(catalogue.events.count == 24)
    let event: EventDetail = try fixture("event-with-recording")
    #expect(event.matches.count == 69)
    #expect(event.recordings.count == 1)
    let schedule: EventDetail = try fixture("event-schedule")
    #expect(schedule.matches.count == 53)
}

@Test func queriesMatchWebBehavior() throws {
    let event: EventDetail = try fixture("event-schedule")
    func selected(_ q: String) -> [Match] { event.matches.filter { MatchQuery.matches($0, query: q) } }
    #expect(selected("Q67").count == 2)
    #expect(selected("q67").allSatisfy { $0.label == "Q67" })
    #expect(selected("QF1-1").count == 2)
    #expect(selected("R16 1-1").count == 2)
    #expect(selected("Q60–Q70").count == 10)
    #expect(selected("Q60-Q70").count == 10)
    #expect(selected("Q67, QF1-1; R16 1-1").count == 6)
    #expect(selected("qualification 67").count == 2)
    #expect(selected("Q70-Q60").isEmpty)
    #expect(selected(" ").count == event.matches.count)
    let first = try #require(event.matches.first { !$0.teams.isEmpty })
    #expect(MatchQuery.matches(first, query: first.teams[0].lowercased()))
    #expect(!MatchQuery.matches(first, query: "unfindable team"))
}

@Test func formattingAndEmptyLast() {
    #expect(Format.clock(3723.9) == "01:02:03")
    #expect(Format.clock(-2) == "00:00:00")
    #expect(Format.parseClock("1:02:03") == 3723)
    #expect(Format.parseClock("nan") == nil)
    #expect(Format.parseClock("-1") == nil)
    #expect(Format.size(1_048_576) == "1.0 MB")
    #expect(Labels.show("R161-1") == "R16 1-1")
    #expect(Labels.failure("warning\nERROR: [generic] actual error\ntrailing line") == "actual error")
    for order in [SortOrder.forward, .reverse] {
        #expect(EmptyLast.compare(nil as Int?, 2, order: order) == .orderedDescending)
        #expect(EmptyLast.compare(2, nil as Int?, order: order) == .orderedAscending)
    }
    #expect(EmptyLast.compare(1, 2, order: .reverse) == .orderedDescending)
}

@Test func importNumericTimesAndStreamEncoding() throws {
    let clip = try JSONDecoder().decode(NewClip.self, from: Data(#"{"title":"Q1","url":"https://example.com/a.mp4","start":1,"end":4}"#.utf8))
    #expect(clip.start == "1" && clip.end == "4" && clip.notes.isEmpty)
    let draft = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(StreamDraft()))
    #expect(draft["id"] == nil && draft["duration"] == nil)
}

@Test func optionalComparatorInsideKeyPathComparator() {
    struct Row { var score: Int? }
    for order in [SortOrder.forward, .reverse] {
        let sorted = [Row(score: nil), Row(score: 2), Row(score: 1)].sorted(using: KeyPathComparator(\Row.score, comparator: OptionalLastComparator<Int>(), order: order))
        #expect(sorted.last?.score == nil)
        #expect(sorted.first?.score == (order == .forward ? 1 : 2))
    }
}

@Test func realProbeFixture() throws {
    let probe: StreamProbe = try fixture("probe")
    #expect(probe.metadata.title == String(repeating: "0", count: 32))
    #expect(probe.metadata.duration == nil)
    #expect(probe.metadata.recordings.isEmpty)
}
