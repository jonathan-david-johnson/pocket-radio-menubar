import AVFoundation
import XCTest
import StreamDiagnostics
import StreamSession
@testable import PocketRadio

@MainActor
final class StreamSessionIntegrationTests: XCTestCase {
    private func station(name: String = "KCRW Eclectic24", stream: String = "https://streams.kcrw.com/e24_mp3") -> RadioStation {
        RadioStation(id: "fixture-station", name: name, streamURL: stream, logoURL: nil)
    }

    func testEndpointOverrideIsSessionOnlyAndExact() {
        let supported = station()
        XCTAssertTrue(StreamExperimentConfiguration.isEligible(supported))
        XCTAssertEqual(StreamExperimentConfiguration.resolvedURL(for: supported, mode: .off)?.absoluteString,
                       supported.streamURL)
        XCTAssertEqual(StreamExperimentConfiguration.resolvedURL(for: supported, mode: .observeOnly),
                       StreamExperimentConfiguration.measuredEndpoint)
        XCTAssertEqual(StreamExperimentConfiguration.resolvedURL(for: supported, mode: .applyCandidate),
                       StreamExperimentConfiguration.measuredEndpoint)
        XCTAssertEqual(supported.streamURL, "https://streams.kcrw.com/e24_mp3", "Never rewrite the station")
        let curatedAAC = station(name: "KCRW Eclectic 24 (AAC)",
                                 stream: "https://streams.kcrw.com/e24_aac")
        XCTAssertTrue(StreamExperimentConfiguration.isEligible(curatedAAC))
        XCTAssertEqual(StreamExperimentConfiguration.resolvedURL(for: curatedAAC, mode: .off)?.absoluteString,
                       curatedAAC.streamURL)
        XCTAssertEqual(StreamExperimentConfiguration.resolvedURL(for: curatedAAC, mode: .observeOnly),
                       StreamExperimentConfiguration.measuredEndpoint)
        XCTAssertEqual(StreamExperimentConfiguration.resolvedURL(for: curatedAAC, mode: .applyCandidate),
                       StreamExperimentConfiguration.measuredEndpoint)
        XCTAssertEqual(curatedAAC.streamURL, "https://streams.kcrw.com/e24_aac",
                       "Curated source remains unchanged")
        for other in [
            station(name: "KEXP"),
            station(stream: "https://streams.kcrw.com/other_aac/playlist.m3u8"),
            station(stream: "https://streams.kcrw.com/e24_aac/other.m3u8"),
            station(stream: "https://streams.kcrw.com/e24_aac?token=private"),
            station(stream: "https://streams.kcrw.com/e24_mp3?token=private"),
            station(stream: "https://unrelated.invalid/e24_mp3"),
        ] {
            XCTAssertFalse(StreamExperimentConfiguration.isEligible(other))
            XCTAssertEqual(StreamExperimentConfiguration.resolvedURL(for: other, mode: .observeOnly)?.absoluteString,
                           other.streamURL)
            XCTAssertEqual(StreamExperimentConfiguration.resolvedURL(for: other, mode: .applyCandidate)?.absoluteString,
                           other.streamURL)
        }
        XCTAssertEqual(StreamExperimentConfiguration.selectionPolicy.feedToProgramOffset, 160)
        XCTAssertEqual(StreamExperimentConfiguration.selectionPolicy.maxFeedSilence, 120)
    }

    func testEligibilityExplainsMismatchedStationWithoutExpandingOverride() {
        let cases: [(RadioStation, String)] = [
            (station(name: "Another station"), "station name does not identify KCRW"),
            (station(stream: "https://alternate.example/e24_mp3"), "station stream host is not the measured host"),
            (station(stream: "https://streams.kcrw.com/other"), "station stream path is not the known Eclectic24 variant"),
            (station(stream: "https://streams.kcrw.com/e24_mp3?private=secret"), "station stream URL contains credentials, query, or fragment"),
            (station(stream: "https://user:secret@streams.kcrw.com/e24_mp3"), "station stream URL contains credentials, query, or fragment"),
        ]
        for (radio, reason) in cases {
            XCTAssertEqual(StreamExperimentConfiguration.ineligibilityReason(for: radio), reason)
            XCTAssertFalse(StreamExperimentConfiguration.isEligible(radio))
            XCTAssertEqual(StreamExperimentConfiguration.resolvedURL(for: radio, mode: .observeOnly)?.absoluteString,
                           radio.streamURL)
        }
        XCTAssertNil(StreamExperimentConfiguration.ineligibilityReason(for: station()))
    }

    func testObserveOnlyUsesReceivedFeedAndSameItemWithoutPublishing() throws {
        let item = AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent-stream-lab-fixture.aiff"))
        let otherItem = AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent-other.aiff"))
        let session = RadioPlaybackSession(item: item, endpoint: StreamExperimentConfiguration.measuredEndpoint,
                                           fetchFeed: { XCTFail("No network fetch expected");
                                               return RadioFeedResult(entries: [], statusCode: 200,
                                                                      cacheAgeSeconds: nil, failure: nil) },
                                           startPolling: false)
        var snapshots: [RadioExperimentSnapshot] = []
        session.onSnapshot = { snapshots.append($0) }
        let raw = Data("""
        [{"title":"Future","artist":"Artist","datetime":"2027-01-15T08:03:20Z"},
         {"title":"Current","artist":"Artist","datetime":"2027-01-15T08:00:00Z"}]
        """.utf8)
        // Use the trace parser in the app adapter, not the legacy UUID-per-poll model.
        let entries = try StationFeed.decode(raw, station: .kcrw)
        let dateA = try XCTUnwrap(entries.last?.playedAt)
        session.accept(RadioFeedResult(entries: entries, statusCode: 200,
                                       cacheAgeSeconds: 10, failure: nil),
                       requestedElapsed: 1, receivedElapsed: 2)
        XCTAssertEqual(session.snapshot.feedTop, "Future — Artist")
        XCTAssertNil(session.snapshot.candidate)
        XCTAssertNil(RadioApplySelection(snapshot: session.snapshot), "Feed receipt cannot publish")
        let sampleA = MediaClockSample(generation: session.generation.uuidString, elapsedSeconds: 10,
                                       mediaSeconds: 10, programDate: dateA.addingTimeInterval(190),
                                       isAdvancing: true)
        session.observe(sampleA, currentItem: item)
        XCTAssertEqual(session.snapshot.candidate, "Current — Artist")
        XCTAssertEqual(try XCTUnwrap(session.snapshot.songSeconds), 30, accuracy: 0.001)
        XCTAssertEqual(session.snapshot.feedTop, "Future — Artist")
        XCTAssertEqual(RadioApplySelection(snapshot: session.snapshot)?.title, "Current — Artist")
        XCTAssertEqual(session.snapshot.history.count, 2)
        let selected = try XCTUnwrap(session.snapshot.selectedOccurrence)
        let openedRow = TracklistEntry(title: "Current", artist: "Artist", album: nil,
                                       albumArtURL: nil, playedAt: dateA)
        let refreshedRow = TracklistEntry(title: "Current", artist: "Artist", album: nil,
                                          albumArtURL: nil, playedAt: dateA)
        XCTAssertNotEqual(openedRow.id, refreshedRow.id, "Feed refresh creates new row UUIDs")
        XCTAssertTrue(PlayerViewModel.matchesAppliedOccurrence(openedRow, selected),
                      "Open live lyric detail must remain current after a feed refresh")
        XCTAssertTrue(PlayerViewModel.matchesAppliedOccurrence(refreshedRow, selected))
        let anotherPlay = TracklistEntry(title: "Current", artist: "Artist", album: nil,
                                         albumArtURL: nil, playedAt: dateA.addingTimeInterval(60))
        XCTAssertFalse(PlayerViewModel.matchesAppliedOccurrence(anotherPlay, selected),
                       "A later occurrence of the same title must not be highlighted")
        let emitted = snapshots.count
        session.observe(MediaClockSample(generation: session.generation.uuidString,
                                         elapsedSeconds: 11, mediaSeconds: 11,
                                         programDate: dateA.addingTimeInterval(191),
                                         isAdvancing: true), currentItem: otherItem)
        XCTAssertEqual(snapshots.count, emitted, "Other player's sample cannot publish")
        session.stop()
        session.accept(RadioFeedResult(entries: entries, statusCode: 200,
                                       cacheAgeSeconds: nil, failure: nil),
                       requestedElapsed: 20, receivedElapsed: 21)
        XCTAssertEqual(snapshots.count, emitted, "Stopped generation rejects late feed results")
    }

    func testFeedReceiptCannotAdvanceCandidateUntilAnotherPlayerSample() throws {
        let item = AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent-fixture.aiff"))
        let session = RadioPlaybackSession(item: item, endpoint: StreamExperimentConfiguration.measuredEndpoint,
                                           fetchFeed: { XCTFail("No network");
                                               return RadioFeedResult(entries: [], statusCode: nil,
                                                                      cacheAgeSeconds: nil, failure: "fixture") },
                                           startPolling: false)
        let first = try StationFeed.decode(Data("[{\"title\":\"First\",\"artist\":\"Artist\",\"datetime\":\"2027-01-15T08:00:00Z\"}]".utf8), station: .kcrw)
        let second = try StationFeed.decode(Data("[{\"title\":\"Second\",\"artist\":\"Artist\",\"datetime\":\"2027-01-15T08:00:20Z\"}]".utf8), station: .kcrw)
        let date = try XCTUnwrap(first[0].playedAt)
        session.accept(RadioFeedResult(entries: first, statusCode: 200, cacheAgeSeconds: nil,
                                       failure: nil), requestedElapsed: 1, receivedElapsed: 2)
        session.observe(MediaClockSample(generation: session.generation.uuidString, elapsedSeconds: 10,
                                         mediaSeconds: 10, programDate: date.addingTimeInterval(190),
                                         isAdvancing: true), currentItem: item)
        XCTAssertEqual(session.snapshot.candidate, "First — Artist")
        session.accept(RadioFeedResult(entries: second, statusCode: 200, cacheAgeSeconds: nil,
                                       failure: nil), requestedElapsed: 11, receivedElapsed: 12)
        XCTAssertEqual(session.snapshot.feedTop, "Second — Artist")
        XCTAssertEqual(session.snapshot.candidate, "First — Artist")
        XCTAssertNil(RadioApplySelection(snapshot: session.snapshot),
                     "Feed-only update must not republish an already selected occurrence")
        session.observe(MediaClockSample(generation: session.generation.uuidString, elapsedSeconds: 13,
                                         mediaSeconds: 13, programDate: date.addingTimeInterval(193),
                                         isAdvancing: true), currentItem: item)
        XCTAssertEqual(session.snapshot.candidate, "Second — Artist")
        XCTAssertEqual(RadioApplySelection(snapshot: session.snapshot)?.title, "Second — Artist")
        session.observe(MediaClockSample(generation: session.generation.uuidString,
                                         elapsedSeconds: 14, mediaSeconds: 14,
                                         programDate: nil, isAdvancing: true), currentItem: item)
        XCTAssertNil(RadioApplySelection(snapshot: session.snapshot),
                     "Missing paired clock must not keep the previous song publishable")
        session.stop()
    }

    func testApplySelectionRejectsNonSongEvenWithValidClock() throws {
        let item = AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent-break-fixture.aiff"))
        let session = RadioPlaybackSession(item: item,
            endpoint: StreamExperimentConfiguration.measuredEndpoint,
            mode: .applyCandidate,
            fetchFeed: { XCTFail("No network"); return RadioFeedResult(entries: [],
                statusCode: nil, cacheAgeSeconds: nil, failure: "fixture") },
            startPolling: false)
        let rows = try StationFeed.decode(Data("""
        [{"title":"Station ID","artist":"[BREAK]","datetime":"2027-01-15T08:00:00Z"}]
        """.utf8), station: .kcrw)
        XCTAssertEqual(rows.first?.kind, "break")
        let date = try XCTUnwrap(rows.first?.playedAt)
        session.accept(RadioFeedResult(entries: rows, statusCode: 200,
                                       cacheAgeSeconds: 0, failure: nil),
                       requestedElapsed: 1, receivedElapsed: 2)
        session.observe(MediaClockSample(generation: session.generation.uuidString,
                                         elapsedSeconds: 3, mediaSeconds: 3,
                                         programDate: date.addingTimeInterval(161),
                                         isAdvancing: true), currentItem: item)
        XCTAssertEqual(session.snapshot.selectedOccurrence?.kind, "break")
        XCTAssertNil(RadioApplySelection(snapshot: session.snapshot),
                     "Do not publish breaks as song titles or timed lyrics")
        session.stop()
    }

    func testApplyTimedLyricsRequireExactLookup() {
        let lines = [LyricLine(timestamp: 0, text: "Fixture line")]
        XCTAssertTrue(LyricsResult(lines: lines, plain: nil, provenance: .exact).isExactSynced)
        XCTAssertFalse(LyricsResult(lines: lines, plain: nil, provenance: .search).isExactSynced)
        XCTAssertFalse(LyricsResult(lines: lines, plain: nil).isExactSynced)
        XCTAssertFalse(LyricsResult(lines: [], plain: "Plain", provenance: .exact).isExactSynced)
    }

    func testRecorderDoesNotOverwriteExistingSidecarOrClaimCompleteExport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stream-experiment-collision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let path = directory.appendingPathComponent("kcrw-\(id.uuidString.lowercased()).decisions.json")
        let prior = Data("existing capture".utf8)
        try prior.write(to: path)
        let recorder = try StreamExperimentRecorder(sessionID: id,
            endpoint: StreamExperimentConfiguration.measuredEndpoint,
            routeCategory: "unrecorded", sessionElapsedAtStart: 0, directory: directory)
        XCTAssertTrue(recorder.finish(reason: "user").hasPrefix("Capture incomplete"))
        XCTAssertEqual(try Data(contentsOf: path), prior)
    }

    func testApplyRecorderLabelsModeWithoutChangingObservedCaptureDefaults() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stream-experiment-apply-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let recorder = try StreamExperimentRecorder(sessionID: id,
            endpoint: StreamExperimentConfiguration.measuredEndpoint,
            routeCategory: "speaker", sessionElapsedAtStart: 0,
            mode: .applyCandidate, directory: directory)
        let item = AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent-apply-fixture.aiff"))
        let sample = MediaClockSample(generation: id.uuidString, elapsedSeconds: 1,
                                      mediaSeconds: 1, programDate: nil, isAdvancing: false)
        let sequence = try XCTUnwrap(recorder.playback(sample: sample, item: item,
                                                       rate: 0, status: .paused))
        let snapshot = RadioExperimentSnapshot(generation: id,
            endpoint: StreamExperimentConfiguration.measuredEndpoint,
            feedTop: "Future — Artist", candidate: nil, candidateID: nil,
            selectedOccurrence: nil, history: [], trigger: .playerSample,
            songSeconds: nil, mediaSeconds: 1, programDate: nil,
            reason: "missing pair", feedStatus: "received", cacheAgeSeconds: nil)
        recorder.decision(sequence: sequence, snapshot: snapshot,
                          legacyTitle: "Legacy — Artist", publishedTitle: "Applied — Artist")
        XCTAssertTrue(recorder.finish(reason: "user").hasPrefix("Exported:"))
        let sidecarURL = directory.appendingPathComponent("kcrw-\(id.uuidString.lowercased()).decisions.json")
        let sidecar = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sidecarURL)) as? [String: Any])
        XCTAssertEqual(sidecar["mode"] as? String, "apply_candidate")
        XCTAssertEqual(sidecar["routeCategory"] as? String, "speaker")
        let decisions = try XCTUnwrap(sidecar["decisions"] as? [[String: Any]])
        XCTAssertEqual(decisions.first?["legacyTitle"] as? String, "Legacy — Artist")
        XCTAssertEqual(decisions.first?["publishedTitle"] as? String, "Applied — Artist")
    }

    func testItemTeardownExportsCompleteApplyCapture() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stream-experiment-teardown-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let recorder = try StreamExperimentRecorder(sessionID: id,
            endpoint: StreamExperimentConfiguration.measuredEndpoint,
            routeCategory: "speaker", sessionElapsedAtStart: 0,
            mode: .applyCandidate, directory: directory)
        recorder.marker("heard_song_change")
        let result = recorder.finish(reason: "item_teardown")
        XCTAssertTrue(result.hasPrefix("Exported:"), result)
        XCTAssertFalse(recorder.isRecording)
        let name = "kcrw-\(id.uuidString.lowercased())"
        let trace = try TraceReader.read(url: directory.appendingPathComponent("\(name).jsonl"))
        XCTAssertEqual(trace.last?.payload, .ended("item_teardown"))
        let sidecarURL = directory.appendingPathComponent("\(name).decisions.json")
        let sidecar = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sidecarURL)) as? [String: Any])
        XCTAssertEqual(sidecar["mode"] as? String, "apply_candidate")
        XCTAssertEqual(sidecar["routeCategory"] as? String, "speaker")
        XCTAssertEqual(recorder.finish(reason: "item_teardown"), "Capture already stopped")
    }

    func testSameItemRecorderExportsReplayableTraceAndDecisionSidecar() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stream-experiment-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let recorder = try StreamExperimentRecorder(sessionID: id,
            endpoint: StreamExperimentConfiguration.measuredEndpoint,
            routeCategory: "headphones", sessionElapsedAtStart: 0, directory: directory)
        let raw = Data("[{\"title\":\"Fixture\",\"artist\":\"Artist\",\"datetime\":\"2027-01-15T08:00:00Z\"}]".utf8)
        let entries = try StationFeed.decode(raw, station: .kcrw)
        let feedSequence = try XCTUnwrap(recorder.feed(
            RadioFeedResult(entries: entries, statusCode: 200, cacheAgeSeconds: 4,
                            failure: nil, headers: ["age": "4"], bodyBytes: raw.count),
            requestedSessionElapsed: 0))
        XCTAssertEqual(feedSequence, 1)
        let item = AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent-stream-lab-fixture.aiff"))
        let sample = MediaClockSample(generation: id.uuidString, elapsedSeconds: 0,
                                      mediaSeconds: 8, programDate: entries[0].playedAt,
                                      isAdvancing: false)
        let playbackSequence = try XCTUnwrap(recorder.playback(sample: sample, item: item,
                                                               rate: 0, status: .paused))
        let snapshot = RadioExperimentSnapshot(generation: id,
            endpoint: StreamExperimentConfiguration.measuredEndpoint,
            feedTop: "Fixture — Artist", candidate: nil, candidateID: nil,
            selectedOccurrence: nil, history: [], trigger: .playerSample,
            songSeconds: nil, mediaSeconds: 8, programDate: entries[0].playedAt,
            reason: "no matching occurrence", feedStatus: "HTTP 200", cacheAgeSeconds: 4)
        recorder.decision(sequence: playbackSequence, snapshot: snapshot, legacyTitle: "Legacy song")
        recorder.marker("heard_song_change")
        let result = recorder.finish(reason: "user")
        XCTAssertTrue(result.hasPrefix("Exported:"), result)
        let name = "kcrw-\(id.uuidString.lowercased())"
        let traceURL = directory.appendingPathComponent("\(name).jsonl")
        let sidecarURL = directory.appendingPathComponent("\(name).decisions.json")
        let trace = try TraceReader.read(url: traceURL)
        XCTAssertEqual(trace.count, 5) // start, feed, playback, marker, end
        XCTAssertEqual(trace.map(\.sequence), [0, 1, 2, 3, 4])
        let sidecar = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sidecarURL)) as? [String: Any])
        XCTAssertEqual(sidecar["mode"] as? String, "observe_only")
        XCTAssertEqual(sidecar["routeCategory"] as? String, "headphones")
        let decisions = try XCTUnwrap(sidecar["decisions"] as? [[String: Any]])
        XCTAssertEqual(decisions.first?["traceSequence"] as? Int, playbackSequence)
        XCTAssertEqual(decisions.first?["legacyTitle"] as? String, "Legacy song")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: traceURL.path))[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: sidecarURL.path))[.posixPermissions] as? Int, 0o600)
    }
}
