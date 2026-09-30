import AVFoundation
import Darwin
import Foundation
import StreamDiagnostics

/// Observation only. No custom loader, audio taps, buffer tuning, or system
/// Now Playing writes. One invocation creates exactly one player item/session.
@MainActor
final class CaptureSession: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    private let options: CaptureOptions
    private let writer: TraceWriter
    private let player = AVPlayer()
    private let metadataOutput = AVPlayerItemMetadataOutput(identifiers: nil)
    private let feedClient = FeedClient()
    private let sessionID = UUID()
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var sequence = 0
    private var stopped = false
    private var observations: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var signals: [DispatchSourceSignal] = []
    private var sampleTask: Task<Void, Never>?
    private var feedTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var metadataTasks: [UUID: Task<Void, Never>] = [:]
    private var continuation: CheckedContinuation<Bool, Never>?

    init(options: CaptureOptions) throws {
        self.options = options
        self.writer = try TraceWriter(url: options.outputURL)
        super.init()
    }

    private var elapsed: Double { ProcessInfo.processInfo.systemUptime - startedAt }

    func run() async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            print("Capturing \(options.station.rawValue) with AVPlayer; audible track is NOT inferred from feed-top.")
            print("Enter 1=song change, 2=lyric landmark, 3=wrong art, p=pause, r=resume, q=finish. Ctrl-C also finishes.")
            record(.started(SessionInfo(station: options.station.rawValue, streamURL: options.streamURL.absoluteString,
                                        feedURL: options.feedURL?.absoluteString, muted: options.muted)))
            guard !stopped else { return }
            let item = AVPlayerItem(url: options.streamURL)
            metadataOutput.setDelegate(self, queue: .main)
            item.add(metadataOutput)
            player.isMuted = options.muted
            player.replaceCurrentItem(with: item)
            installObservers(item: item)
            record(.notice("metadata_attached"))
            installInputAndSignals()
            player.play()
            sampleTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.sample()
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                }
            }
            startFeedLoop()
            deadlineTask = Task { [weak self] in
                guard let duration = self?.options.duration else { return }
                do { try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000)) } catch { return }
                self?.finish(reason: "duration")
            }
        }
    }

    private func installObservers(item: AVPlayerItem) {
        observations = [
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.sample() }
            },
            player.observe(\.rate, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.sample() }
            },
            item.observe(\.status, options: [.new]) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self, !self.stopped else { return }
                    self.sample()
                    if item.status == .failed {
                        let error = item.error as NSError?
                        self.record(.notice("player_error:\(error?.domain ?? "unknown"):\(error?.code ?? 0)"))
                        self.finish(reason: "player_failed", success: false)
                    }
                }
            },
        ]
        for (name, label) in [(NSNotification.Name.AVPlayerItemPlaybackStalled, "playback_stalled"),
                              (.AVPlayerItemTimeJumped, "media_time_jumped"),
                              (.AVPlayerItemDidPlayToEndTime, "item_ended"),
                              (.AVPlayerItemFailedToPlayToEndTime, "item_failed_to_end")] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.stopped else { return }
                    self.record(.notice(label))
                    self.sample()
                    if label == "item_ended" { self.finish(reason: label) }
                    if label == "item_failed_to_end" { self.finish(reason: label, success: false) }
                }
            })
        }
    }

    private func sample() {
        guard !stopped, let item = player.currentItem else { return }
        let state: String
        switch player.timeControlStatus {
        case .paused: state = "paused"
        case .waitingToPlayAtSpecifiedRate: state = "waiting"
        case .playing: state = "playing"
        @unknown default: state = "unknown"
        }
        let status: String
        switch item.status {
        case .unknown: status = "unknown"
        case .readyToPlay: status = "ready"
        case .failed: status = "failed"
        @unknown default: status = "unknown"
        }
        record(.playback(PlaybackObservation(mediaSeconds: finite(item.currentTime().seconds), programDate: item.currentDate(),
                                             rate: Double(player.rate), timeControlStatus: state, itemStatus: status,
                                             waitingReason: player.reasonForWaitingToPlay?.rawValue,
                                             loadedRanges: ranges(item.loadedTimeRanges), seekableRanges: ranges(item.seekableTimeRanges),
                                             bufferEmpty: item.isPlaybackBufferEmpty, likelyToKeepUp: item.isPlaybackLikelyToKeepUp)))
    }

    nonisolated func metadataOutput(_ output: AVPlayerItemMetadataOutput, didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup], from track: AVPlayerItemTrack?) {
        let receivedAt = ProcessInfo.processInfo.systemUptime
        Task { @MainActor [weak self] in self?.collectMetadata(groups, receivedAt: receivedAt) }
    }

    private func collectMetadata(_ groups: [AVTimedMetadataGroup], receivedAt: Double) {
        guard !stopped else { return }
        guard metadataTasks.count < 64, groups.reduce(0, { $0 + $1.items.count }) <= 256 else {
            finish(reason: "metadata_capacity_exceeded", success: false)
            return
        }
        let id = UUID()
        let receivedMedia = player.currentItem.flatMap { finite($0.currentTime().seconds) }
        let receiptElapsed = receivedAt - startedAt
        metadataTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.metadataTasks[id] = nil }
            var values: [MetadataValue] = []
            for group in groups {
                for item in group.items {
                    let value = try? await item.load(.stringValue)
                    guard !Task.isCancelled, !self.stopped else { return }
                    values.append(MetadataValue(identifier: item.identifier?.rawValue,
                                                key: item.key.map { String(describing: $0) }, keySpace: item.keySpace?.rawValue,
                                                value: value, mediaStartSeconds: self.finite(group.timeRange.start.seconds),
                                                mediaDurationSeconds: self.finite(group.timeRange.duration.seconds)))
                }
            }
            self.record(.metadata(MetadataObservation(receivedElapsedSeconds: receiptElapsed,
                                                       receivedMediaSeconds: receivedMedia, values: values)))
        }
    }

    private func startFeedLoop() {
        guard let url = options.feedURL else { return }
        feedTask = Task { [weak self] in
            var requestID = 0
            while !Task.isCancelled {
                guard let self, !self.stopped else { return }
                requestID += 1
                let result = await self.feedClient.fetch(url: url, station: self.options.station,
                                                        requestID: requestID, requestedAt: self.elapsed)
                guard !Task.isCancelled, !self.stopped else { return }
                self.record(.feed(result))
                do { try await Task.sleep(nanoseconds: UInt64(self.options.feedInterval * 1_000_000_000)) } catch { return }
            }
        }
    }

    private func installInputAndSignals() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while let line = readLine() {
                Task { @MainActor [weak self] in self?.command(line.trimmingCharacters(in: .whitespacesAndNewlines)) }
                if line == "q" { return }
            }
        }
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor in self?.finish(reason: "signal") }
            }
            signals.append(source)
            source.resume()
        }
    }

    private func command(_ command: String) {
        guard !stopped else { return }
        switch command {
        case "1": record(.marker("heard_song_change"))
        case "2": record(.marker("lyric_landmark"))
        case "3": record(.marker("wrong_artwork"))
        case "p": record(.marker("pause_requested")); player.pause()
        case "r": record(.marker("resume_requested")); player.play()
        case "q": finish(reason: "user")
        default: print("Use 1, 2, 3, p, r, or q followed by Enter.")
        }
    }

    private func record(_ payload: TracePayload) {
        guard !stopped else { return }
        do {
            let event = TraceEvent(sessionID: sessionID, sequence: sequence, elapsedSeconds: elapsed, wallTime: Date(), payload: payload)
            try writer.append(event)
            sequence += 1
            let prefix = String(format: "[%8.3fs]", event.elapsedSeconds)
            switch payload {
            case .metadata(let observation):
                print("\(prefix) player metadata: \(observation.values.map { String(reflecting: $0.value ?? "<nontext/unavailable>") }.joined(separator: " | "))")
            case .feed(let observation):
                let top = observation.entries.first
                print("\(prefix) feed-top: \(String(reflecting: top?.title ?? top?.kind ?? "<empty>")); failure=\(observation.failure ?? "none")")
            case .marker(let marker), .notice(let marker), .ended(let marker): print("\(prefix) \(marker)")
            default: break
            }
        } catch {
            fputs("Capture failed: \(error). File may be incomplete.\n", stderr)
            shutdown(success: false)
        }
    }

    private func finish(reason: String, success: Bool = true) {
        guard !stopped else { return }
        if !metadataTasks.isEmpty { record(.notice("pending_metadata_cancelled:\(metadataTasks.count)")) }
        record(.ended(reason))
        if !stopped { shutdown(success: success) }
    }

    private func shutdown(success: Bool) {
        guard !stopped else { return }
        stopped = true
        sampleTask?.cancel()
        feedTask?.cancel()
        deadlineTask?.cancel()
        metadataTasks.values.forEach { $0.cancel() }
        metadataTasks.removeAll()
        feedClient.cancel()
        observations.removeAll()
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        notifications.removeAll()
        metadataOutput.setDelegate(nil, queue: nil)
        player.pause()
        player.replaceCurrentItem(with: nil)
        signals.forEach { $0.cancel() }
        signals.removeAll()
        var finalSuccess = success
        do { try writer.close() } catch {
            fputs("Cannot finish trace: \(error)\n", stderr)
            finalSuccess = false
        }
        continuation?.resume(returning: finalSuccess)
        continuation = nil
    }

    private func finite(_ value: Double) -> Double? { value.isFinite ? value : nil }

    private func ranges(_ ranges: [NSValue]) -> [MediaRange] {
        ranges.compactMap {
            let range = $0.timeRangeValue
            guard let start = finite(range.start.seconds), let duration = finite(range.duration.seconds) else { return nil }
            return MediaRange(start: start, duration: duration)
        }
    }
}
