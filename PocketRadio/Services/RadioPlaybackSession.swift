import AVFoundation
import Foundation
import StreamDiagnostics
import StreamSession

/// Same-item decision and retained evidence. Only a player-sample decision may
/// publish in Apply mode; a feed callback may update history but not the title.
struct RadioExperimentSnapshot {
    let generation: UUID
    let endpoint: URL
    let feedTop: String?
    let candidate: String?
    let candidateID: OccurrenceID?
    let selectedOccurrence: Occurrence?
    let history: [Occurrence]
    let trigger: DecisionTrigger?
    let songSeconds: Double?
    let mediaSeconds: Double?
    let programDate: Date?
    let reason: String
    let feedStatus: String
    let cacheAgeSeconds: Double?
}

/// Fail-closed publication gate shared by the app and synthetic tests. Feed
/// receipt cannot publish, even when it changes the top row or corrects history.
struct RadioApplySelection {
    let occurrence: Occurrence
    let songSeconds: Double
    let title: String

    init?(snapshot: RadioExperimentSnapshot) {
        guard snapshot.trigger == .playerSample,
              snapshot.programDate != nil,
              let occurrence = snapshot.selectedOccurrence,
              occurrence.id == snapshot.candidateID,
              occurrence.kind == "trackplay",
              let title = occurrence.title, !title.isEmpty,
              let artist = occurrence.artist, !artist.isEmpty,
              let seconds = snapshot.songSeconds, seconds.isFinite, seconds >= 0 else { return nil }
        self.occurrence = occurrence
        songSeconds = seconds
        self.title = "\(title) — \(artist)"
    }
}

/// Main-actor owner for the experimental AVPlayerItem. The poller belongs to
/// playback, not to a popover or the station being browsed.
@MainActor
final class RadioPlaybackSession {
    let generation = UUID()
    let item: AVPlayerItem
    let endpoint: URL
    let mode: StreamExperimentMode
    var onSnapshot: ((RadioExperimentSnapshot) -> Void)?
    var onRecorderStatus: ((String) -> Void)?
    var legacyTitle: (() -> String)?
    var publishedTitle: (() -> String)?

    private let fetchFeed: @MainActor () async -> RadioFeedResult
    private var recorder: StreamExperimentRecorder?
    private let startedUptime = ProcessInfo.processInfo.systemUptime
    private var state = SessionState(historyPolicy: StreamExperimentConfiguration.historyPolicy,
                                     selectionPolicy: StreamExperimentConfiguration.selectionPolicy,
                                     clockPolicy: StreamExperimentConfiguration.clockPolicy)
    private var pollTask: Task<Void, Never>?
    private var requestID = 0
    private var latestFeedTop: String?
    private(set) var snapshot: RadioExperimentSnapshot
    private(set) var isStopped = false

    init(item: AVPlayerItem, endpoint: URL,
         mode: StreamExperimentMode = .observeOnly,
         fetchFeed: @escaping @MainActor () async -> RadioFeedResult,
         startPolling: Bool = true) {
        self.item = item
        self.endpoint = endpoint
        self.mode = mode
        self.fetchFeed = fetchFeed
        snapshot = RadioExperimentSnapshot(generation: generation, endpoint: endpoint,
                                           feedTop: nil, candidate: nil, candidateID: nil,
                                           selectedOccurrence: nil, history: [], trigger: nil,
                                           songSeconds: nil, mediaSeconds: nil, programDate: nil,
                                           reason: "waiting for paired player clock and feed",
                                           feedStatus: "not requested", cacheAgeSeconds: nil)
        if startPolling { startPoller() }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        pollTask?.cancel()
        pollTask = nil
        finishRecording(reason: "item_teardown")
        onSnapshot = nil
        onRecorderStatus = nil
        legacyTitle = nil
        publishedTitle = nil
    }

    var isRecording: Bool { recorder?.isRecording == true }

    func beginRecording(routeCategory: String) throws {
        guard !isStopped, recorder == nil else { throw TraceError.invalid("capture already started or item stopped") }
        recorder = try StreamExperimentRecorder(sessionID: generation, endpoint: endpoint,
                                                routeCategory: routeCategory,
                                                sessionElapsedAtStart: elapsedNow, mode: mode)
        onRecorderStatus?("Capturing same-player observations (\(routeCategory))")
    }

    func finishRecording(reason: String = "user") {
        guard let recorder else { return }
        self.recorder = nil
        onRecorderStatus?(recorder.finish(reason: reason))
    }

    func mark(_ name: String) {
        guard !isStopped else { return }
        recorder?.marker(name)
    }

    private var elapsedNow: Double { ProcessInfo.processInfo.systemUptime - startedUptime }

    func sample(currentItem: AVPlayerItem?, rate: Float, status: AVPlayer.TimeControlStatus) {
        guard !isStopped, currentItem === item else { return }
        let media = item.currentTime().seconds
        let sample = MediaClockSample(generation: generation.uuidString, elapsedSeconds: elapsedNow,
                                      mediaSeconds: media.isFinite ? media : nil,
                                      programDate: item.currentDate(),
                                      isAdvancing: rate > 0 && status == .playing)
        observe(sample, currentItem: item)
        let sequence = recorder?.playback(sample: sample, item: item, rate: rate, status: status)
        recorder?.decision(sequence: sequence, snapshot: snapshot,
                           legacyTitle: legacyTitle?() ?? "",
                           publishedTitle: publishedTitle?())
    }

    func observe(_ sample: MediaClockSample, currentItem: AVPlayerItem?) {
        guard !isStopped, currentItem === item, sample.generation == generation.uuidString else { return }
        let decision = state.observePlayer(sample)
        publish(decision, feedStatus: snapshot.feedStatus, cacheAge: snapshot.cacheAgeSeconds)
    }

    /// Testable feed-injection boundary. A cancelled or late prior generation is
    /// discarded before it can reach the core or UI.
    func accept(_ result: RadioFeedResult, requestedElapsed: Double,
                receivedElapsed: Double) {
        guard !isStopped else { return }
        let recordedSequence = recorder?.feed(result, requestedSessionElapsed: requestedElapsed)
        requestID += 1
        do {
            let update: FeedMutation
            if let failure = result.failure {
                update = try state.failFeed(requestID: requestID,
                                            requestedElapsedSeconds: requestedElapsed,
                                            receivedElapsedSeconds: receivedElapsed,
                                            reason: failure)
            } else {
                let entries = result.entries.map {
                    OccurrenceInput(station: "kcrw", providerID: $0.providerID, kind: $0.kind,
                                    title: $0.title, artist: $0.artist, album: $0.album,
                                    artworkURL: $0.artworkURL, playedAt: $0.playedAt)
                }
                update = try state.receiveFeed(requestID: requestID,
                                               requestedElapsedSeconds: requestedElapsed,
                                               receivedElapsedSeconds: receivedElapsed,
                                               entries: entries)
            }
            if result.failure == nil {
                latestFeedTop = result.entries.first.map { entry in
                    entry.title.map { "\($0) — \(entry.artist ?? "")" } ?? entry.kind
                }
            }
            let status: String
            switch update.update {
            case .accepted: status = "received \(result.entries.count) entries"
            case .empty: status = "empty response"
            case .failed(let reason): status = reason
            case .ignoredOutOfOrder: status = "out-of-order response ignored"
            case .ambiguousCorrection: status = "ambiguous correction"
            }
            // Receiving a row changes available evidence, not the player's
            // position. Only the next paired sample may advance the candidate.
            snapshot = RadioExperimentSnapshot(generation: generation, endpoint: endpoint,
                                               feedTop: topDescription,
                                               candidate: snapshot.candidate,
                                               candidateID: snapshot.candidateID,
                                               selectedOccurrence: snapshot.selectedOccurrence,
                                               history: state.history.occurrences,
                                               trigger: .feedUpdate,
                                               songSeconds: snapshot.songSeconds,
                                               mediaSeconds: snapshot.mediaSeconds,
                                               programDate: snapshot.programDate,
                                               reason: snapshot.reason,
                                               feedStatus: status,
                                               cacheAgeSeconds: result.cacheAgeSeconds)
            onSnapshot?(snapshot)
            recorder?.decision(sequence: recordedSequence, snapshot: snapshot,
                               legacyTitle: legacyTitle?() ?? "",
                               publishedTitle: publishedTitle?())
        } catch {
            snapshot = RadioExperimentSnapshot(generation: generation, endpoint: endpoint,
                                               feedTop: topDescription, candidate: nil,
                                               candidateID: nil, selectedOccurrence: nil,
                                               history: state.history.occurrences, trigger: .feedUpdate,
                                               songSeconds: nil, mediaSeconds: nil, programDate: nil,
                                               reason: "invalid feed timing or policy",
                                               feedStatus: "rejected", cacheAgeSeconds: nil)
            onSnapshot?(snapshot)
            recorder?.decision(sequence: recordedSequence, snapshot: snapshot,
                               legacyTitle: legacyTitle?() ?? "",
                               publishedTitle: publishedTitle?())
        }
    }

    private var topDescription: String? { latestFeedTop }

    private func publish(_ decision: SessionDecision, feedStatus: String, cacheAge: Double?) {
        let clock: ValidMediaClock?
        if case .valid(let valid)? = decision.clock { clock = valid } else { clock = nil }
        let selection: OccurrenceSelection?
        let reason: String
        switch decision.selection {
        case .selected(let current):
            selection = current
            reason = "estimated +160s; not verified audible"
        case .unavailable(let why):
            selection = nil
            if case .invalid(let clockReason)? = decision.clock {
                reason = "player clock: \(clockReason.rawValue)"
            } else {
                reason = "alignment unavailable: \(why.rawValue)"
            }
        }
        let candidate = selection.map { current in
            current.occurrence.title.map { "\($0) — \(current.occurrence.artist ?? "")" }
                ?? current.occurrence.kind
        }
        snapshot = RadioExperimentSnapshot(generation: generation, endpoint: endpoint,
                                           feedTop: topDescription,
                                           candidate: candidate,
                                           candidateID: selection?.occurrence.id,
                                           selectedOccurrence: selection?.occurrence,
                                           history: state.history.occurrences,
                                           trigger: decision.trigger,
                                           songSeconds: selection?.songSeconds,
                                           mediaSeconds: clock?.mediaSeconds,
                                           programDate: clock?.programDate,
                                           reason: reason, feedStatus: feedStatus,
                                           cacheAgeSeconds: cacheAge)
        onSnapshot?(snapshot)
    }

    private func startPoller() {
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled, !self.isStopped {
                let requested = ProcessInfo.processInfo.systemUptime - self.startedUptime
                let result = await self.fetchFeed()
                guard !Task.isCancelled, !self.isStopped else { return }
                let received = ProcessInfo.processInfo.systemUptime - self.startedUptime
                self.accept(result, requestedElapsed: requested, receivedElapsed: received)
                do { try await Task.sleep(nanoseconds: 30_000_000_000) }
                catch { return }
            }
        }
    }
}
