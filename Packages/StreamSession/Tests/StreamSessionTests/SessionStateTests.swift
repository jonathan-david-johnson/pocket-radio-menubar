import XCTest
@testable import StreamSession

final class SessionStateTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func input(_ title: String, at seconds: Double) -> OccurrenceInput {
        OccurrenceInput(station: "kcrw", providerID: nil, kind: "trackplay", title: title,
                        artist: "Artist", album: nil, artworkURL: nil,
                        playedAt: origin.addingTimeInterval(seconds))
    }

    func testFutureFeedEvidenceCannotLeakIntoEarlierPlayerDecision() throws {
        var state = SessionState()
        let beforeFeed = state.observePlayer(MediaClockSample(generation: "item", elapsedSeconds: 10,
                                                               mediaSeconds: 10,
                                                               programDate: origin.addingTimeInterval(400),
                                                               isAdvancing: true))
        XCTAssertEqual(beforeFeed.selection, .unavailable(.noHistory))

        let mutation = try state.receiveFeed(requestID: 1, requestedElapsedSeconds: 19,
                                             receivedElapsedSeconds: 20,
                                             entries: [input("A", at: 0), input("B", at: 200)])
        guard case .selected(let selected)? = mutation.decision?.selection else {
            return XCTFail("The newly received evidence should be evaluated only at its receipt event")
        }
        XCTAssertEqual(mutation.decision?.elapsedSeconds, 20)
        XCTAssertEqual(selected.occurrence.title, "B")
        XCTAssertEqual(beforeFeed.selection, .unavailable(.noHistory),
                       "A later feed event cannot revise an already emitted decision")
    }

    func testNewGenerationJoinsAtSupportedCurrentPositionNotZero() throws {
        var state = SessionState(selectionPolicy: .init(feedToProgramOffset: 160,
                                                        maxSelectedAge: 1200,
                                                        maxFeedSilence: 1000))
        _ = try state.receiveFeed(requestID: 1, requestedElapsedSeconds: 0,
                                  receivedElapsedSeconds: 1, entries: [input("A", at: 0)])
        _ = state.observePlayer(MediaClockSample(generation: "item-1", elapsedSeconds: 10,
                                                 mediaSeconds: 10,
                                                 programDate: origin.addingTimeInterval(200),
                                                 isAdvancing: true))
        let reconnected = state.observePlayer(MediaClockSample(generation: "item-2", elapsedSeconds: 20,
                                                                mediaSeconds: 3,
                                                                programDate: origin.addingTimeInterval(300),
                                                                isAdvancing: true))
        guard case .selected(let selection) = reconnected.selection else {
            return XCTFail("Expected a reconnected current occurrence")
        }
        XCTAssertEqual(selection.occurrence.title, "A")
        XCTAssertEqual(selection.songSeconds, 140, accuracy: 0.000_001)
    }

    func testFeedPollDuringPauseDoesNotAdvanceMediaDerivedPosition() throws {
        var state = SessionState(selectionPolicy: .init(feedToProgramOffset: 160,
                                                        maxSelectedAge: 1200,
                                                        maxFeedSilence: 1000))
        _ = try state.receiveFeed(requestID: 1, requestedElapsedSeconds: 0,
                                  receivedElapsedSeconds: 1, entries: [input("A", at: 0)])
        let paused = state.observePlayer(MediaClockSample(generation: "item", elapsedSeconds: 170,
                                                          mediaSeconds: 10,
                                                          programDate: origin.addingTimeInterval(170),
                                                          isAdvancing: false))
        guard case .selected(let atPause) = paused.selection else { return XCTFail("Expected selection") }

        let feed = try state.receiveFeed(requestID: 2, requestedElapsedSeconds: 199,
                                         receivedElapsedSeconds: 200,
                                         entries: [input("A", at: 0), input("Future", at: 100)])
        guard case .selected(let whilePaused)? = feed.decision?.selection else {
            return XCTFail("Expected the paused clock to remain usable")
        }
        XCTAssertEqual(whilePaused.occurrence.title, "A")
        XCTAssertEqual(whilePaused.songSeconds, atPause.songSeconds, accuracy: 0.000_001)
    }
}
