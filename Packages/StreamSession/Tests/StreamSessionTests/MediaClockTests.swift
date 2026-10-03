import XCTest
@testable import StreamSession

final class MediaClockTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func sample(generation: String = "item-1", elapsed: Double, media: Double?, program: Double?,
                        advancing: Bool = true) -> MediaClockSample {
        MediaClockSample(generation: generation, elapsedSeconds: elapsed, mediaSeconds: media,
                         programDate: program.map { origin.addingTimeInterval($0) },
                         isAdvancing: advancing)
    }

    func testClockAdvancesFromMediaAnchorAndFreezesThroughPause() {
        var clock = MediaClock()
        XCTAssertEqual(clock.observe(sample(elapsed: 0, media: 10, program: 100)),
                       .valid(.init(generation: "item-1", elapsedSeconds: 0, mediaSeconds: 10,
                                    programDate: origin.addingTimeInterval(100))))
        XCTAssertEqual(clock.observe(sample(elapsed: 10, media: 20, program: 110)),
                       .valid(.init(generation: "item-1", elapsedSeconds: 10, mediaSeconds: 20,
                                    programDate: origin.addingTimeInterval(110))))

        let paused = clock.observe(sample(elapsed: 41.367, media: 20, program: 110, advancing: false))
        XCTAssertEqual(paused,
                       .valid(.init(generation: "item-1", elapsedSeconds: 41.367, mediaSeconds: 20,
                                    programDate: origin.addingTimeInterval(110))),
                       "Wall/elapsed time must not advance the media-derived program date")
    }

    func testMissingAndNonfinitePairsInvalidateClock() {
        var clock = MediaClock()
        _ = clock.observe(sample(elapsed: 0, media: 0, program: 0))
        XCTAssertEqual(clock.observe(sample(elapsed: 1, media: nil, program: 1)),
                       .invalid(.missingPair))
        XCTAssertEqual(clock.observe(sample(elapsed: 2, media: .infinity, program: 2)),
                       .invalid(.nonfinitePair))
    }

    func testBackwardAndIncompatibleJumpsInvalidateThenNextPairReanchors() {
        var clock = MediaClock(policy: .init(correlationTolerance: 1.5, progressionTolerance: 2))
        _ = clock.observe(sample(elapsed: 0, media: 10, program: 100))
        XCTAssertEqual(clock.observe(sample(elapsed: 1, media: 9, program: 101)),
                       .invalid(.backwardJump))

        let reanchored = clock.observe(sample(elapsed: 2, media: 20, program: 200))
        XCTAssertEqual(reanchored,
                       .valid(.init(generation: "item-1", elapsedSeconds: 2, mediaSeconds: 20,
                                    programDate: origin.addingTimeInterval(200))))

        XCTAssertEqual(clock.observe(sample(elapsed: 3, media: 21, program: 205)),
                       .invalid(.correlationDiscontinuity))
    }

    func testLargePlayingMediaJumpRelativeToElapsedInvalidates() {
        var clock = MediaClock(policy: .init(correlationTolerance: 1.5, progressionTolerance: 2))
        _ = clock.observe(sample(elapsed: 0, media: 0, program: 0))
        XCTAssertEqual(clock.observe(sample(elapsed: 1, media: 20, program: 20)),
                       .invalid(.mediaProgressionDiscontinuity))
    }

    func testForwardWindowJumpAfterPauseInvalidates() {
        var clock = MediaClock(policy: .init(correlationTolerance: 1.5, progressionTolerance: 2))
        _ = clock.observe(sample(elapsed: 0, media: 0, program: 0))
        _ = clock.observe(sample(elapsed: 30, media: 0, program: 0, advancing: false))
        XCTAssertEqual(clock.observe(sample(elapsed: 31, media: 50, program: 50, advancing: true)),
                       .invalid(.mediaProgressionDiscontinuity),
                       "A resume/go-live jump must not masquerade as continuous buffered playback")
    }

    func testNewGenerationUsesOnlyItsOwnValidPair() {
        var clock = MediaClock()
        _ = clock.observe(sample(elapsed: 0, media: 10, program: 100))
        let newItem = clock.observe(sample(generation: "item-2", elapsed: 1, media: 3, program: 500))
        XCTAssertEqual(newItem,
                       .valid(.init(generation: "item-2", elapsedSeconds: 1, mediaSeconds: 3,
                                    programDate: origin.addingTimeInterval(500))))
        XCTAssertEqual(clock.generation, "item-2")
    }
}
