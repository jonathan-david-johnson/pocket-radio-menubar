import XCTest
import StreamDiagnostics
import StreamSession
@testable import StreamLab

final class SelectionReplayTests: XCTestCase {
    private let sessionID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
    private let traceOrigin = Date(timeIntervalSince1970: 1_800_001_000)
    private let providerOrigin = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ sequence: Int, _ elapsed: Double, _ payload: TracePayload) -> TraceEvent {
        TraceEvent(sessionID: sessionID, sequence: sequence, elapsedSeconds: elapsed,
                   wallTime: traceOrigin.addingTimeInterval(elapsed), payload: payload)
    }

    private func entries(_ rows: [(String, Double)]) throws -> [FeedEntry] {
        let body = rows.map { title, offset in
            "{\"title\":\"\(title)\",\"artist\":\"Artist\",\"datetime\":\"\(iso(providerOrigin.addingTimeInterval(offset)))\"}"
        }.joined(separator: ",")
        return try StationFeed.decode(Data("[\(body)]".utf8), station: .kcrw)
    }

    private func feed(_ sequence: Int, _ elapsed: Double, _ rows: [(String, Double)]) throws -> TraceEvent {
        event(sequence, elapsed,
              .feed(FeedObservation(requestID: sequence, requestedElapsedSeconds: elapsed - 0.1,
                                    statusCode: 200, headers: [:], bodyBytes: 100,
                                    entries: try entries(rows), failure: nil)))
    }

    private func playback(_ sequence: Int, _ elapsed: Double, media: Double,
                          program: Double, advancing: Bool = true) -> TraceEvent {
        event(sequence, elapsed,
              .playback(PlaybackObservation(mediaSeconds: media,
                                             programDate: providerOrigin.addingTimeInterval(program),
                                             rate: advancing ? 1 : 0,
                                             timeControlStatus: advancing ? "playing" : "paused",
                                             itemStatus: "ready", waitingReason: nil,
                                             loadedRanges: [], seekableRanges: [],
                                             bufferEmpty: false, likelyToKeepUp: true)))
    }

    private func completeTrace() throws -> [TraceEvent] {
        [
            event(0, 0, .started(SessionInfo(station: "kcrw", streamURL: "https://example.invalid/hls",
                                             feedURL: "https://example.invalid/feed", muted: false))),
            try feed(1, 1, [("A", 0), ("B", 200)]),
            playback(2, 10, media: 10, program: 359.5),
            playback(3, 11, media: 10.5, program: 360),
            event(4, 11.2, .marker("heard_song_change")),
            event(5, 12, .ended("user")),
        ]
    }

    private func annotations() -> SelectionAnnotations {
        SelectionAnnotations(schemaVersion: 1, sessionID: sessionID,
                             traceFilename: "synthetic.jsonl", traceSHA256: "synthetic",
                             markers: [
                                SelectionMarkerAnnotation(id: "b-start", classification: .songStart,
                                                          traceSequence: 4, markerElapsedSeconds: 11.2,
                                                          expected: ExpectedOccurrence(title: "B", artist: "Artist",
                                                                                       kind: "trackplay",
                                                                                       playedAtMilliseconds: milliseconds(providerOrigin.addingTimeInterval(200))),
                                                          identityProvenance: "synthetic", includeInMetrics: true,
                                                          note: nil),
                             ], pauses: [])
    }

    func testReplayIsCausalAndTransitionsAtTheOffsetBoundary() throws {
        let analysis = try SelectionReplay.analyze(events: completeTrace(), annotations: annotations(),
                                                   offsetSeconds: 160)
        XCTAssertEqual(analysis.transitions.map { $0.occurrence.title }, ["A", "B"])
        XCTAssertEqual(try XCTUnwrap(analysis.transitions.last?.elapsedSeconds), 11, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(analysis.markerResults.first?.signedErrorSeconds), -0.2, accuracy: 0.000_001)
        XCTAssertEqual(analysis.metrics?.count, 1)
        XCTAssertEqual(try XCTUnwrap(analysis.metrics?.worstAbsoluteErrorSeconds), 0.2, accuracy: 0.000_001)
    }

    func testFutureFeedObservationDoesNotLeakBackward() throws {
        let trace = [
            event(0, 0, .started(SessionInfo(station: "kcrw", streamURL: "https://example.invalid/hls",
                                             feedURL: "https://example.invalid/feed", muted: false))),
            try feed(1, 1, [("A", 0)]),
            playback(2, 10, media: 10, program: 400),
            try feed(3, 20, [("B", 200), ("A", 0)]),
            event(4, 21, .ended("user")),
        ]
        let empty = SelectionAnnotations(schemaVersion: 1, sessionID: sessionID,
                                         traceFilename: "synthetic.jsonl", traceSHA256: "synthetic",
                                         markers: [], pauses: [])
        let analysis = try SelectionReplay.analyze(events: trace, annotations: empty, offsetSeconds: 160)
        XCTAssertEqual(analysis.transitions.map { ($0.elapsedSeconds, $0.occurrence.title ?? "") }.map { "\($0.0):\($0.1)" },
                       ["10.0:A", "20.0:B"])
    }

    func testReplayAndReportAreDeterministic() throws {
        let first = try SelectionReplay.render(events: completeTrace(), annotations: annotations(), offsetSeconds: 160)
        let second = try SelectionReplay.render(events: completeTrace(), annotations: annotations(), offsetSeconds: 160)
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.contains("offset: +160.000s"), first)
        XCTAssertTrue(first.contains("median absolute error: 0.200s"), first)
        XCTAssertTrue(first.contains("development evidence"), first)
    }

    func testAnnotationMustMatchSessionAndMarkerEvent() throws {
        let wrongSession = SelectionAnnotations(schemaVersion: 1, sessionID: UUID(),
                                                traceFilename: "synthetic.jsonl", traceSHA256: "synthetic",
                                                markers: [], pauses: [])
        XCTAssertThrowsError(try SelectionReplay.analyze(events: completeTrace(), annotations: wrongSession,
                                                         offsetSeconds: 160))

        var annotation = annotations().markers[0]
        annotation = SelectionMarkerAnnotation(id: annotation.id, classification: annotation.classification,
                                               traceSequence: 3, markerElapsedSeconds: annotation.markerElapsedSeconds,
                                               expected: annotation.expected,
                                               identityProvenance: annotation.identityProvenance,
                                               includeInMetrics: annotation.includeInMetrics, note: annotation.note)
        let wrongMarker = SelectionAnnotations(schemaVersion: 1, sessionID: sessionID,
                                               traceFilename: "synthetic.jsonl", traceSHA256: "synthetic",
                                               markers: [annotation], pauses: [])
        XCTAssertThrowsError(try SelectionReplay.analyze(events: completeTrace(), annotations: wrongMarker,
                                                         offsetSeconds: 160))
    }

    func testCommercialBeforeThresholdIsNotReportedAsSongStart() throws {
        let trace = [
            event(0, 0, .started(SessionInfo(station: "kcrw", streamURL: "https://example.invalid/hls",
                                             feedURL: "https://example.invalid/feed", muted: false))),
            try feed(1, 1, [("A", 0), ("B", 200)]),
            playback(2, 10, media: 10, program: 350),
            event(3, 10.2, .marker("heard_song_change")),
            playback(4, 20, media: 20, program: 360),
            event(5, 20.2, .marker("heard_song_change")),
            event(6, 21, .ended("user")),
        ]
        let expected = ExpectedOccurrence(title: "B", artist: "Artist", kind: "trackplay",
                                          playedAtMilliseconds: milliseconds(providerOrigin.addingTimeInterval(200)))
        let sidecar = SelectionAnnotations(schemaVersion: 1, sessionID: sessionID,
                                           traceFilename: "synthetic.jsonl", traceSHA256: "synthetic",
                                           markers: [
                                            SelectionMarkerAnnotation(id: "commercial", classification: .commercial,
                                                                      traceSequence: 3, markerElapsedSeconds: 10.2,
                                                                      expected: expected, identityProvenance: "listener",
                                                                      includeInMetrics: false, note: nil),
                                            SelectionMarkerAnnotation(id: "song", classification: .songStart,
                                                                      traceSequence: 5, markerElapsedSeconds: 20.2,
                                                                      expected: expected, identityProvenance: "listener",
                                                                      includeInMetrics: true, note: nil),
                                           ], pauses: [])
        let analysis = try SelectionReplay.analyze(events: trace, annotations: sidecar, offsetSeconds: 160)
        XCTAssertEqual(analysis.transitions.last?.occurrence.title, "B")
        XCTAssertEqual(try XCTUnwrap(analysis.transitions.last?.elapsedSeconds), 20, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(analysis.markerResults[0].signedErrorSeconds), 9.8, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(analysis.markerResults[1].signedErrorSeconds), -0.2, accuracy: 0.000_001)
        XCTAssertEqual(analysis.metrics?.count, 1)
    }

    func testNonfiniteOffsetFailsExplicitly() throws {
        XCTAssertThrowsError(try SelectionReplay.analyze(events: completeTrace(), annotations: annotations(),
                                                         offsetSeconds: .infinity)) {
            XCTAssertEqual($0 as? SelectionReplayError, .invalid("offset must be finite"))
        }
    }

    func testComparisonCombinesSessionsSensitivityAndLeaveOneOutDeterministically() throws {
        let input = SelectionReplayInput(events: try completeTrace(), annotations: annotations())
        let first = try SelectionComparison.render(inputs: [input, input], primaryOffset: 160,
                                                    sensitivityOffsets: [159, 160, 161])
        let second = try SelectionComparison.render(inputs: [input, input], primaryOffset: 160,
                                                     sensitivityOffsets: [159, 160, 161])
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.contains("included markers measured: 2/2"), first)
        XCTAssertTrue(first.contains("sensitivity"), first)
        XCTAssertTrue(first.contains("leave-one-session-out"), first)
        XCTAssertTrue(first.contains("fitted=+160.000s"), first)
    }

    func testMissedAndCommercialAnnotationsRemainVisibleButExcluded() throws {
        let expected = ExpectedOccurrence(title: "B", artist: "Artist", kind: "trackplay",
                                          playedAtMilliseconds: milliseconds(providerOrigin.addingTimeInterval(200)))
        let excluded = SelectionAnnotations(schemaVersion: 1, sessionID: sessionID,
                                            traceFilename: "synthetic.jsonl", traceSHA256: "synthetic",
                                            markers: [
                                                SelectionMarkerAnnotation(id: "commercial", classification: .commercial,
                                                                          traceSequence: 4, markerElapsedSeconds: 11.2,
                                                                          expected: expected, identityProvenance: "listener",
                                                                          includeInMetrics: false, note: "speech"),
                                                SelectionMarkerAnnotation(id: "missed", classification: .missedSongStart,
                                                                          traceSequence: nil, markerElapsedSeconds: nil,
                                                                          expected: expected, identityProvenance: "feed order",
                                                                          includeInMetrics: false, note: "no keypress"),
                                            ], pauses: [])
        let analysis = try SelectionReplay.analyze(events: completeTrace(), annotations: excluded,
                                                   offsetSeconds: 160)
        XCTAssertNil(analysis.metrics)
        XCTAssertEqual(analysis.markerResults.map(\.classification), [.commercial, .missedSongStart])
        XCTAssertTrue(analysis.markerResults.allSatisfy { !$0.includedInMetrics })
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}
