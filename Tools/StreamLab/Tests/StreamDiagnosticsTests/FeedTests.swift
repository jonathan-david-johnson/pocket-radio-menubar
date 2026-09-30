import Foundation
import XCTest
@testable import StreamDiagnostics

final class FeedTests: XCTestCase {
    func testKEXPPreservesAirbreakIDsAndFractionalProviderTime() throws {
        let data = Data(#"{"results":[{"id":42,"play_type":"airbreak","airdate":"2026-09-16T16:17:16.123456-07:00"},{"id":41,"play_type":"trackplay","song":"Song A","artist":"Artist A","thumbnail_uri":"https://art.example/a?secret=x","airdate":"2026-09-16T16:12:00-07:00"}]}"#.utf8)
        let entries = try StationFeed.decode(data, station: .kexp)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].kind, "airbreak")
        XCTAssertEqual(entries[0].providerID, "42")
        let playedAt = try XCTUnwrap(entries[0].playedAt)
        XCTAssertEqual(playedAt.timeIntervalSince1970 * 1000,
                       (playedAt.timeIntervalSince1970 * 1000).rounded())
        XCTAssertEqual(entries[1].title, "Song A")
        XCTAssertEqual(entries[1].artworkURL, "https://art.example/a")
        let encoded = try TraceJSON.encoder().encode(entries)
        XCTAssertEqual(try TraceJSON.decoder().decode([FeedEntry].self, from: encoded), entries)
    }

    func testKCRWPreservesBreakTrackAndProviderTimes() throws {
        let data = Data(#"[{"title":"[BREAK]","artist":"DJ","datetime":"2026-09-16T16:17:16.987654-07:00"},{"title":"Song A","artist":"Artist A","album":"Album A","albumImageLarge":"https://art.example/a?secret=x","datetime":"2026-09-16T16:12:00-07:00"}]"#.utf8)
        let entries = try StationFeed.decode(data, station: .kcrw)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].kind, "break")
        XCTAssertEqual(entries[0].providerTimestamp, "2026-09-16T16:17:16.987654-07:00")
        let breakTime = try XCTUnwrap(entries[0].playedAt)
        XCTAssertEqual(breakTime.timeIntervalSince1970 * 1000,
                       (breakTime.timeIntervalSince1970 * 1000).rounded())
        XCTAssertEqual(entries[1].kind, "trackplay")
        XCTAssertEqual(entries[1].title, "Song A")
        XCTAssertEqual(entries[1].artist, "Artist A")
        XCTAssertEqual(entries[1].album, "Album A")
        XCTAssertEqual(entries[1].artworkURL, "https://art.example/a")
    }
}
