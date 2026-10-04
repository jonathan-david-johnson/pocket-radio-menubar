import AVFoundation
import Combine
import XCTest
import MediaPlayer
import StreamDiagnostics
import StreamSession
@testable import PocketRadio

@MainActor
private final class PlaybackFixture {
    var sessions: [RadioPlaybackSession] = []
    var endpoints: [URL] = []
    var nowPlaying: [String: Any]?
    var lyrics: LyricsResult? = LyricsResult(lines: [LyricLine(timestamp: 0, text: "First line"),
                                                    LyricLine(timestamp: 31, text: "Second line")],
                                           plain: nil, duration: 200, provenance: .exact, resourceID: "fixture-resource")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("m12-capture-\(UUID().uuidString)")
    var recorderCreations = 0
    var legacyTracklist: [TracklistEntry] = []
    var onTracklistRequest: ((RadioStation) -> Void)?
    var savedOffset: TimeInterval = 47
    var offsetReads = 0
    var offsetWrites: [Int] = []
    var lyricRequests: [String] = []
    var lyricProvider: ((String) async -> LyricsResult?)?
    var feedProvider: (() async -> RadioFeedResult)?
    var startPolling = false
    lazy var vm: PlayerViewModel = {
        var dependencies = RadioPlaybackDependencies()
        dependencies.makeItem = { [unowned self] url in
            endpoints.append(url)
            return AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent-m12-\(endpoints.count).aiff"))
        }
        dependencies.play = { _ in }
        dependencies.sample = { _, _ in }
        dependencies.fetchFeed = { [unowned self] in
            if let feedProvider { return await feedProvider() }
            XCTFail("No automatic network/feed request")
            return RadioFeedResult(entries: [], statusCode: nil, cacheAgeSeconds: nil, failure: "fixture")
        }
        dependencies.fetchTracklist = { [unowned self] station in
            onTracklistRequest?(station)
            return legacyTracklist
        }
        dependencies.lyricOffsets = RadioLyricOffsetPersistence(read: { [unowned self] _ in
            offsetReads += 1
            return savedOffset
        }, write: { [unowned self] _, value in
            offsetWrites.append(value)
            savedOffset = TimeInterval(value)
        })
        dependencies.fetchLyrics = { [unowned self] _, title, _ in
            lyricRequests.append(title)
            if let lyricProvider { return await lyricProvider(title) }
            return lyrics
        }
        dependencies.lyricDebounce = { }
        dependencies.makeSession = { [unowned self] item, endpoint, mode, fetch in
            let session = RadioPlaybackSession(item: item, endpoint: endpoint, mode: mode,
                                               fetchFeed: fetch, startPolling: startPolling,
                                               makeRecorder: { [unowned self] id, endpoint, route, elapsed, mode in
                recorderCreations += 1
                return try StreamExperimentRecorder(sessionID: id, endpoint: endpoint, routeCategory: route,
                    sessionElapsedAtStart: elapsed, mode: mode, directory: directory)
            })
            sessions.append(session)
            return session
        }
        dependencies.publishNowPlaying = { [unowned self] in nowPlaying = $0 }
        return PlayerViewModel(playbackDependencies: dependencies, startAuthentication: false)
    }()
    let station = RadioStation(id: "fixture-station", name: "KCRW Eclectic24",
                               streamURL: "https://streams.kcrw.com/e24_mp3", logoURL: nil)

    func play() {
        vm.favoriteStations = [station]
        vm.playStation(station)
    }

    func feed(_ session: RadioPlaybackSession, title: String = "Current", second: Int = 0,
              elapsed: Double = 2) throws -> Date {
        let raw = Data("[{\"title\":\"\(title)\",\"artist\":\"Artist\",\"datetime\":\"2027-01-15T08:00:\(String(format: "%02d", second))Z\"}]".utf8)
        let entries = try StationFeed.decode(raw, station: .kcrw)
        session.accept(RadioFeedResult(entries: entries, statusCode: 200, cacheAgeSeconds: nil, failure: nil),
                       requestedElapsed: elapsed - 1, receivedElapsed: elapsed)
        return try XCTUnwrap(entries[0].playedAt)
    }

    func sample(_ session: RadioPlaybackSession, date: Date?, elapsed: Double = 10) {
        session.observe(MediaClockSample(generation: session.generation.uuidString,
                                         elapsedSeconds: elapsed, mediaSeconds: elapsed,
                                         programDate: date, isAdvancing: true), currentItem: session.item)
    }
}

@MainActor
final class StreamSessionIntegrationTests: XCTestCase {
    private func station(name: String = "KCRW Eclectic24", stream: String = "https://streams.kcrw.com/e24_mp3") -> RadioStation {
        RadioStation(id: "fixture-station", name: name, streamURL: stream, logoURL: nil)
    }

    func testOrdinaryPlaybackPublishesOnlyPairedItemSelectionWithoutDebug() async throws {
        let fixture = PlaybackFixture()
        fixture.play()
        defer { if fixture.vm.isPlaying { fixture.vm.togglePlayback() } }
        XCTAssertEqual(fixture.vm.streamExperimentMode, .off)
        let session = try XCTUnwrap(fixture.sessions.first, "Ordinary playback must own a session without Debug")
        let date = try fixture.feed(session)
        XCTAssertEqual(fixture.vm.nowPlayingTitle, fixture.station.name)
        fixture.sample(session, date: date.addingTimeInterval(190))
        XCTAssertEqual(fixture.vm.nowPlayingTitle, "Current — Artist")
        XCTAssertEqual(fixture.nowPlaying?[MPMediaItemPropertyTitle] as? String, fixture.vm.nowPlayingTitle)
        let selected = try XCTUnwrap(fixture.vm.visibleTracklist.first)
        XCTAssertTrue(fixture.vm.isCurrentTracklistEntry(selected))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(fixture.vm.currentLyric, "First line")
        _ = try fixture.feed(session, title: "Next", second: 20, elapsed: 12)
        XCTAssertEqual(fixture.vm.nowPlayingTitle, "Current — Artist", "Feed receipt cannot advance")
        XCTAssertEqual(fixture.vm.visibleTracklist.first?.title, "Current")
        fixture.sample(session, date: date.addingTimeInterval(193), elapsed: 13)
        XCTAssertEqual(fixture.vm.nowPlayingTitle, "Next — Artist")
        XCTAssertEqual(fixture.recorderCreations, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    func testHistoryPillBrowsingPreservesPendingAndLoadedAlignedLyrics() async throws {
        let fixture = PlaybackFixture()
        let supported = RadioStation(id: "browse-kexp", name: "KEXP", streamURL: "https://kexp.invalid/stream", logoURL: nil)
        let unsupported = RadioStation(id: "browse-other", name: "Other radio", streamURL: "https://other.invalid/stream", logoURL: nil)
        let requested = expectation(description: "Live lyric request suspended")
        var pending: CheckedContinuation<LyricsResult?, Never>?
        fixture.lyricProvider = { _ in
            await withCheckedContinuation {
                pending = $0
                requested.fulfill()
            }
        }
        fixture.play()
        fixture.vm.favoriteStations = [fixture.station, supported, unsupported]
        defer {
            pending?.resume(returning: nil)
            if fixture.vm.isPlaying { fixture.vm.togglePlayback() }
        }
        let session = try XCTUnwrap(fixture.sessions.last)
        let date = try fixture.feed(session)
        fixture.sample(session, date: date.addingTimeInterval(190))
        let row = try XCTUnwrap(fixture.vm.visibleTracklist.first)
        await fulfillment(of: [requested], timeout: 2)

        let browseRequested = expectation(description: "Supported history uses browsing feed")
        fixture.legacyTracklist = [TracklistEntry(title: "History only", artist: "Other artist", album: nil,
                                                albumArtURL: nil, playedAt: date)]
        fixture.onTracklistRequest = { station in
            XCTAssertEqual(station.id, supported.id)
            browseRequested.fulfill()
        }
        fixture.vm.selectStream(1)
        await fulfillment(of: [browseRequested], timeout: 2)
        fixture.onTracklistRequest = { _ in XCTFail("Unsupported browsing must not poll") }
        fixture.vm.selectStream(2)
        fixture.vm.selectPodcast()
        XCTAssertTrue(fixture.vm.liveLyricSelection(for: row)?.isLoading == true)
        XCTAssertFalse(session.isStopped)
        XCTAssertTrue(fixture.vm.audioPlayer.currentItem === session.item)
        XCTAssertEqual(fixture.vm.nowPlayingTitle, "Current — Artist")

        let loaded = expectation(description: "Pending live lyrics survive browsing")
        let subscription = fixture.vm.$hasSyncedLyrics.filter { $0 }.prefix(1).sink { _ in loaded.fulfill() }
        pending?.resume(returning: fixture.lyrics)
        pending = nil
        await fulfillment(of: [loaded], timeout: 2)
        withExtendedLifetime(subscription) { }
        XCTAssertEqual(fixture.vm.alignedLyricsResult?.resourceID, "fixture-resource")
        fixture.vm.adjustLyricOffset(by: 2)
        fixture.onTracklistRequest = nil
        fixture.vm.selectStream(1)
        fixture.vm.selectStream(2)
        fixture.vm.selectPodcast()
        fixture.sample(session, date: date.addingTimeInterval(191), elapsed: 11)
        XCTAssertEqual(fixture.vm.currentLyric, "Second line")
        XCTAssertEqual(fixture.vm.liveLyricSelection(for: row)?.highlightedLineIndex, 1)
        XCTAssertEqual(fixture.vm.lyricOffset, 2)
        XCTAssertEqual(fixture.lyricRequests, ["Current"])
        XCTAssertEqual(fixture.sessions.count, 1, "Pill selection is visual, not a reconnect")
        XCTAssertEqual(fixture.offsetReads, 0)
        XCTAssertTrue(fixture.offsetWrites.isEmpty)

        // stopTracklist is private; exercise its real podcast-switch caller.
        fixture.vm.selectEpisode(UpNextEpisode(uuid: "browse-podcast", title: "Podcast",
            url: "https://podcast.invalid/episode.mp3", podcastUUID: "podcast", playedUpTo: 0, duration: 600))
        XCTAssertTrue(session.isStopped)
        XCTAssertNil(fixture.vm.alignedLyricsResult)
        XCTAssertNil(fixture.vm.liveLyricSelection(for: row))
    }

    func testPlaybackPollerSurvivesHistoryBrowsingAndRejectsCancelledGenerationReceipt() async throws {
        let fixture = PlaybackFixture()
        fixture.startPolling = true
        let firstRequested = expectation(description: "First playback feed request")
        let secondRequested = expectation(description: "Reconnect feed request")
        let firstReturned = expectation(description: "Cancelled feed returns")
        let secondReturned = expectation(description: "Current feed returns")
        var first: CheckedContinuation<RadioFeedResult, Never>?
        var second: CheckedContinuation<RadioFeedResult, Never>?
        var requests = 0
        fixture.feedProvider = {
            requests += 1
            let ordinal = requests
            let result = await withCheckedContinuation { continuation in
                if ordinal == 1 {
                    first = continuation
                    firstRequested.fulfill()
                } else {
                    XCTAssertEqual(ordinal, 2, "Only reconnect starts another playback poller")
                    second = continuation
                    secondRequested.fulfill()
                }
            }
            (ordinal == 1 ? firstReturned : secondReturned).fulfill()
            return result
        }
        fixture.play()
        defer {
            let empty = RadioFeedResult(entries: [], statusCode: 200, cacheAgeSeconds: nil, failure: nil)
            first?.resume(returning: empty)
            second?.resume(returning: empty)
            if fixture.vm.isPlaying { fixture.vm.togglePlayback() }
        }
        await fulfillment(of: [firstRequested], timeout: 2)
        let old = try XCTUnwrap(fixture.sessions.last)
        let supported = RadioStation(id: "poll-browse", name: "KEXP", streamURL: "https://kexp.invalid/stream", logoURL: nil)
        let unsupported = RadioStation(id: "poll-other", name: "Other", streamURL: "https://other.invalid/stream", logoURL: nil)
        fixture.vm.favoriteStations = [fixture.station, supported, unsupported]
        fixture.vm.selectStream(1)
        fixture.vm.selectStream(2)
        fixture.vm.selectPodcast()
        XCTAssertFalse(old.isStopped)
        XCTAssertEqual(requests, 1)
        fixture.vm.selectStream(0)
        fixture.vm.togglePlayback()
        XCTAssertTrue(old.isStopped)
        fixture.vm.togglePlayback()
        await fulfillment(of: [secondRequested], timeout: 2)
        let current = try XCTUnwrap(fixture.sessions.last)
        XCTAssertNotEqual(current.generation, old.generation)
        let entries = try StationFeed.decode(Data("""
        [{"title":"Polled","artist":"Artist","datetime":"2027-01-15T08:00:00Z"}]
        """.utf8), station: .kcrw)
        let response = RadioFeedResult(entries: entries, statusCode: 200, cacheAgeSeconds: nil, failure: nil)
        first?.resume(returning: response)
        first = nil
        await fulfillment(of: [firstReturned], timeout: 2)
        XCTAssertNil(old.snapshot.feedTop)
        XCTAssertNil(current.snapshot.feedTop)
        XCTAssertEqual(fixture.vm.nowPlayingTitle, fixture.station.name)
        second?.resume(returning: response)
        second = nil
        await fulfillment(of: [secondReturned], timeout: 2)
        XCTAssertEqual(current.snapshot.feedTop, "Polled — Artist")
        XCTAssertEqual(fixture.vm.nowPlayingTitle, fixture.station.name, "Receipt alone cannot publish")
        fixture.sample(current, date: try XCTUnwrap(entries.first?.playedAt).addingTimeInterval(190))
        XCTAssertEqual(fixture.vm.nowPlayingTitle, "Polled — Artist")
        fixture.vm.togglePlayback()
        XCTAssertTrue(current.isStopped)
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(fixture.recorderCreations, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    func testNormalReconnectCannotArmRecorderAndOnlyExplicitDebugCaptureWritesFiles() throws {
        let fixture = PlaybackFixture()
        defer {
            if fixture.vm.isPlaying { fixture.vm.togglePlayback() }
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        fixture.play()
        let ordinary = try XCTUnwrap(fixture.sessions.last)
        fixture.vm.beginStreamExperimentCapture(routeCategory: "speaker")
        XCTAssertEqual(fixture.recorderCreations, 0)
        XCTAssertThrowsError(try ordinary.beginRecording(routeCategory: "speaker"), "Off is not a capture mode")
        fixture.vm.togglePlayback()
        fixture.vm.togglePlayback()
        XCTAssertEqual(fixture.recorderCreations, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
        #if DEBUG
        for mode in [StreamExperimentMode.observeOnly, .applyCandidate] {
            fixture.vm.setStreamExperimentMode(mode)
            XCTAssertFalse(fixture.vm.isStreamExperimentCapturing)
            let before = fixture.recorderCreations
            fixture.vm.beginStreamExperimentCapture(routeCategory: "speaker")
            XCTAssertEqual(fixture.recorderCreations, before + 1)
            XCTAssertTrue(fixture.vm.isStreamExperimentCapturing)
            fixture.vm.markStreamExperiment("heard_song_change")
            fixture.vm.endStreamExperimentCapture()
            XCTAssertFalse(fixture.vm.isStreamExperimentCapturing)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
        XCTAssertEqual(files.filter { $0.hasSuffix("jsonl") }.count, 2)
        XCTAssertEqual(files.filter { $0.hasSuffix("decisions.json") }.count, 2)
        fixture.vm.togglePlayback()
        fixture.vm.togglePlayback()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted(), files.sorted())
        #else
        fixture.vm.setStreamExperimentMode(.applyCandidate)
        XCTAssertEqual(fixture.vm.streamExperimentMode, .off)
        fixture.vm.beginStreamExperimentCapture(routeCategory: "speaker")
        XCTAssertEqual(fixture.recorderCreations, 0)
        let explicitSession = RadioPlaybackSession(item: ordinary.item,
            endpoint: StreamExperimentConfiguration.measuredEndpoint, mode: .applyCandidate,
            fetchFeed: { XCTFail("No feed in this check"); return RadioFeedResult(entries: [], statusCode: nil, cacheAgeSeconds: nil, failure: nil) },
            startPolling: false)
        XCTAssertThrowsError(try explicitSession.beginRecording(routeCategory: "speaker"))
        XCTAssertThrowsError(try StreamExperimentRecorder(sessionID: UUID(),
            endpoint: StreamExperimentConfiguration.measuredEndpoint, routeCategory: "speaker",
            sessionElapsedAtStart: 0, mode: .applyCandidate, directory: fixture.directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
        explicitSession.stop()
        #endif
    }

    func testPauseReconnectSwitchRejectsLateFeedLyricsAndEndCallbacks() async throws {
        let fixture = PlaybackFixture()
        var pending: CheckedContinuation<LyricsResult?, Never>?
        fixture.lyricProvider = { _ in await withCheckedContinuation { pending = $0 } }
        fixture.play()
        defer { if fixture.vm.isPlaying { fixture.vm.togglePlayback() } }
        let old = try XCTUnwrap(fixture.sessions.last)
        let date = try fixture.feed(old)
        fixture.sample(old, date: date.addingTimeInterval(190))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNotNil(pending)
        fixture.vm.togglePlayback()
        XCTAssertTrue(old.isStopped)
        XCTAssertNil(fixture.vm.audioPlayer.currentItem)
        XCTAssertEqual(fixture.vm.nowPlayingTitle, fixture.station.name)
        XCTAssertFalse(fixture.vm.hasSyncedLyrics)
        fixture.vm.loadLyrics(for: TracklistEntry(title: "Wrong feed top", artist: "Artist", album: nil, albumArtURL: nil, playedAt: date))
        fixture.vm.togglePlayback()
        let resumed = try XCTUnwrap(fixture.sessions.last)
        XCTAssertNotEqual(old.generation, resumed.generation)
        XCTAssertEqual(fixture.vm.nowPlayingTitle, fixture.station.name, "Reconnect needs a new clock")
        _ = try fixture.feed(old, title: "Late", elapsed: 12)
        fixture.sample(old, date: date.addingTimeInterval(193), elapsed: 13)
        pending?.resume(returning: fixture.lyrics)
        pending = nil
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(fixture.vm.nowPlayingTitle, fixture.station.name)
        XCTAssertFalse(fixture.vm.hasSyncedLyrics)
        XCTAssertEqual(fixture.lyricRequests, ["Current"])

        // The end notification queued by an old item must not stop its replacement.
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: resumed.item)
        let other = RadioStation(id: "other", name: "Other radio", streamURL: "https://other.invalid/stream", logoURL: nil)
        fixture.vm.playStation(other)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(fixture.vm.isPlaying, "Old item's queued end callback must not tear down new source")
        XCTAssertEqual(fixture.vm.nowPlayingTitle, other.name)
        XCTAssertNil(fixture.vm.streamExperimentSnapshot)
    }

    func testBarAndLiveDetailShareResourceClockAndCorrectionWhileHistoryIsIndependent() async throws {
        let fixture = PlaybackFixture()
        fixture.play()
        defer { if fixture.vm.isPlaying { fixture.vm.togglePlayback() } }
        let session = try XCTUnwrap(fixture.sessions.last)
        let date = try fixture.feed(session)
        fixture.sample(session, date: date.addingTimeInterval(190))
        for _ in 0..<20 { await Task.yield() }
        let row = try XCTUnwrap(fixture.vm.visibleTracklist.first)
        let live = try XCTUnwrap(fixture.vm.liveLyricSelection(for: row))
        XCTAssertEqual(live.result?.lines.map(\.text), ["First line", "Second line"])
        XCTAssertEqual(live.result?.provenance, .exact)
        XCTAssertEqual(live.result?.resourceID, "fixture-resource")
        XCTAssertEqual(live.highlightedLineIndex, fixture.vm.currentLyricLineIndex)
        XCTAssertEqual(fixture.vm.currentLyric, "First line")
        fixture.vm.adjustLyricOffset(by: 2)
        XCTAssertEqual(fixture.vm.currentLyric, "Second line")
        XCTAssertEqual(fixture.vm.liveLyricSelection(for: row)?.highlightedLineIndex, 1)
        XCTAssertEqual(session.snapshot.songSeconds, 30, "Correction must not change +160 clock")
        let historical = TracklistEntry(title: row.title, artist: row.artist, album: nil, albumArtURL: nil,
                                        playedAt: date.addingTimeInterval(-60))
        XCTAssertNil(fixture.vm.liveLyricSelection(for: historical))
        fixture.vm.loadLyrics(for: historical)
        XCTAssertEqual(fixture.vm.currentLyric, "Second line")
        XCTAssertEqual(fixture.lyricRequests, ["Current"], "Browsing cannot replace the live lyric resource")
        _ = try fixture.feed(session, title: "Next", second: 20, elapsed: 12)
        fixture.sample(session, date: date.addingTimeInterval(193), elapsed: 13)
        XCTAssertEqual(fixture.vm.lyricOffset, 0)
        XCTAssertNil(fixture.vm.alignedLyricsResult, "New occurrence must not display the old resource")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(fixture.vm.liveLyricSelection(for: row), "Old detail becomes historical, never highlighted")
        fixture.vm.togglePlayback()
        XCTAssertNil(fixture.vm.alignedLyricsResult)
    }

    func testSameSongRevisionAndLaterOccurrenceResetResourceAndRejectLateLookup() async throws {
        let fixture = PlaybackFixture()
        fixture.play()
        defer { if fixture.vm.isPlaying { fixture.vm.togglePlayback() } }
        let session = try XCTUnwrap(fixture.sessions.last)
        let date = try fixture.feed(session)
        let firstLoaded = expectation(description: "First resource loaded")
        let firstSubscription = fixture.vm.$hasSyncedLyrics.filter { $0 }.prefix(1).sink { _ in firstLoaded.fulfill() }
        fixture.sample(session, date: date.addingTimeInterval(190))
        await fulfillment(of: [firstLoaded], timeout: 2)
        withExtendedLifetime(firstSubscription) { }
        let originalRow = try XCTUnwrap(fixture.vm.visibleTracklist.first)
        let originalOccurrence = try XCTUnwrap(session.snapshot.selectedOccurrence)
        fixture.vm.adjustLyricOffset(by: 2)

        var pendingRevision: CheckedContinuation<LyricsResult?, Never>?
        defer { pendingRevision?.resume(returning: nil) }
        let revisionRequested = expectation(description: "Revised occurrence lookup suspended")
        let revisionReturned = expectation(description: "Cancelled revision lookup returned")
        fixture.lyricProvider = { _ in
            let result = await withCheckedContinuation {
                pendingRevision = $0
                revisionRequested.fulfill()
            }
            revisionReturned.fulfill()
            return result
        }
        let revised = try StationFeed.decode(Data("""
        [{"title":"Current","artist":"Artist","album":"Revised album","datetime":"2027-01-15T08:00:00Z"}]
        """.utf8), station: .kcrw)
        session.accept(RadioFeedResult(entries: revised, statusCode: 200, cacheAgeSeconds: nil, failure: nil),
                       requestedElapsed: 11, receivedElapsed: 12)
        XCTAssertEqual(fixture.vm.lyricOffset, 2, "Feed revision cannot republish before a player sample")
        fixture.sample(session, date: date.addingTimeInterval(193), elapsed: 13)
        XCTAssertEqual(session.snapshot.selectedOccurrence?.id, originalOccurrence.id)
        XCTAssertGreaterThan(try XCTUnwrap(session.snapshot.selectedOccurrence?.revision), originalOccurrence.revision)
        XCTAssertEqual(fixture.vm.lyricOffset, 0)
        XCTAssertNil(fixture.vm.alignedLyricsResult)
        await fulfillment(of: [revisionRequested], timeout: 2)

        fixture.lyricProvider = nil
        fixture.lyrics = LyricsResult(lines: [LyricLine(timestamp: 0, text: "Later recording")], plain: nil,
                                      duration: 200, provenance: .exact, resourceID: "later-resource")
        let later = try StationFeed.decode(Data("""
        [{"title":"Current","artist":"Artist","datetime":"2027-01-15T08:05:00Z"}]
        """.utf8), station: .kcrw)
        session.accept(RadioFeedResult(entries: later, statusCode: 200, cacheAgeSeconds: nil, failure: nil),
                       requestedElapsed: 308, receivedElapsed: 309)
        let laterLoaded = expectation(description: "Later occurrence resource loaded")
        let laterSubscription = fixture.vm.$hasSyncedLyrics.filter { $0 }.prefix(1).sink { _ in laterLoaded.fulfill() }
        fixture.sample(session, date: date.addingTimeInterval(490), elapsed: 310)
        await fulfillment(of: [laterLoaded], timeout: 2)
        withExtendedLifetime(laterSubscription) { }
        XCTAssertNotEqual(session.snapshot.selectedOccurrence?.id, originalOccurrence.id)
        XCTAssertNil(fixture.vm.liveLyricSelection(for: originalRow), "Same text is not the same occurrence")
        XCTAssertEqual(fixture.vm.alignedLyricsResult?.resourceID, "later-resource")
        XCTAssertEqual(fixture.vm.currentLyric, "Later recording")
        pendingRevision?.resume(returning: LyricsResult(lines: [LyricLine(timestamp: 0, text: "Stale revision")],
            plain: nil, duration: 200, provenance: .exact, resourceID: "stale-revision"))
        pendingRevision = nil
        await fulfillment(of: [revisionReturned], timeout: 2)
        XCTAssertEqual(fixture.vm.alignedLyricsResult?.resourceID, "later-resource")
        XCTAssertEqual(fixture.vm.currentLyric, "Later recording")
        XCTAssertEqual(fixture.lyricRequests, ["Current", "Current", "Current"])
        XCTAssertEqual(fixture.vm.lyricOffset, 0)
        XCTAssertEqual(fixture.offsetReads, 0)
        XCTAssertTrue(fixture.offsetWrites.isEmpty)
    }

    func testStalledClockFreezesLyricsAndDiscontinuityFailsClosedUntilNewPair() async throws {
        let fixture = PlaybackFixture()
        fixture.play()
        defer { if fixture.vm.isPlaying { fixture.vm.togglePlayback() } }
        let session = try XCTUnwrap(fixture.sessions.last)
        let date = try fixture.feed(session)
        let loaded = expectation(description: "Initial timed resource loaded")
        let subscription = fixture.vm.$hasSyncedLyrics.filter { $0 }.prefix(1).sink { _ in loaded.fulfill() }
        fixture.sample(session, date: date.addingTimeInterval(190))
        await fulfillment(of: [loaded], timeout: 2)
        withExtendedLifetime(subscription) { }
        let row = try XCTUnwrap(fixture.vm.visibleTracklist.first)
        fixture.vm.adjustLyricOffset(by: 2)
        for elapsed in [11.0, 15.0] {
            session.observe(MediaClockSample(generation: session.generation.uuidString, elapsedSeconds: elapsed,
                mediaSeconds: 10, programDate: date.addingTimeInterval(190), isAdvancing: false), currentItem: session.item)
            XCTAssertEqual(session.snapshot.songSeconds, 30)
            XCTAssertEqual(fixture.vm.currentLyric, "Second line", "Wall time must not advance stalled lyrics")
            XCTAssertEqual(fixture.vm.liveLyricSelection(for: row)?.highlightedLineIndex, 1)
            XCTAssertEqual(fixture.vm.lyricOffset, 2)
        }
        // Same generation but another item, or same item but another generation, cannot publish.
        let otherItem = AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent-review-old-item.aiff"))
        for (generation, item) in [(session.generation.uuidString, otherItem), (UUID().uuidString, session.item)] {
            session.observe(MediaClockSample(generation: generation, elapsedSeconds: 16, mediaSeconds: 16,
                programDate: date.addingTimeInterval(206), isAdvancing: true), currentItem: item)
            XCTAssertEqual(fixture.vm.currentLyric, "Second line")
            XCTAssertEqual(fixture.vm.alignedLyricsResult?.resourceID, "fixture-resource")
        }
        session.observe(MediaClockSample(generation: session.generation.uuidString, elapsedSeconds: 16,
            mediaSeconds: 16, programDate: date.addingTimeInterval(206), isAdvancing: true), currentItem: session.item)
        XCTAssertNil(session.snapshot.candidate)
        XCTAssertEqual(fixture.vm.nowPlayingTitle, fixture.station.name)
        XCTAssertEqual(fixture.nowPlaying?[MPMediaItemPropertyTitle] as? String, fixture.station.name)
        XCTAssertTrue(fixture.vm.alignmentUnavailableReason?.contains("correlationDiscontinuity") == true)
        XCTAssertNil(fixture.vm.alignedLyricsResult)
        XCTAssertNil(fixture.vm.liveLyricSelection(for: row))
        XCTAssertFalse(fixture.vm.hasSyncedLyrics)
        XCTAssertEqual(fixture.vm.currentLyric, "")
        XCTAssertEqual(fixture.vm.lyricOffset, 0)

        let recovered = expectation(description: "New valid pair reloads live resource")
        let recoverySubscription = fixture.vm.$hasSyncedLyrics.filter { $0 }.prefix(1).sink { _ in recovered.fulfill() }
        fixture.sample(session, date: date.addingTimeInterval(197), elapsed: 17)
        await fulfillment(of: [recovered], timeout: 2)
        withExtendedLifetime(recoverySubscription) { }
        XCTAssertNil(fixture.vm.alignmentUnavailableReason)
        XCTAssertEqual(fixture.vm.nowPlayingTitle, "Current — Artist")
        XCTAssertEqual(fixture.vm.liveLyricSelection(for: row)?.highlightedLineIndex, 1,
                       "The original open detail is LIVE again after valid pairing")
        XCTAssertEqual(fixture.lyricRequests, ["Current", "Current"])
        XCTAssertEqual(fixture.offsetReads, 0)
        XCTAssertTrue(fixture.offsetWrites.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    func testEqualTimestampResourceHighlightsTheSameLineShownInTheBar() async throws {
        let fixture = PlaybackFixture()
        fixture.lyrics = LyricsResult(lines: [
            LyricLine(timestamp: 0, text: "Intro"),
            LyricLine(timestamp: 30, text: "First simultaneous line"),
            LyricLine(timestamp: 30, text: "Second simultaneous line")
        ], plain: nil, duration: 200, provenance: .exact, resourceID: "equal-timestamp-resource")
        XCTAssertTrue(try XCTUnwrap(fixture.lyrics).isExactSynced,
                      "Equal timestamps are accepted by the production resource validity gate")
        fixture.play()
        defer { if fixture.vm.isPlaying { fixture.vm.togglePlayback() } }
        let session = try XCTUnwrap(fixture.sessions.last)
        let date = try fixture.feed(session)
        let loaded = expectation(description: "Equal-timestamp resource loaded")
        let subscription = fixture.vm.$hasSyncedLyrics.filter { $0 }.prefix(1).sink { _ in loaded.fulfill() }
        fixture.sample(session, date: date.addingTimeInterval(190))
        await fulfillment(of: [loaded], timeout: 2)
        withExtendedLifetime(subscription) { }
        let row = try XCTUnwrap(fixture.vm.visibleTracklist.first)
        let live = try XCTUnwrap(fixture.vm.liveLyricSelection(for: row))
        let result = try XCTUnwrap(live.result)
        let index = try XCTUnwrap(live.highlightedLineIndex)
        XCTAssertTrue(result.lines.indices.contains(index))
        XCTAssertEqual(result.lines[index].text, fixture.vm.currentLyric,
                       "LIVE detail must highlight the exact resource line displayed in the menubar")
    }

    func testFuzzyOrInvalidTimingNeverHighlightsAlignedLyrics() async throws {
        for result in [
            nil,
            LyricsResult(lines: [LyricLine(timestamp: 0, text: "Fuzzy")], plain: "Text", provenance: .search),
            LyricsResult(lines: [LyricLine(timestamp: .nan, text: "Invalid")], plain: "Text", provenance: .exact),
            LyricsResult(lines: [], plain: "Untimed", provenance: .exact)
        ] as [LyricsResult?] {
            let fixture = PlaybackFixture()
            fixture.lyrics = result
            fixture.play()
            let session = try XCTUnwrap(fixture.sessions.last)
            let date = try fixture.feed(session)
            fixture.sample(session, date: date.addingTimeInterval(190))
            for _ in 0..<20 { await Task.yield() }
            let row = try XCTUnwrap(fixture.vm.visibleTracklist.first)
            XCTAssertFalse(fixture.vm.hasSyncedLyrics)
            XCTAssertNil(fixture.vm.liveLyricSelection(for: row)?.highlightedLineIndex)
            fixture.vm.togglePlayback()
        }
    }

    func testUnavailableAlignmentIsVisibleAndNeverFallsBackToFeedTopOrSavedOffsets() async throws {
        let fixture = PlaybackFixture()
        fixture.legacyTracklist = [TracklistEntry(title: "False top", artist: "Artist", album: nil, albumArtURL: nil, playedAt: Date())]
        fixture.play()
        defer { if fixture.vm.isPlaying { fixture.vm.togglePlayback() } }
        XCTAssertTrue(fixture.vm.alignmentUnavailableReason?.lowercased().contains("alignment unavailable") == true)
        for _ in 0..<20 { await Task.yield() }
        let session = try XCTUnwrap(fixture.sessions.last)
        fixture.sample(session, date: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertNotNil(fixture.vm.alignmentUnavailableReason, "Missing history is unavailable")
        XCTAssertEqual(fixture.vm.nowPlayingTitle, fixture.station.name)
        let date = try fixture.feed(session, elapsed: 12)
        fixture.sample(session, date: nil, elapsed: 13)
        XCTAssertTrue(fixture.vm.alignmentUnavailableReason?.lowercased().contains("alignment unavailable") == true)
        XCTAssertEqual(fixture.vm.nowPlayingTitle, fixture.station.name)
        fixture.sample(session, date: date.addingTimeInterval(190), elapsed: 14)
        XCTAssertNil(fixture.vm.alignmentUnavailableReason)
        for _ in 0..<20 { await Task.yield() }
        fixture.vm.adjustLyricOffset(by: 5)
        XCTAssertEqual(fixture.vm.lyricOffset, 5)
        fixture.vm.togglePlayback()
        fixture.vm.adjustLyricOffset(by: 5)
        fixture.vm.loadLyrics(for: fixture.legacyTracklist[0])
        XCTAssertEqual(fixture.offsetReads, 0)
        XCTAssertTrue(fixture.offsetWrites.isEmpty)
        XCTAssertEqual(fixture.savedOffset, 47)
        XCTAssertEqual(fixture.vm.lyricOffset, 0)
        XCTAssertNotNil(fixture.vm.alignmentUnavailableReason)
    }

    func testUnsupportedRadioPodcastAndObserveRetainLegacyPublication() async throws {
        let fixture = PlaybackFixture()
        let other = RadioStation(id: "other", name: "Other radio", streamURL: "https://other.invalid/stream", logoURL: nil)
        fixture.legacyTracklist = [TracklistEntry(title: "Legacy", artist: "Artist", album: nil, albumArtURL: nil, playedAt: Date().addingTimeInterval(-30))]
        fixture.vm.playStation(other)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(fixture.sessions.isEmpty)
        XCTAssertFalse(fixture.vm.usesAlignedRadioPlayback)
        XCTAssertNil(fixture.vm.alignmentUnavailableReason)
        XCTAssertEqual(fixture.endpoints.last?.absoluteString, other.streamURL)
        fixture.vm.loadLyrics(for: fixture.legacyTracklist[0])
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(fixture.vm.lyricOffset, 47)
        XCTAssertGreaterThan(fixture.offsetReads, 0)
        let episode = UpNextEpisode(uuid: "episode", title: "Podcast", url: "https://podcast.invalid/episode.mp3",
                                    podcastUUID: "podcast", playedUpTo: 0, duration: 600)
        fixture.vm.selectEpisode(episode)
        XCTAssertEqual(fixture.endpoints.last?.absoluteString, episode.url)
        XCTAssertEqual(fixture.vm.nowPlayingTitle, episode.title)
        XCTAssertFalse(fixture.vm.usesAlignedRadioPlayback)
        fixture.vm.togglePlayback()
        #if DEBUG
        fixture.vm.setStreamExperimentMode(.observeOnly)
        fixture.play()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(fixture.vm.nowPlayingTitle, "Legacy — Artist")
        let session = try XCTUnwrap(fixture.sessions.last)
        let date = try fixture.feed(session)
        fixture.sample(session, date: date.addingTimeInterval(190))
        XCTAssertEqual(fixture.vm.nowPlayingTitle, "Legacy — Artist", "Observe never publishes aligned candidate")
        XCTAssertFalse(fixture.vm.isStreamExperimentCapturing)
        fixture.vm.togglePlayback()
        #endif
    }

    func testEndpointOverrideIsSessionOnlyAndExact() {
        let supported = station()
        XCTAssertTrue(StreamExperimentConfiguration.isEligible(supported))
        XCTAssertEqual(StreamExperimentConfiguration.resolvedURL(for: supported, mode: .off),
                       StreamExperimentConfiguration.measuredEndpoint)
        XCTAssertEqual(StreamExperimentConfiguration.resolvedURL(for: supported, mode: .observeOnly),
                       StreamExperimentConfiguration.measuredEndpoint)
        XCTAssertEqual(StreamExperimentConfiguration.resolvedURL(for: supported, mode: .applyCandidate),
                       StreamExperimentConfiguration.measuredEndpoint)
        XCTAssertEqual(supported.streamURL, "https://streams.kcrw.com/e24_mp3", "Never rewrite the station")
        let curatedAAC = station(name: "KCRW Eclectic 24 (AAC)",
                                 stream: "https://streams.kcrw.com/e24_aac")
        XCTAssertTrue(StreamExperimentConfiguration.isEligible(curatedAAC))
        XCTAssertEqual(StreamExperimentConfiguration.resolvedURL(for: curatedAAC, mode: .off),
                       StreamExperimentConfiguration.measuredEndpoint)
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
