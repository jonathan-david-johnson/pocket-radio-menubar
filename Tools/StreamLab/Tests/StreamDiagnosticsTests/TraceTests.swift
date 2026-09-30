import Foundation
import XCTest
@testable import StreamDiagnostics

final class TraceTests: XCTestCase {
    func testCaptureRoundTripsAndReplaysIdentically() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let events = fixture()
        let writer = try TraceWriter(url: url)
        for event in events { try writer.append(event) }
        try writer.close()

        let loaded = try TraceReader.read(url: url)
        XCTAssertEqual(loaded, events)
        XCTAssertEqual(try TraceReplay.snapshots(events), try TraceReplay.snapshots(loaded))
        XCTAssertEqual(try TraceReplay.snapshots(loaded).last?.endReason, "duration")
    }

    /// A real capture stamps events with `Date()`, which carries sub-millisecond precision the
    /// trace file cannot hold. Events snap on init so a captured trace still reads back identical.
    func testUnalignedCaptureTimesSurviveAWriteReadRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let id = UUID()
        let events = [
            TraceEvent(sessionID: id, sequence: 0, elapsedSeconds: 0, wallTime: Date(),
                       payload: .started(SessionInfo(station: "kcrw", streamURL: "https://example.org/live", feedURL: nil, muted: true))),
            TraceEvent(sessionID: id, sequence: 1, elapsedSeconds: 0.5, wallTime: Date(), payload: .marker("heard_song_change")),
            TraceEvent(sessionID: id, sequence: 2, elapsedSeconds: 1, wallTime: Date(), payload: .ended("duration")),
        ]
        for event in events {
            XCTAssertEqual(event.wallTime.timeIntervalSince1970 * 1000, (event.wallTime.timeIntervalSince1970 * 1000).rounded())
        }

        let writer = try TraceWriter(url: url)
        for event in events { try writer.append(event) }
        try writer.close()
        XCTAssertEqual(try TraceReader.read(url: url), events)
        XCTAssertEqual(try TraceJSON.decoder().decode([TraceEvent].self, from: try TraceJSON.encoder().encode(events)), events)
    }

    func testFractionalPlaybackProgramDateSurvivesRoundTripAndReplay() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let id = UUID()
        let playback = PlaybackObservation(mediaSeconds: 12.25,
                                           programDate: Date(timeIntervalSince1970: 1_750_000_000.1234567),
                                           rate: 1, timeControlStatus: "playing", itemStatus: "ready",
                                           waitingReason: nil, loadedRanges: [], seekableRanges: [],
                                           bufferEmpty: false, likelyToKeepUp: true)
        let programDate = try XCTUnwrap(playback.programDate)
        XCTAssertEqual(programDate.timeIntervalSince1970 * 1000,
                       (programDate.timeIntervalSince1970 * 1000).rounded())
        let events = [
            TraceEvent(sessionID: id, sequence: 0, elapsedSeconds: 0, wallTime: Date(timeIntervalSince1970: 100),
                       payload: .started(SessionInfo(station: "kcrw", streamURL: "https://example.org/live", feedURL: nil, muted: true))),
            TraceEvent(sessionID: id, sequence: 1, elapsedSeconds: 1, wallTime: Date(timeIntervalSince1970: 101),
                       payload: .playback(playback)),
            TraceEvent(sessionID: id, sequence: 2, elapsedSeconds: 2, wallTime: Date(timeIntervalSince1970: 102),
                       payload: .ended("test")),
        ]

        let writer = try TraceWriter(url: url)
        for event in events { try writer.append(event) }
        try writer.close()
        let loaded = try TraceReader.read(url: url)
        XCTAssertEqual(loaded, events)
        XCTAssertEqual(try TraceReplay.snapshots(loaded), try TraceReplay.snapshots(events))
    }

    func testWriterRefusesOverwriteAndRestrictsFilePermissions() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try TraceWriter(url: url)
        XCTAssertThrowsError(try TraceWriter(url: url))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        try writer.close()
    }

    func testSizeLimitLeavesAnExplicitlyIncompleteTrace() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let events = fixture()
        let limit = try TraceJSON.encoder().encode(events[0]).count + 1
        let writer = try TraceWriter(url: url, byteLimit: limit)
        try writer.append(events[0])
        XCTAssertThrowsError(try writer.append(events[1])) { error in
            guard case TraceError.limitExceeded = error else { return XCTFail("Unexpected error: \(error)") }
        }
        try writer.close()
        XCTAssertThrowsError(try TraceReader.read(url: url))
        XCTAssertEqual(try Data(contentsOf: url).count, limit)
    }

    func testReaderReportsCorruptJSONLine() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not-json\n".utf8).write(to: url)

        XCTAssertThrowsError(try TraceReader.read(url: url)) { error in
            XCTAssertEqual(String(describing: error), "Invalid trace: invalid JSON event at line 1")
        }
    }

    func testReaderRejectsMissingFinalNewlineAsTruncated() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try TraceJSON.encoder().encode(fixture()[0]).write(to: url)

        XCTAssertThrowsError(try TraceReader.read(url: url)) { error in
            XCTAssertEqual(String(describing: error), "Invalid trace: missing final newline; possibly truncated")
        }
    }

    func testURLsAndEmbeddedMetadataStripSecrets() {
        XCTAssertEqual(TracePrivacy.url("https://user:password@radio.example/live?token=secret#fragment"), "https://radio.example/live")
        XCTAssertEqual(TracePrivacy.url("file:///Users/someone/private.wav"), "file:///<local-audio>")
        XCTAssertEqual(TracePrivacy.metadata("StreamTitle='Song';StreamUrl='https://u:p@radio.example/a?key=secret';"),
                       "StreamTitle='Song';StreamUrl='https://radio.example/a';")
        XCTAssertEqual(TracePrivacy.metadata("StreamTitle='Song';StreamUrl='file:///Users/synthetic/private.wav';"),
                       "StreamTitle='Song';StreamUrl='file:///<local-audio>';")
    }

    func testFeedNeverOverwritesSeparatePlayerMetadataEvidence() throws {
        let original = fixture()
        let metadata = MetadataObservation(receivedElapsedSeconds: 0.2, receivedMediaSeconds: 21,
                                           values: [MetadataValue(identifier: "icy/StreamTitle", key: "StreamTitle", keySpace: "icy",
                                                                  value: "Artist B - Song B", mediaStartSeconds: 20, mediaDurationSeconds: 1)])
        let entries = try StationFeed.decode(Data(#"{"results":[{"id":41,"play_type":"trackplay","song":"Song A","artist":"Artist A"}]}"#.utf8), station: .kexp)
        let feed = FeedObservation(requestID: 1, requestedElapsedSeconds: 0.1, statusCode: 200, headers: [:], bodyBytes: 100, entries: entries, failure: nil)
        let events = [original[0],
                      TraceEvent(sessionID: original[0].sessionID, sequence: 1, elapsedSeconds: 0.3, wallTime: Date(), payload: .metadata(metadata)),
                      TraceEvent(sessionID: original[0].sessionID, sequence: 2, elapsedSeconds: 0.4, wallTime: Date(), payload: .feed(feed)),
                      TraceEvent(sessionID: original[0].sessionID, sequence: 3, elapsedSeconds: 1, wallTime: Date(), payload: .ended("test"))]
        let snapshot = try XCTUnwrap(TraceReplay.snapshots(events).last)
        XCTAssertEqual(snapshot.metadata, metadata)
        XCTAssertEqual(snapshot.feed?.entries.first?.title, "Song A")
        let encoded = try TraceJSON.encoder().encode(events)
        XCTAssertEqual(try TraceJSON.decoder().decode([TraceEvent].self, from: encoded), events)
    }

    func testReplayRejectsDuplicateStart() {
        let events = fixture()
        let duplicate = TraceEvent(sessionID: events[0].sessionID, sequence: 1, elapsedSeconds: 1,
                                   wallTime: Date(timeIntervalSince1970: 124),
                                   payload: .started(SessionInfo(station: "kexp", streamURL: "https://example.org/other",
                                                                 feedURL: nil, muted: true)))
        assertInvalid([events[0], duplicate], reason: "duplicate session start")
    }

    func testReplayRejectsWrongSession() {
        let events = fixture()
        let wrongSession = TraceEvent(sessionID: UUID(), sequence: 1, elapsedSeconds: 1,
                                      wallTime: Date(timeIntervalSince1970: 124), payload: .marker("wrong"))
        assertInvalid([events[0], wrongSession], reason: "wrong session")
    }

    func testReplayRejectsSequenceGapOrReordering() {
        let events = fixture()
        let skipped = TraceEvent(sessionID: events[0].sessionID, sequence: 2, elapsedSeconds: 1,
                                 wallTime: Date(timeIntervalSince1970: 124), payload: .marker("skipped"))
        assertInvalid([events[0], skipped], reason: "sequence gap or reordering")
    }

    func testReplayRejectsBackwardElapsedTime() {
        let events = fixture()
        let forward = TraceEvent(sessionID: events[0].sessionID, sequence: 1, elapsedSeconds: 2,
                                 wallTime: Date(timeIntervalSince1970: 124), payload: .marker("forward"))
        let backward = TraceEvent(sessionID: events[0].sessionID, sequence: 2, elapsedSeconds: 1,
                                  wallTime: Date(timeIntervalSince1970: 125), payload: .ended("test"))
        assertInvalid([events[0], forward, backward], reason: "invalid or backward elapsed time")
    }

    func testReplayRejectsNonfiniteWallClock() {
        let event = TraceEvent(sessionID: UUID(), sequence: 0, elapsedSeconds: 0,
                               wallTime: Date(timeIntervalSince1970: .infinity),
                               payload: .notice("invalid"))
        assertInvalid([event], reason: "invalid wall clock")
    }

    func testReplayAllowsBackwardWallClockCorrection() throws {
        let id = UUID()
        let events = [
            TraceEvent(sessionID: id, sequence: 0, elapsedSeconds: 0, wallTime: Date(timeIntervalSince1970: 200),
                       payload: .started(SessionInfo(station: "kexp", streamURL: "https://example.org/live", feedURL: nil, muted: true))),
            TraceEvent(sessionID: id, sequence: 1, elapsedSeconds: 1, wallTime: Date(timeIntervalSince1970: 100),
                       payload: .marker("clock_corrected")),
            TraceEvent(sessionID: id, sequence: 2, elapsedSeconds: 2, wallTime: Date(timeIntervalSince1970: 101),
                       payload: .ended("test")),
        ]
        let snapshots = try TraceReplay.snapshots(events)
        XCTAssertEqual(snapshots.count, 3)
        XCTAssertEqual(snapshots.last?.endReason, "test")
    }

    func testReplayRejectsUnsupportedSchemaVersion() {
        let id = UUID()
        var start = TraceEvent(sessionID: id, sequence: 0, elapsedSeconds: 0,
                               wallTime: Date(timeIntervalSince1970: 123),
                               payload: .started(SessionInfo(station: "kexp", streamURL: "https://example.org/live", feedURL: nil, muted: true)))
        start.schemaVersion = 2
        assertInvalid([start], reason: "unsupported schema version")
    }

    func testReplayRejectsEventAfterSessionEnd() {
        let events = fixture()
        let late = TraceEvent(sessionID: events[0].sessionID, sequence: 3, elapsedSeconds: 3,
                              wallTime: Date(timeIntervalSince1970: 126), payload: .marker("late"))
        assertInvalid(events + [late], reason: "event after session end")
    }

    func testReplayRejectsMissingStart() {
        let event = TraceEvent(sessionID: UUID(), sequence: 0, elapsedSeconds: 0,
                               wallTime: Date(timeIntervalSince1970: 123), payload: .ended("test"))
        assertInvalid([event], reason: "missing session start")
    }

    func testReplayRejectsMissingEnd() {
        assertInvalid(Array(fixture().prefix(2)), reason: "incomplete capture: missing session end")
    }

    func testReplayPreservesMultipleMetadataItemsAndMediaRanges() throws {
        let id = UUID()
        let metadata = MetadataObservation(
            receivedElapsedSeconds: 1,
            receivedMediaSeconds: 12,
            values: [
                MetadataValue(identifier: "icy/title", key: "StreamTitle", keySpace: "icy", value: "Artist - Song",
                              mediaStartSeconds: 11, mediaDurationSeconds: 1),
                MetadataValue(identifier: "id3/album", key: "album", keySpace: "id3", value: "Album",
                              mediaStartSeconds: 10.5, mediaDurationSeconds: 2),
            ]
        )
        let loaded = [MediaRange(start: 10, duration: 5), MediaRange(start: 20, duration: 4)]
        let seekable = [MediaRange(start: 8, duration: 16)]
        let playback = PlaybackObservation(mediaSeconds: 12, programDate: nil, rate: 1,
                                           timeControlStatus: "playing", itemStatus: "ready", waitingReason: nil,
                                           loadedRanges: loaded, seekableRanges: seekable,
                                           bufferEmpty: false, likelyToKeepUp: true)
        let events = [
            TraceEvent(sessionID: id, sequence: 0, elapsedSeconds: 0, wallTime: Date(timeIntervalSince1970: 123),
                       payload: .started(SessionInfo(station: "kexp", streamURL: "https://example.org/live", feedURL: nil, muted: true))),
            TraceEvent(sessionID: id, sequence: 1, elapsedSeconds: 1, wallTime: Date(timeIntervalSince1970: 124),
                       payload: .metadata(metadata)),
            TraceEvent(sessionID: id, sequence: 2, elapsedSeconds: 2, wallTime: Date(timeIntervalSince1970: 125),
                       payload: .playback(playback)),
            TraceEvent(sessionID: id, sequence: 3, elapsedSeconds: 3, wallTime: Date(timeIntervalSince1970: 126),
                       payload: .ended("test")),
        ]

        let final = try XCTUnwrap(TraceReplay.snapshots(events).last)
        XCTAssertEqual(final.metadata?.values, metadata.values)
        XCTAssertEqual(final.playback?.loadedRanges, loaded)
        XCTAssertEqual(final.playback?.seekableRanges, seekable)
    }

    private func assertInvalid(_ events: [TraceEvent], reason: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try TraceReplay.snapshots(events), file: file, line: line) { error in
            XCTAssertEqual(String(describing: error), "Invalid trace: \(reason)", file: file, line: line)
        }
    }

    private func fixture() -> [TraceEvent] {
        let id = UUID()
        return [
            TraceEvent(sessionID: id, sequence: 0, elapsedSeconds: 0, wallTime: Date(timeIntervalSince1970: 123),
                       payload: .started(SessionInfo(station: "kexp", streamURL: "https://example.org/live", feedURL: nil, muted: true))),
            TraceEvent(sessionID: id, sequence: 1, elapsedSeconds: 1, wallTime: Date(timeIntervalSince1970: 124),
                       payload: .marker("heard_song_change")),
            TraceEvent(sessionID: id, sequence: 2, elapsedSeconds: 2, wallTime: Date(timeIntervalSince1970: 125),
                       payload: .ended("duration")),
        ]
    }
}
