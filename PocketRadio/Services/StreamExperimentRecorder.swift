import AVFoundation
import Darwin
import Foundation
import StreamDiagnostics
import StreamSession

private struct StreamDecisionRecord: Encodable {
    let traceSequence: Int
    let elapsedSeconds: Double
    let legacyTitle: String
    let publishedTitle: String?
    let feedTop: String?
    let candidate: String?
    let occurrenceID: String?
    let mediaSeconds: Double?
    let programDateMilliseconds: Int64?
    let estimatedSongSeconds: Double?
    let reason: String
    let feedStatus: String
}

private struct StreamDecisionSidecar: Encodable {
    let schemaVersion: Int
    let sessionID: UUID
    let mode: String
    let routeCategory: String
    let feedToProgramOffset: Double
    let maxSelectedAge: Double
    let maxFeedSilence: Double
    let decisions: [StreamDecisionRecord]
}

/// Explicit same-item capture. TraceWriter supplies exclusive 0600 files,
/// redaction, size limits, and session-v1 validation. Sidecar never stores lyrics.
@MainActor
final class StreamExperimentRecorder {
    private let writer: TraceWriter
    private let traceURL: URL
    private let sidecarURL: URL
    private let sessionID: UUID
    private let routeCategory: String
    private let mode: StreamExperimentMode
    private let startUptime = ProcessInfo.processInfo.systemUptime
    private let sessionElapsedAtStart: Double
    private var sequence = 0
    private var decisions: [StreamDecisionRecord] = []
    private var finished = false
    private var failed = false

    init(sessionID: UUID, endpoint: URL, routeCategory: String,
         sessionElapsedAtStart: Double, mode: StreamExperimentMode = .observeOnly,
         directory: URL? = nil) throws {
        guard ["speaker", "headphones", "bluetooth", "other", "unrecorded"].contains(routeCategory),
              sessionElapsedAtStart.isFinite, sessionElapsedAtStart >= 0 else {
            throw TraceError.invalid("invalid route category or capture time")
        }
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                        in: .userDomainMask)[0]
            .appendingPathComponent("PocketRadio/StreamExperiment", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let name = "kcrw-\(sessionID.uuidString.lowercased())"
        let trace = base.appendingPathComponent("\(name).jsonl")
        self.writer = try TraceWriter(url: trace)
        self.traceURL = trace
        self.sidecarURL = base.appendingPathComponent("\(name).decisions.json")
        self.sessionID = sessionID
        self.routeCategory = routeCategory
        self.mode = mode
        self.sessionElapsedAtStart = sessionElapsedAtStart
        do {
            try append(.started(SessionInfo(station: "kcrw", streamURL: endpoint.absoluteString,
                                            feedURL: StreamExperimentConfiguration.feedEndpoint.absoluteString,
                                            muted: false)))
        } catch {
            failed = true
            try? writer.close()
            throw error
        }
    }

    var isRecording: Bool { !finished && !failed }

    func marker(_ name: String) {
        guard ["heard_song_change", "lyric_landmark", "wrong_title_or_line",
               "speech_or_commercial"].contains(name) else { return }
        tryAppend(.marker(name))
    }

    func feed(_ result: RadioFeedResult, requestedSessionElapsed: Double) -> Int? {
        let requested = max(0, requestedSessionElapsed - sessionElapsedAtStart)
        let safeHeaders = result.headers.mapValues(TracePrivacy.metadata)
        let observation = FeedObservation(requestID: sequence,
                                          requestedElapsedSeconds: requested,
                                          statusCode: result.statusCode,
                                          headers: safeHeaders,
                                          bodyBytes: result.bodyBytes,
                                          entries: result.entries,
                                          failure: result.failure.map(TracePrivacy.metadata))
        return tryAppend(.feed(observation))
    }

    func playback(sample: MediaClockSample, item: AVPlayerItem, rate: Float,
                  status: AVPlayer.TimeControlStatus) -> Int? {
        let statusText: String
        switch status {
        case .playing: statusText = "playing"
        case .paused: statusText = "paused"
        case .waitingToPlayAtSpecifiedRate: statusText = "waiting"
        @unknown default: statusText = "unknown"
        }
        let itemStatus: String
        switch item.status {
        case .readyToPlay: itemStatus = "ready"
        case .failed: itemStatus = "failed"
        case .unknown: itemStatus = "unknown"
        @unknown default: itemStatus = "unknown"
        }
        let ranges = item.loadedTimeRanges.compactMap { value -> MediaRange? in
            let range = value.timeRangeValue
            let start = range.start.seconds, duration = range.duration.seconds
            guard start.isFinite, duration.isFinite else { return nil }
            return MediaRange(start: start, duration: duration)
        }
        return tryAppend(.playback(PlaybackObservation(
            mediaSeconds: sample.mediaSeconds, programDate: sample.programDate,
            rate: Double(rate), timeControlStatus: statusText, itemStatus: itemStatus,
            waitingReason: nil, loadedRanges: ranges, seekableRanges: [],
            bufferEmpty: item.isPlaybackBufferEmpty,
            likelyToKeepUp: item.isPlaybackLikelyToKeepUp
        )))
    }

    func decision(sequence: Int?, snapshot: RadioExperimentSnapshot, legacyTitle: String,
                  publishedTitle: String? = nil) {
        guard isRecording, let sequence else { return }
        let date = snapshot.programDate?.timeIntervalSince1970
        decisions.append(StreamDecisionRecord(traceSequence: sequence,
                                              elapsedSeconds: elapsed,
                                              legacyTitle: TracePrivacy.metadata(legacyTitle),
                                              publishedTitle: publishedTitle.map(TracePrivacy.metadata),
                                              feedTop: snapshot.feedTop.map(TracePrivacy.metadata),
                                              candidate: snapshot.candidate.map(TracePrivacy.metadata),
                                              occurrenceID: snapshot.candidateID.map { TracePrivacy.metadata($0.rawValue) },
                                              mediaSeconds: snapshot.mediaSeconds,
                                              programDateMilliseconds: date.map { Int64(($0 * 1000).rounded()) },
                                              estimatedSongSeconds: snapshot.songSeconds,
                                              reason: TracePrivacy.metadata(snapshot.reason),
                                              feedStatus: TracePrivacy.metadata(snapshot.feedStatus)))
        if decisions.count > 10_000 { failed = true }
    }

    /// Returns a local file path for the user to inspect. A failure never claims
    /// to have exported a complete trace+sidecar pair.
    func finish(reason: String) -> String {
        guard !finished else { return "Capture already stopped" }
        finished = true
        defer { try? writer.close() }
        guard !failed else { return "Capture incomplete (write or decision limit reached)" }
        do {
            try append(.ended(reason))
            let sidecar = StreamDecisionSidecar(schemaVersion: 1, sessionID: sessionID,
                                                mode: mode == .applyCandidate ? "apply_candidate" : "observe_only",
                                                routeCategory: routeCategory,
                                                feedToProgramOffset: StreamExperimentConfiguration.selectionPolicy.feedToProgramOffset,
                                                maxSelectedAge: StreamExperimentConfiguration.selectionPolicy.maxSelectedAge,
                                                maxFeedSilence: StreamExperimentConfiguration.selectionPolicy.maxFeedSilence,
                                                decisions: decisions)
            let data = try TraceJSON.encoder().encode(sidecar)
            guard data.count <= 8 * 1024 * 1024 else {
                return "Capture incomplete (decision sidecar limit reached)"
            }
            let descriptor = sidecarURL.withUnsafeFileSystemRepresentation { path in
                path.map { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600)) } ?? -1
            }
            guard descriptor >= 0 else { return "Capture incomplete (sidecar creation failed)" }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                return "Capture incomplete (sidecar write failed)"
            }
            return "Exported: \(traceURL.path) and \(sidecarURL.lastPathComponent)"
        } catch {
            return "Capture incomplete (trace write failed)"
        }
    }

    private var elapsed: Double { max(0, ProcessInfo.processInfo.systemUptime - startUptime) }

    @discardableResult
    private func tryAppend(_ payload: TracePayload) -> Int? {
        guard isRecording else { return nil }
        do { return try append(payload) }
        catch { failed = true; return nil }
    }

    @discardableResult
    private func append(_ payload: TracePayload) throws -> Int {
        let number = sequence
        try writer.append(TraceEvent(sessionID: sessionID, sequence: number,
                                     elapsedSeconds: elapsed, wallTime: Date(), payload: payload))
        sequence += 1
        return number
    }
}
