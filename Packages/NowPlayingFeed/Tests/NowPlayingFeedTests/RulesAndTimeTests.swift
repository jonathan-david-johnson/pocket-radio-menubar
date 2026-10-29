import XCTest
@testable import NowPlayingFeed

final class RulesAndTimeTests: XCTestCase {
    // Behavior 4. Expected values were computed with Python's datetime, an independent implementation.
    func testISOFormats() {
        XCTAssertEqual(FeedTime.iso("2026-10-29T03:45:17-07:00"), 1793270717)
        XCTAssertEqual(FeedTime.iso("2026-10-29 11:45:41 +0100"), 1793270741)   // no colon, space before the offset
        XCTAssertEqual(FeedTime.iso("2026-10-29 11:45:41+01:00"), 1793270741)
        XCTAssertEqual(FeedTime.iso("2026-10-29T10:45:41Z"), 1793270741)
        XCTAssertEqual(FeedTime.iso("2026-10-29 10:48:38.02+00:00")!, 1793270918.02, accuracy: 0.001)
        XCTAssertNil(FeedTime.iso("not a time"))
    }

    func testNaiveTimeUsesTheNamedZone() {
        XCTAssertEqual(FeedTime.iso("2026-10-29 03:49:22", zone: TimeZone(identifier: "America/Los_Angeles")), 1793270962)
        XCTAssertEqual(FeedTime.iso("2026-10-29T12:25:42", zone: TimeZone(identifier: "Europe/Amsterdam")), 1793273142)
        XCTAssertEqual(FeedTime.iso("2026-10-29T12:25:42"), 1793276742, "no zone means UTC")
    }

    func testOtherFormats() {
        XCTAssertEqual(FeedTime.dotNet("/Date(1793270805000)/"), 1793270805)
        XCTAssertEqual(FeedTime.monthDayYear("10-29-2026 06:47:00", zone: TimeZone(identifier: "America/Chicago")!), 1793274420)
    }

    func testOutputFormatDropsFractions() {
        XCTAssertEqual(FeedTime.format(1793270918.99), "2026-10-29T10:48:38Z")
    }

    // Behavior 5: the ended and stale boundaries (60 s and 900 s).
    func testEndedAndStaleBoundaries() {
        let c = Candidate(title: "Song", artist: "Artist", startedAt: 1_000_000, duration: 200)   // ends at 1_000_200
        func status(_ now: Double) -> NowPlayingRecord.Status {
            Rules.record(c, now: now, stationId: "s", channel: .api, adapter: "t").status
        }
        XCTAssertEqual(status(1_000_200 + 60), .playing, "exactly 60 s past the end is still playing")
        XCTAssertEqual(status(1_000_200 + 61), .between)
        XCTAssertEqual(status(1_000_200 + 900), .between, "exactly 900 s past is still between")
        XCTAssertEqual(status(1_000_200 + 901), .stale)
    }

    func testNoDurationGoesStaleAfter900Seconds() {
        let song = Candidate(title: "Song", artist: "Artist", startedAt: 1_000_000)
        XCTAssertEqual(Rules.record(song, now: 1_000_900, stationId: "s", channel: .api, adapter: "t").status, .playing)
        XCTAssertEqual(Rules.record(song, now: 1_000_901, stationId: "s", channel: .api, adapter: "t").status, .stale)
    }

    func testAShowIsNeverStaleForLackOfADuration() {
        let show = Candidate(kind: .show, title: "Morning Show", startedAt: 1_000_000, show: "Morning Show")
        XCTAssertEqual(Rules.record(show, now: 1_000_000 + 40_000, stationId: "s", channel: .api, adapter: "t").status, .playing)
    }

    func testHttpArtworkIsUpgradedAndAudioIsNotInvolved() {
        let c = Candidate(title: "T", artist: "A", artwork: "http://image.example/a.jpg")
        XCTAssertEqual(Rules.record(c, now: 5, stationId: "s", channel: .api, adapter: "t").item?.artworkUrl, "https://image.example/a.jpg")
    }

    func testDurationRoundsHalfToEven() {
        // Python's round() is half-to-even, and the contract was generated with it.
        let c = Candidate(title: "T", artist: "A", startedAt: 100, duration: 2.5)
        XCTAssertEqual(Rules.record(c, now: 101, stationId: "s", channel: .api, adapter: "t").item?.durationSec, 2)
    }

    func testEntityDecoding() {
        XCTAssertEqual(Text.unescape("W/ FLO &amp; Operelly &#39;s &#x41;"), "W/ FLO & Operelly 's A")
        XCTAssertEqual(Text.unescape("no entity & here"), "no entity & here")
    }
}
