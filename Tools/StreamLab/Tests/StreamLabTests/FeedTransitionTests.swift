import XCTest
import StreamDiagnostics
@testable import StreamLab

/// Publish-lag bounding. A station feed is polled at an interval, so the moment an entry
/// appeared is only known to within one interval. The report must state a bracket, never
/// a point estimate, and must never call either edge an audible boundary.
final class FeedTransitionTests: XCTestCase {
    private let sessionID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    private let origin = Date(timeIntervalSince1970: 1_758_000_000)

    private func iso(_ offset: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: origin.addingTimeInterval(offset))
    }

    /// Builds a KCRW-shaped row so entries come from the real parser rather than a stub.
    private func entries(title: String, airtimeOffset: Double) throws -> [FeedEntry] {
        let json = Data("""
        [{"id": 1, "title": "\(title)", "artist": "Synthetic Artist", "datetime": "\(iso(airtimeOffset))"}]
        """.utf8)
        return try StationFeed.decode(json, station: .kcrw)
    }

    private func feed(_ sequence: Int, elapsed: Double, title: String, airtimeOffset: Double) throws -> TraceEvent {
        TraceEvent(sessionID: sessionID, sequence: sequence, elapsedSeconds: elapsed,
                   wallTime: origin.addingTimeInterval(elapsed),
                   payload: .feed(FeedObservation(requestID: sequence, requestedElapsedSeconds: elapsed,
                                                  statusCode: 200, headers: [:], bodyBytes: 128,
                                                  entries: try entries(title: title, airtimeOffset: airtimeOffset),
                                                  failure: nil)))
    }

    private func event(_ sequence: Int, _ elapsed: Double, _ payload: TracePayload) -> TraceEvent {
        TraceEvent(sessionID: sessionID, sequence: sequence, elapsedSeconds: elapsed,
                   wallTime: origin.addingTimeInterval(elapsed), payload: payload)
    }

    private func traceWithOneTransition() throws -> [TraceEvent] {
        [
            event(0, 0, .started(SessionInfo(station: "kcrw", streamURL: "https://example.invalid/s",
                                             feedURL: "https://example.invalid/feed", muted: true))),
            // Track A aired 50s before the capture began: a baseline, not a transition.
            try feed(1, elapsed: 10, title: "Track A", airtimeOffset: -50),
            try feed(2, elapsed: 20, title: "Track A", airtimeOffset: -50),
            // Track B's stated airtime is 5s after the capture began. The poll at 20s did
            // not carry it and the poll at 30s did, so publication falls in (+15s, +25s).
            try feed(3, elapsed: 30, title: "Track B", airtimeOffset: 5),
            event(4, 40, .ended("duration")),
        ]
    }

    func testReportBracketsPublishLagBetweenTheTwoAdjacentPolls() throws {
        let report = try ReplayReport.render(try traceWithOneTransition())
        XCTAssertTrue(report.contains("Track B"), report)
        XCTAssertTrue(report.contains("15.000"), "Lower bound (last poll without the entry): \(report)")
        XCTAssertTrue(report.contains("25.000"), "Upper bound (first poll with the entry): \(report)")
        XCTAssertTrue(report.lowercased().contains("publish"),
                      "The bracket must be labelled as publish lag: \(report)")
    }

    func testFirstPolledEntryIsABaselineNotATransition() throws {
        let report = try ReplayReport.render(try traceWithOneTransition())
        XCTAssertTrue(report.contains("feed transitions (1"),
                      "Track A was already playing at capture start and must not be counted: \(report)")
    }

    func testLagIsMeasuredAgainstTheEntrysOwnClaimedAirtimeNotAudibility() throws {
        let report = try ReplayReport.render(try traceWithOneTransition())
        XCTAssertTrue(report.lowercased().contains("claimed airtime") || report.lowercased().contains("stated airtime"),
                      "The baseline must be named as the entry's own claim: \(report)")
        XCTAssertFalse(report.lowercased().contains("song started"),
                       "A publish bracket is not a song-start claim: \(report)")
    }

    func testTraceWithoutFeedTransitionsReportsNone() throws {
        let steady = [
            event(0, 0, .started(SessionInfo(station: "kcrw", streamURL: "https://example.invalid/s",
                                             feedURL: "https://example.invalid/feed", muted: true))),
            try feed(1, elapsed: 10, title: "Track A", airtimeOffset: -50),
            try feed(2, elapsed: 20, title: "Track A", airtimeOffset: -50),
            event(3, 30, .ended("duration")),
        ]
        let report = try ReplayReport.render(steady)
        XCTAssertTrue(report.contains("feed transitions (0"), report)
    }

    /// KEXP airbreaks have a kind and provider timestamp, but no song title. They are
    /// real feed-top transitions; a repeat poll of the same break is not another one.
    func testUntitledKEXPAirbreakAppearsInTransitionSummary() throws {
        func kexpFeed(_ sequence: Int, elapsed: Double, row: String) throws -> TraceEvent {
            let json = Data("""
            {"results":[\(row)]}
            """.utf8)
            return event(sequence, elapsed,
                         .feed(FeedObservation(requestID: sequence, requestedElapsedSeconds: elapsed,
                                               statusCode: 200, headers: [:], bodyBytes: json.count,
                                               entries: try StationFeed.decode(json, station: .kexp), failure: nil)))
        }
        let old = """
        {"id":1,"play_type":"trackplay","song":"Old","artist":"A","airdate":"\(iso(-50))"}
        """
        let breakRow = """
        {"id":2,"play_type":"airbreak","airdate":"\(iso(15))"}
        """
        let next = """
        {"id":3,"play_type":"trackplay","song":"Next","artist":"B","airdate":"\(iso(45))"}
        """
        let trace = [
            event(0, 0, .started(SessionInfo(station: "kexp", streamURL: "https://example.invalid/s",
                                             feedURL: "https://example.invalid/feed", muted: false))),
            try kexpFeed(1, elapsed: 10, row: old),
            try kexpFeed(2, elapsed: 20, row: breakRow),
            try kexpFeed(3, elapsed: 30, row: breakRow),
            try kexpFeed(4, elapsed: 50, row: next),
            event(5, 60, .ended("duration")),
        ]
        let report = try ReplayReport.render(trace)
        let section = report.components(separatedBy: "feed transitions (").last?.components(separatedBy: "\ncounts").first ?? ""
        XCTAssertTrue(section.contains("2 observed"), section)
        XCTAssertEqual(section.components(separatedBy: "\"airbreak\"").count - 1, 1, section)
        XCTAssertTrue(section.contains("kind=airbreak"), section)
        XCTAssertTrue(section.contains("claimed airtime +5.000s"), section)
        XCTAssertTrue(section.contains("\"Next\""), section)
    }

    func testEntryWithoutAParsedAirtimeIsStillCountedButNotBracketed() throws {
        let undated = Data("""
        [{"id": 7, "title": "No Timestamp", "artist": "Synthetic Artist"}]
        """.utf8)
        let trace = [
            event(0, 0, .started(SessionInfo(station: "kcrw", streamURL: "https://example.invalid/s",
                                             feedURL: "https://example.invalid/feed", muted: true))),
            try feed(1, elapsed: 10, title: "Track A", airtimeOffset: -50),
            TraceEvent(sessionID: sessionID, sequence: 2, elapsedSeconds: 20,
                       wallTime: origin.addingTimeInterval(20),
                       payload: .feed(FeedObservation(requestID: 2, requestedElapsedSeconds: 20, statusCode: 200,
                                                      headers: [:], bodyBytes: 64,
                                                      entries: try StationFeed.decode(undated, station: .kcrw),
                                                      failure: nil))),
            event(3, 30, .ended("duration")),
        ]
        let report = try ReplayReport.render(trace)
        XCTAssertTrue(report.contains("feed transitions (1"), report)
        XCTAssertTrue(report.contains("No Timestamp"), report)
        XCTAssertTrue(report.lowercased().contains("no stated airtime"),
                      "An unbracketable transition must say why: \(report)")
    }
}

/// A polled feed can sit behind a cache. A response carrying `age: N` describes the origin
/// as it was N seconds ago, so treating it as a current observation invents a lower bound
/// that the evidence does not support. This is a regression test for exactly that error.
final class FeedCacheAgeTests: XCTestCase {
    private let sessionID = UUID(uuidString: "cccccccc-dddd-eeee-ffff-000000000000")!
    private let origin = Date(timeIntervalSince1970: 1_758_000_000)

    private func iso(_ offset: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: origin.addingTimeInterval(offset))
    }

    private func feed(_ sequence: Int, elapsed: Double, title: String, airtimeOffset: Double,
                     age: String?) throws -> TraceEvent {
        let json = Data("""
        [{"id": 1, "title": "\(title)", "artist": "A", "datetime": "\(iso(airtimeOffset))"}]
        """.utf8)
        return TraceEvent(sessionID: sessionID, sequence: sequence, elapsedSeconds: elapsed,
                          wallTime: origin.addingTimeInterval(elapsed),
                          payload: .feed(FeedObservation(requestID: sequence, requestedElapsedSeconds: elapsed,
                                                         statusCode: 200,
                                                         headers: age.map { ["age": $0] } ?? [:],
                                                         bodyBytes: 128,
                                                         entries: try StationFeed.decode(json, station: .kcrw),
                                                         failure: nil)))
    }

    private func event(_ sequence: Int, _ elapsed: Double, _ payload: TracePayload) -> TraceEvent {
        TraceEvent(sessionID: sessionID, sequence: sequence, elapsedSeconds: elapsed,
                   wallTime: origin.addingTimeInterval(elapsed), payload: payload)
    }

    /// Mirrors the observed KCRW shape: the poll before a transition was already 50s stale,
    /// so it cannot establish that the entry was unpublished at that wall time.
    func testAStaleEarlierResponseYieldsNoLowerBound() throws {
        let trace = [
            event(0, 0, .started(SessionInfo(station: "kcrw", streamURL: "https://example.invalid/s",
                                             feedURL: "https://example.invalid/feed", muted: true))),
            try feed(1, elapsed: 60, title: "Old", airtimeOffset: -200, age: "50"),
            try feed(2, elapsed: 70, title: "New", airtimeOffset: 55, age: nil),
            event(3, 80, .ended("duration")),
        ]
        let report = try ReplayReport.render(trace)
        XCTAssertTrue(report.lowercased().contains("stale"),
                      "A stale prior response must be called out: \(report)")
        XCTAssertTrue(report.contains("no lower bound"),
                      "The report must decline to give a lower bound: \(report)")
        XCTAssertFalse(report.contains("published between"),
                       "A two-sided bracket is not supported by stale evidence: \(report)")
    }

    func testAFreshEarlierResponseStillYieldsATwoSidedBracket() throws {
        let trace = [
            event(0, 0, .started(SessionInfo(station: "kcrw", streamURL: "https://example.invalid/s",
                                             feedURL: "https://example.invalid/feed", muted: true))),
            try feed(1, elapsed: 60, title: "Old", airtimeOffset: -200, age: "0"),
            try feed(2, elapsed: 70, title: "New", airtimeOffset: 55, age: "0"),
            event(3, 80, .ended("duration")),
        ]
        let report = try ReplayReport.render(trace)
        XCTAssertTrue(report.contains("published between"), report)
        XCTAssertTrue(report.contains("5.000"), "Lower bound from a fresh prior response: \(report)")
        XCTAssertTrue(report.contains("15.000"), "Upper bound: \(report)")
    }

    /// The upper bound must also be corrected: a cached response showing the entry proves
    /// only that the origin had it `age` seconds before the response was received.
    func testUpperBoundIsCorrectedForTheAgeOfTheRespondingCache() throws {
        let trace = [
            event(0, 0, .started(SessionInfo(station: "kcrw", streamURL: "https://example.invalid/s",
                                             feedURL: "https://example.invalid/feed", muted: true))),
            try feed(1, elapsed: 60, title: "Old", airtimeOffset: -200, age: "0"),
            try feed(2, elapsed: 90, title: "New", airtimeOffset: 55, age: "20"),
            event(3, 100, .ended("duration")),
        ]
        let report = try ReplayReport.render(trace)
        // Received at +35s after airtime, but 20s stale: origin had it by +15s.
        XCTAssertTrue(report.contains("15.000"), "Upper bound must subtract the age: \(report)")
        XCTAssertFalse(report.contains("35.000"), "The raw receipt time overstates the lag: \(report)")
    }

    func testCacheStalenessIsSummarisedForTheWholeCapture() throws {
        let trace = [
            event(0, 0, .started(SessionInfo(station: "kcrw", streamURL: "https://example.invalid/s",
                                             feedURL: "https://example.invalid/feed", muted: true))),
            try feed(1, elapsed: 10, title: "A", airtimeOffset: -100, age: "0"),
            try feed(2, elapsed: 20, title: "A", airtimeOffset: -100, age: "41"),
            event(3, 30, .ended("duration")),
        ]
        let report = try ReplayReport.render(trace)
        XCTAssertTrue(report.lowercased().contains("cache age"), report)
        XCTAssertTrue(report.contains("41"), "The observed maximum staleness matters: \(report)")
    }
}
