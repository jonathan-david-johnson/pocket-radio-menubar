import Foundation
import StreamDiagnostics

/// Renders a recorded trace as a deterministic text timeline. Output depends only on
/// the event sequence: no clocks, locales, time zones, or dictionary ordering leak in.
///
/// The report never merges feed entries with player metadata. They stay separate
/// candidates because neither one establishes what a listener actually heard.
enum ReplayReport {
    static func render(_ events: [TraceEvent]) throws -> String {
        let snapshots = try TraceReplay.snapshots(events)
        guard let final = snapshots.last, let session = final.session else {
            throw TraceError.invalid("trace has no session start")
        }

        var lines = ["stream-lab replay — observations only; no line below is a claim about what was audible.", ""]
        lines.append("session \(final.sessionID?.uuidString ?? "<unknown>")")
        lines.append("  station:  \(session.station)")
        lines.append("  stream:   \(session.streamURL)")
        lines.append("  feed:     \(session.feedURL ?? "<disabled>")")
        lines.append("  muted:    \(session.muted)")
        lines.append("  recorder: \(session.recorderVersion)")
        lines.append("  events:   \(events.count)")
        lines.append("  elapsed:  \(seconds(final.elapsedSeconds))s")
        lines.append("  ended:    \(final.endReason ?? "<incomplete>")")
        lines.append("")
        lines.append("timeline (elapsed seconds; monotonic ordering — see the clock section for untracked time)")
        lines.append(contentsOf: events.map(timelineRow))

        var playbackCount = 0, metadataCount = 0, feedCount = 0, feedFailures = 0, noticeCount = 0
        var markers: [String: Int] = [:]
        for event in events {
            switch event.payload {
            case .playback: playbackCount += 1
            case .metadata: metadataCount += 1
            case .feed(let observation):
                feedCount += 1
                if observation.failure != nil { feedFailures += 1 }
            case .notice: noticeCount += 1
            case .marker(let marker): markers[marker, default: 0] += 1
            case .started, .ended: break
            }
        }

        lines.append("")
        lines.append(contentsOf: clockSection(events))

        lines.append("")
        lines.append(contentsOf: feedTransitionSection(events))

        lines.append("")
        lines.append("counts")
        lines.append("  playback observations: \(playbackCount)")
        lines.append("  player metadata: \(metadataCount)")
        lines.append("  feed responses: \(feedCount)")
        lines.append("  feed failures: \(feedFailures)")
        lines.append("  notices: \(noticeCount)")
        lines.append("  markers:\(markers.isEmpty ? " none" : "")")
        // Sorted so the report is byte-identical across runs.
        for key in markers.keys.sorted() { lines.append("    \(key): \(markers[key]!)") }

        lines.append("")
        lines.append("Evidence boundary: feed entries and player metadata remain separate candidates.")
        lines.append("Neither one, nor a human marker, establishes an audible song boundary.")
        return lines.joined(separator: "\n")
    }

    private static func timelineRow(_ event: TraceEvent) -> String {
        let prefix = String(format: "[%9.3f] ", event.elapsedSeconds)
        switch event.payload {
        case .started(let session):
            return prefix + "started   \(session.station) muted=\(session.muted)"
        case .notice(let notice):
            return prefix + "notice    \(notice)"
        case .marker(let marker):
            return prefix + "marker    \(marker)"
        case .ended(let reason):
            return prefix + "ended     \(reason)"
        case .playback(let observation):
            let buffer = observation.bufferEmpty ? "empty" : (observation.likelyToKeepUp ? "ok" : "low")
            let waiting = observation.waitingReason.map { " waiting=\($0)" } ?? ""
            return prefix + "playback  \(observation.timeControlStatus)/\(observation.itemStatus)"
                + " media=\(optionalSeconds(observation.mediaSeconds))"
                + String(format: " rate=%.2f", observation.rate)
                + " buffer=\(buffer)\(waiting)"
        case .metadata(let observation):
            let values = observation.values.map { value -> String in
                let range = zip(value.mediaStartSeconds, value.mediaDurationSeconds)
                    .map { " range=[\(seconds($0)),+\(seconds($1))]" } ?? ""
                return String(reflecting: value.value ?? "<nontext/unavailable>") + range
            }
            return prefix + "metadata  media=\(optionalSeconds(observation.receivedMediaSeconds)) "
                + (values.isEmpty ? "<no items>" : values.joined(separator: " | "))
        case .feed(let observation):
            if let failure = observation.failure {
                return prefix + "feed      #\(observation.requestID) failure=\(failure)"
            }
            let top = observation.entries.first
            let title = top.flatMap { $0.title ?? $0.kind } ?? "<empty>"
            let artist = top?.artist.map { " — \($0)" } ?? ""
            return prefix + "feed      #\(observation.requestID)"
                + " status=\(observation.statusCode.map(String.init) ?? "none")"
                + " entries=\(observation.entries.count) bytes=\(observation.bodyBytes)"
                + " top-candidate=\(String(reflecting: title))\(artist)"
        }
    }


    /// `elapsedSeconds` comes from `ProcessInfo.systemUptime`, which freezes while the
    /// system is suspended. The reducer still sees a valid monotonic sequence, so a
    /// capture that slept through part of its run looks like a clean shorter capture.
    /// Comparing it against `wallTime` is the only way the trace reveals the gap.
    private static let skewThreshold = 2.0

    private static func clockSection(_ events: [TraceEvent]) -> [String] {
        guard let first = events.first, let last = events.last else { return [] }
        let wallSpan = last.wallTime.timeIntervalSince(first.wallTime)
        let monotonicSpan = last.elapsedSeconds - first.elapsedSeconds

        var gaps: [(elapsed: Double, monotonic: Double, wall: Double)] = []
        for (previous, event) in zip(events, events.dropFirst()) {
            let monotonic = event.elapsedSeconds - previous.elapsedSeconds
            let wall = event.wallTime.timeIntervalSince(previous.wallTime)
            if wall - monotonic > skewThreshold {
                gaps.append((event.elapsedSeconds, monotonic, wall))
            }
        }

        var lines = ["clock"]
        lines.append("  wall span:      \(seconds(wallSpan))s")
        lines.append("  monotonic span: \(seconds(monotonicSpan))s")
        guard !gaps.isEmpty else {
            lines.append("  no gap over \(seconds(skewThreshold))s; the two clocks agree")
            return lines
        }
        let total = gaps.reduce(0) { $0 + ($1.wall - $1.monotonic) }
        lines.append("  UNTRACKED TIME: \(seconds(total))s across \(gaps.count) gap(s)")
        for gap in gaps {
            lines.append("    at elapsed \(seconds(gap.elapsed)): wall +\(seconds(gap.wall))s"
                + " vs monotonic +\(seconds(gap.monotonic))s")
        }
        lines.append("  Monotonic time freezes while the system is suspended, so this capture")
        lines.append("  most likely slept. Any interval spanning a gap above is a lower bound")
        lines.append("  on real time, and audio continuity across it is not established.")
        return lines
    }


    /// A feed is polled, so the instant an entry appeared is only known to lie between the
    /// last poll without it and the first poll with it. Report that bracket, never a point.
    ///
    /// The bracket is measured against the entry's own claimed airtime, which is a
    /// broadcaster assertion. It says when the feed published, not when audio changed.
    private static func feedTransitionSection(_ events: [TraceEvent]) -> [String] {
        var observations: [(event: TraceEvent, observation: FeedObservation)] = []
        for event in events {
            if case .feed(let observation) = event.payload, observation.failure == nil {
                observations.append((event, observation))
            }
        }

        var transitions: [[String]] = []
        var previousTopKey: String??
        var previousPoll: TraceEvent?
        var previousObservation: FeedObservation?
        for (event, observation) in observations {
            let top = observation.entries.first
            // KEXP airbreaks have no title. Include the kind in the identity so an
            // untitled break remains a transition, not a missing song title.
            let topKey = top.map { "\($0.kind)\u{1F}\($0.title ?? "")" }
            defer { previousTopKey = .some(topKey); previousPoll = event; previousObservation = observation }
            // The first successful poll establishes a baseline, including an airbreak.
            guard let established = previousTopKey, established != topKey, let top else { continue }
            let name = top.title.flatMap { $0.isEmpty ? nil : $0 } ?? top.kind
            let kindSuffix = top.kind == "trackplay" ? "" : " (kind=\(top.kind))"

            var rows = [
                "  \(String(reflecting: name))\(kindSuffix)",
                "    first seen at elapsed \(seconds(event.elapsedSeconds))",
            ]
            if let airtime = top.playedAt {
                // A response carrying `age: N` describes the origin as of N seconds earlier.
                let age = cacheAge(observation)
                let upper = event.wallTime.addingTimeInterval(-age).timeIntervalSince(airtime)
                if age > 0 {
                    rows.append("    responding cache was \(seconds(age))s stale")
                }
                rows.append("    origin had it by claimed airtime +\(seconds(upper))s")
                if let earlier = previousPoll, let earlierObservation = previousObservation {
                    let earlierAge = cacheAge(earlierObservation)
                    let lower = earlier.wallTime.addingTimeInterval(-earlierAge).timeIntervalSince(airtime)
                    if lower >= 0 {
                        rows.append("    published between claimed airtime +\(seconds(lower))s and +\(seconds(upper))s")
                    } else {
                        rows.append("    previous response was \(seconds(earlierAge))s stale and predates the airtime,")
                        rows.append("    so it gives no lower bound; the lag may be anywhere in 0s..+\(seconds(upper))s")
                    }
                }
            } else {
                rows.append("    no stated airtime in the entry; publish lag cannot be bracketed")
            }
            transitions.append(rows)
        }

        var lines = ["feed transitions (\(transitions.count) observed)"]
        if let worst = observations.map({ cacheAge($0.observation) }).max(), worst > 0 {
            lines.append("  cache age observed: up to \(seconds(worst))s stale across \(observations.count) polls")
            lines.append("  A cached feed cannot reveal a change sooner than it refreshes, so polling faster")
            lines.append("  than the refresh interval gains nothing.")
        }
        guard !transitions.isEmpty else {
            lines.append("  no change in the feed's top entry during this capture")
            return lines
        }
        for rows in transitions { lines.append(contentsOf: rows) }
        lines.append("  Bounds above describe when the ORIGIN held the entry, corrected for cache age, and")
        lines.append("  are measured against the entry's own claimed airtime. None of it is when audio")
        lines.append("  changed or what a listener heard.")
        return lines
    }


    /// Seconds the responding cache had already held the payload, from the `age` header.
    /// An absent header means the response came from the origin.
    private static func cacheAge(_ observation: FeedObservation) -> Double {
        let value = observation.headers.first { $0.key.lowercased() == "age" }?.value
        return value.flatMap(Double.init).map { max(0, $0) } ?? 0
    }

    private static func seconds(_ value: Double) -> String { String(format: "%.3f", value) }

    private static func optionalSeconds(_ value: Double?) -> String { value.map(seconds) ?? "none" }
}

private func zip<A, B>(_ first: A?, _ second: B?) -> (A, B)? {
    guard let first, let second else { return nil }
    return (first, second)
}
