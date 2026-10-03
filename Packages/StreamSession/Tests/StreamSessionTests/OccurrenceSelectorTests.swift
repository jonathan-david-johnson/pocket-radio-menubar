import XCTest
@testable import StreamSession

final class OccurrenceSelectorTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func occurrence(_ title: String, at seconds: Double, kind: String = "trackplay") -> OccurrenceInput {
        OccurrenceInput(station: "kcrw", providerID: nil, kind: kind, title: title,
                        artist: kind == "trackplay" ? "Artist" : nil,
                        album: nil, artworkURL: nil, playedAt: origin.addingTimeInterval(seconds))
    }

    private func history(_ inputs: [OccurrenceInput], receivedAt: Double = 10) throws -> OccurrenceHistory {
        var result = OccurrenceHistory()
        _ = try result.receive(requestID: 1, requestedElapsedSeconds: receivedAt - 1,
                               receivedElapsedSeconds: receivedAt, entries: inputs)
        return result
    }

    func testEarlyEntryRemainsPendingUntilOffsetBoundary() throws {
        let history = try history([occurrence("A", at: 100)])
        let selector = OccurrenceSelector(policy: .init(feedToProgramOffset: 160,
                                                         maxSelectedAge: 1200,
                                                         maxFeedSilence: 120))

        XCTAssertEqual(selector.select(from: history, playerProgramDate: origin.addingTimeInterval(259.999),
                                       playerElapsedSeconds: 20),
                       .unavailable(.historyBeginsAfterPlayer))
        let atBoundary = selector.select(from: history, playerProgramDate: origin.addingTimeInterval(260),
                                         playerElapsedSeconds: 20)
        guard case .selected(let selection) = atBoundary else { return XCTFail("Expected boundary selection") }
        XCTAssertEqual(selection.occurrence.title, "A")
        XCTAssertEqual(selection.songSeconds, 0, accuracy: 0.000_001)
    }

    func testLatestEligibleOccurrenceWinsAndPositionUsesShiftedStart() throws {
        let history = try history([occurrence("A", at: 0), occurrence("B", at: 200)])
        let selector = OccurrenceSelector(policy: .init(feedToProgramOffset: 160,
                                                         maxSelectedAge: 1200,
                                                         maxFeedSilence: 120))
        let result = selector.select(from: history, playerProgramDate: origin.addingTimeInterval(390),
                                     playerElapsedSeconds: 20)
        guard case .selected(let selection) = result else { return XCTFail("Expected a selected occurrence") }
        XCTAssertEqual(selection.occurrence.title, "B")
        XCTAssertEqual(selection.songSeconds, 30, accuracy: 0.000_001,
                       "playedAt + 190s means 30 song seconds after the +160s mapping")
    }

    func testInitialJoinMidSongSelectsCoveredOccurrence() throws {
        let history = try history([occurrence("Older", at: 0), occurrence("Current", at: 180), occurrence("Future", at: 400)])
        let result = OccurrenceSelector().select(from: history,
                                                  playerProgramDate: origin.addingTimeInterval(400),
                                                  playerElapsedSeconds: 20)
        guard case .selected(let selection) = result else { return XCTFail("Expected mid-song selection") }
        XCTAssertEqual(selection.occurrence.title, "Current")
        XCTAssertEqual(selection.songSeconds, 60, accuracy: 0.000_001)
    }

    func testBreakIsSelectableButMissingDateAndUncoveredHistoryAreUnavailable() throws {
        let covered = try history([occurrence("A", at: 0), occurrence("Break", at: 200, kind: "break")])
        let breakResult = OccurrenceSelector().select(from: covered,
                                                       playerProgramDate: origin.addingTimeInterval(365),
                                                       playerElapsedSeconds: 20)
        guard case .selected(let selection) = breakResult else { return XCTFail("Expected explicit break selection") }
        XCTAssertEqual(selection.occurrence.kind, "break")

        XCTAssertEqual(OccurrenceSelector().select(from: covered, playerProgramDate: nil,
                                                    playerElapsedSeconds: 20),
                       .unavailable(.missingPlayerProgramDate))
        XCTAssertEqual(OccurrenceSelector().select(from: OccurrenceHistory(),
                                                    playerProgramDate: origin, playerElapsedSeconds: 20),
                       .unavailable(.noHistory))
    }

    func testUndatedHistoryCannotBecomeEligible() throws {
        let undated = OccurrenceInput(station: "kcrw", providerID: nil, kind: "trackplay",
                                      title: "Undated", artist: "Artist", album: nil,
                                      artworkURL: nil, playedAt: nil)
        let history = try history([undated])
        XCTAssertEqual(OccurrenceSelector().select(from: history,
                                                    playerProgramDate: origin.addingTimeInterval(500),
                                                    playerElapsedSeconds: 20),
                       .unavailable(.historyBeginsAfterPlayer))
    }

    func testOldSelectionAndStaleFeedBecomeUnavailable() throws {
        let history = try history([occurrence("A", at: 0)], receivedAt: 10)
        let ageLimited = OccurrenceSelector(policy: .init(feedToProgramOffset: 160,
                                                           maxSelectedAge: 100,
                                                           maxFeedSilence: 1000))
        XCTAssertEqual(ageLimited.select(from: history, playerProgramDate: origin.addingTimeInterval(400),
                                         playerElapsedSeconds: 20),
                       .unavailable(.selectedOccurrenceTooOld))

        let staleLimited = OccurrenceSelector(policy: .init(feedToProgramOffset: 160,
                                                             maxSelectedAge: 1000,
                                                             maxFeedSilence: 30))
        XCTAssertEqual(staleLimited.select(from: history, playerProgramDate: origin.addingTimeInterval(200),
                                           playerElapsedSeconds: 41),
                       .unavailable(.staleFeed))
    }

    func testAmbiguousHistoryCannotSelect() throws {
        var history = OccurrenceHistory(policy: .init(maxOccurrences: 10, maxHistoryAge: 3600,
                                                       correctionWindow: 120))
        _ = try history.receive(requestID: 1, requestedElapsedSeconds: 0, receivedElapsedSeconds: 1,
                                entries: [occurrence("A", at: 100), occurrence("A", at: 250)])
        _ = try history.receive(requestID: 2, requestedElapsedSeconds: 1, receivedElapsedSeconds: 2,
                                entries: [occurrence("A", at: 175)])

        XCTAssertEqual(OccurrenceSelector().select(from: history,
                                                    playerProgramDate: origin.addingTimeInterval(500),
                                                    playerElapsedSeconds: 3),
                       .unavailable(.ambiguousHistory))
    }
}
