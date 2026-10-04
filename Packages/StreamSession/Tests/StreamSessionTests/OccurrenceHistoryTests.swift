import XCTest
@testable import StreamSession

final class OccurrenceHistoryTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func input(_ title: String, at seconds: Double, kind: String = "trackplay",
                       providerID: String? = nil, album: String? = nil, artwork: String? = nil) -> OccurrenceInput {
        OccurrenceInput(station: "kcrw", providerID: providerID, kind: kind,
                        title: title, artist: kind == "trackplay" ? "Artist" : nil,
                        album: album, artworkURL: artwork,
                        playedAt: origin.addingTimeInterval(seconds))
    }

    private func receive(_ entries: [OccurrenceInput], request: Int, at elapsed: Double,
                         history: inout OccurrenceHistory) throws -> HistoryUpdate {
        try history.receive(requestID: request, requestedElapsedSeconds: elapsed - 0.1,
                            receivedElapsedSeconds: elapsed, entries: entries)
    }

    func testRepeatedPollPreservesIdentityAndResourceRevisionDoesNotRestartTiming() throws {
        var history = OccurrenceHistory(policy: .init(maxOccurrences: 10, maxHistoryAge: 3600,
                                                       correctionWindow: 120))
        let first = try receive([input("A", at: 10, album: "Old")], request: 1, at: 20, history: &history)
        let original = try XCTUnwrap(history.occurrences.first)
        XCTAssertEqual(first, .accepted(inserted: 1, revised: 0))

        let second = try receive([input("A", at: 10, album: "New", artwork: "https://example.invalid/a.jpg")],
                                 request: 2, at: 30, history: &history)
        let revised = try XCTUnwrap(history.occurrences.first)
        XCTAssertEqual(second, .accepted(inserted: 0, revised: 1))
        XCTAssertEqual(revised.id, original.id)
        XCTAssertEqual(revised.playedAt, original.playedAt)
        XCTAssertEqual(revised.revision, 1)
        XCTAssertEqual(revised.album, "New")
    }

    func testRepeatAtAnotherTimestampIsDistinctAndBreakSurvives() throws {
        var history = OccurrenceHistory()
        _ = try receive([
            input("A", at: 0),
            input("Break", at: 300, kind: "break"),
            input("A", at: 900),
        ], request: 1, at: 1, history: &history)

        XCTAssertEqual(history.occurrences.count, 3)
        XCTAssertEqual(Set(history.occurrences.map(\.id)).count, 3)
        XCTAssertTrue(history.occurrences.contains { $0.kind == "break" })
    }

    func testUnambiguousTimestampCorrectionPreservesIdentity() throws {
        var history = OccurrenceHistory(policy: .init(maxOccurrences: 10, maxHistoryAge: 3600,
                                                       correctionWindow: 60))
        _ = try receive([input("A", at: 100)], request: 1, at: 1, history: &history)
        let originalID = try XCTUnwrap(history.occurrences.first?.id)

        let update = try receive([input("A", at: 105)], request: 2, at: 2, history: &history)
        XCTAssertEqual(update, .accepted(inserted: 0, revised: 1))
        XCTAssertEqual(history.occurrences.first?.id, originalID)
        XCTAssertEqual(history.occurrences.first?.playedAt, origin.addingTimeInterval(105))
    }

    func testAmbiguousTimestampCorrectionRejectsBatchWithoutMutation() throws {
        var history = OccurrenceHistory(policy: .init(maxOccurrences: 10, maxHistoryAge: 3600,
                                                       correctionWindow: 120))
        _ = try receive([input("A", at: 100), input("A", at: 250)], request: 1, at: 1, history: &history)
        let before = history.occurrences

        let update = try receive([input("A", at: 175)], request: 2, at: 2, history: &history)
        guard case .ambiguousCorrection = update else { return XCTFail("Expected ambiguous correction, got \(update)") }
        XCTAssertEqual(history.occurrences, before)
        XCTAssertTrue(history.hasAmbiguousCorrection)
    }

    func testFailureEmptyAndOutOfOrderResponsesRemainDistinct() throws {
        var history = OccurrenceHistory()
        _ = try receive([input("A", at: 0)], request: 1, at: 10, history: &history)

        let failed = try history.fail(requestID: 2, requestedElapsedSeconds: 19,
                                      receivedElapsedSeconds: 20, reason: "timeout")
        XCTAssertEqual(failed, .failed("timeout"))
        XCTAssertEqual(history.occurrences.count, 1, "Failure retains the last good history")
        XCTAssertEqual(history.feedState, .failed(receivedElapsedSeconds: 20, reason: "timeout"))

        let empty = try receive([], request: 3, at: 30, history: &history)
        XCTAssertEqual(empty, .empty)
        XCTAssertEqual(history.occurrences.count, 1, "A successful empty response is evidence, not a destructive clear")
        XCTAssertEqual(history.feedState, .empty(receivedElapsedSeconds: 30))

        let ignored = try history.receive(requestID: 2, requestedElapsedSeconds: 19,
                                          receivedElapsedSeconds: 31, entries: [input("Old", at: -100)])
        XCTAssertEqual(ignored, .ignoredOutOfOrder)
        XCTAssertFalse(history.occurrences.contains { $0.title == "Old" })
    }

    func testHistoryEvictsByAgeThenCount() throws {
        var history = OccurrenceHistory(policy: .init(maxOccurrences: 2, maxHistoryAge: 100,
                                                       correctionWindow: 10))
        _ = try receive([input("A", at: 0), input("B", at: 150), input("C", at: 200)],
                        request: 1, at: 1, history: &history)
        XCTAssertEqual(history.occurrences.map(\.title), ["B", "C"])
    }

    func testInvalidPolicyAndRequestTimingFailExplicitly() {
        var invalidPolicy = OccurrenceHistory(policy: .init(maxOccurrences: 0, maxHistoryAge: 100,
                                                             correctionWindow: 10))
        XCTAssertThrowsError(try invalidPolicy.receive(requestID: 1, requestedElapsedSeconds: 0,
                                                       receivedElapsedSeconds: 1,
                                                       entries: [input("A", at: 0)])) {
            XCTAssertEqual($0 as? StreamSessionError, .invalid("history policy"))
        }

        var history = OccurrenceHistory()
        XCTAssertThrowsError(try history.receive(requestID: 1, requestedElapsedSeconds: 2,
                                                 receivedElapsedSeconds: 1,
                                                 entries: [input("A", at: 0)])) {
            XCTAssertEqual($0 as? StreamSessionError, .invalid("request timing"))
        }
    }
}
