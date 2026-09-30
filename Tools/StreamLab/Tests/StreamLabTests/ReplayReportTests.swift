import XCTest
import StreamDiagnostics
@testable import StreamLab

/// Offline replay rendering. Every trace here is synthetic: no station is contacted,
/// no audio is played, and no account or credential is touched.
final class ReplayReportTests: XCTestCase {
    private let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let origin = Date(timeIntervalSince1970: 1_758_000_000)

    private func event(_ sequence: Int, _ elapsed: Double, _ payload: TracePayload) -> TraceEvent {
        TraceEvent(sessionID: sessionID, sequence: sequence, elapsedSeconds: elapsed,
                   wallTime: origin.addingTimeInterval(elapsed), payload: payload)
    }

    private func feedEntries() throws -> [FeedEntry] {
        let json = Data("""
        [{"id": 9001, "title": "Synthetic Song", "artist": "Synthetic Artist", "datetime": "2026-09-16T05:20:00Z"},
         {"id": 9000, "title": "[BREAK]", "artist": "[BREAK]", "datetime": "2026-09-16T05:16:00Z"}]
        """.utf8)
        return try StationFeed.decode(json, station: .kcrw)
    }

    private func playback(_ media: Double, state: String = "playing") -> TracePayload {
        .playback(PlaybackObservation(mediaSeconds: media, programDate: origin.addingTimeInterval(media), rate: 1,
                                      timeControlStatus: state, itemStatus: "ready", waitingReason: nil,
                                      loadedRanges: [MediaRange(start: 0, duration: media + 8)],
                                      seekableRanges: [], bufferEmpty: false, likelyToKeepUp: true))
    }

    private func completeTrace() throws -> [TraceEvent] {
        [
            event(0, 0, .started(SessionInfo(station: "kcrw", streamURL: "https://example.invalid/explicit-stream",
                                             feedURL: "https://example.invalid/feed", muted: false))),
            event(1, 0.25, .notice("metadata_attached")),
            event(2, 1.5, playback(1.2)),
            event(3, 12.75, .metadata(MetadataObservation(receivedElapsedSeconds: 12.75, receivedMediaSeconds: 12.4,
                                                          values: [MetadataValue(identifier: "id3/TIT2", key: "TIT2", keySpace: "org.id3",
                                                                                 value: "Synthetic Artist - Synthetic Song",
                                                                                 mediaStartSeconds: 12.4, mediaDurationSeconds: 3.5)]))),
            event(4, 30.0, .feed(FeedObservation(requestID: 1, requestedElapsedSeconds: 30.0, statusCode: 200,
                                                 headers: ["Content-Type": "application/json", "Server": "synthetic"],
                                                 bodyBytes: 256, entries: try feedEntries(), failure: nil))),
            event(5, 41.0, .marker("heard_song_change")),
            event(6, 55.0, playback(54.2, state: "paused")),
            event(7, 60.0, .feed(FeedObservation(requestID: 2, requestedElapsedSeconds: 60.0, statusCode: nil,
                                                 headers: [:], bodyBytes: 0, entries: [], failure: "timeout"))),
            event(8, 61.0, .ended("user")),
        ]
    }

    func testRenderIsDeterministicAcrossRepeatedRuns() throws {
        let events = try completeTrace()
        XCTAssertEqual(try ReplayReport.render(events), try ReplayReport.render(events),
                       "Replay output must not depend on dictionary order, locale, or the current time zone")
    }

    func testRenderShowsSessionElapsedTimelineAndEndReason() throws {
        let report = try ReplayReport.render(try completeTrace())
        XCTAssertTrue(report.contains("kcrw"))
        XCTAssertTrue(report.contains("https://example.invalid/explicit-stream"))
        XCTAssertTrue(report.contains("metadata_attached"))
        XCTAssertTrue(report.contains("heard_song_change"))
        XCTAssertTrue(report.contains("Synthetic Artist - Synthetic Song"))
        XCTAssertTrue(report.contains("61.000"), "The timeline should use elapsed seconds as the diagnostic axis")
        XCTAssertTrue(report.contains("user"), "The end reason must be reported")
    }

    func testRenderCountsEachObservationKindSeparately() throws {
        let report = try ReplayReport.render(try completeTrace())
        XCTAssertTrue(report.contains("playback observations: 2"), report)
        XCTAssertTrue(report.contains("player metadata: 1"), report)
        XCTAssertTrue(report.contains("feed responses: 2"), report)
        XCTAssertTrue(report.contains("feed failures: 1"), report)
        XCTAssertTrue(report.contains("heard_song_change: 1"), report)
    }

    func testRenderKeepsFeedAndPlayerMetadataAsSeparateCandidates() throws {
        let report = try ReplayReport.render(try completeTrace())
        XCTAssertTrue(report.contains("Synthetic Song"), "Feed-top should be shown as a candidate")
        XCTAssertTrue(report.lowercased().contains("candidate"),
                      "Feed-top must be labelled a candidate, never an audibility claim")
        XCTAssertFalse(report.lowercased().contains("now playing"),
                       "Replay must not present any observation as the audible track")
    }

    /// Observed on a live KCRW capture: the Mac suspended mid-session, `systemUptime`
    /// froze for ~68s, and the trace still looked like a clean shorter capture.
    /// A reader cannot trust an interval that silently spans a suspend.
    func testRenderFlagsWallVersusMonotonicSkewFromASystemSuspend() throws {
        let suspended = [
            event(0, 0, .started(SessionInfo(station: "kcrw", streamURL: "https://example.invalid/s",
                                             feedURL: nil, muted: true))),
            event(1, 10.0, playback(9.6)),
            // Monotonic time advances 0.5s while the wall clock advances 60.5s.
            TraceEvent(sessionID: sessionID, sequence: 2, elapsedSeconds: 10.5,
                       wallTime: origin.addingTimeInterval(70.5), payload: playback(10.1)),
            TraceEvent(sessionID: sessionID, sequence: 3, elapsedSeconds: 11.0,
                       wallTime: origin.addingTimeInterval(71.0), payload: .ended("duration")),
        ]
        let report = try ReplayReport.render(suspended)
        XCTAssertTrue(report.contains("clock"), report)
        XCTAssertTrue(report.contains("60.000"), "The skew size should be reported: \(report)")
        XCTAssertTrue(report.lowercased().contains("suspend"),
                      "The report should name a suspend as the reason monotonic time froze")
        XCTAssertTrue(report.contains("lower bound"),
                      "Intervals spanning a suspend must be described as lower bounds")
    }

    func testRenderReportsAgreementWhenNoSuspendOccurred() throws {
        let report = try ReplayReport.render(try completeTrace())
        XCTAssertTrue(report.contains("clock"), report)
        XCTAssertFalse(report.lowercased().contains("suspend"),
                       "A clean capture must not be labelled as suspended: \(report)")
    }

    func testRenderRejectsAnIncompleteTrace() throws {
        let truncated = Array(try completeTrace().dropLast())
        XCTAssertThrowsError(try ReplayReport.render(truncated)) {
            XCTAssertTrue("\($0)".lowercased().contains("incomplete"), "Expected an incomplete-capture failure, got \($0)")
        }
    }

    func testTraceFileRoundTripsThroughReplayWithoutNetworkAccess() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stream-lab-replay-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let events = try completeTrace()
        let writer = try TraceWriter(url: url)
        for event in events { try writer.append(event) }
        try writer.close()

        let readBack = try TraceReader.read(url: url)
        XCTAssertEqual(readBack, events, "A written trace must read back exactly")
        XCTAssertEqual(try ReplayReport.render(readBack), try ReplayReport.render(events),
                       "Replaying from disk must match replaying the in-memory sequence")
    }
}
