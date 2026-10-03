import Foundation
import StreamDiagnostics
import StreamSession

enum SelectionReplayError: Error, CustomStringConvertible, Equatable {
    case invalid(String)

    var description: String {
        switch self {
        case .invalid(let reason): return "Invalid selection replay: \(reason)"
        }
    }
}

struct SelectionTransition: Equatable {
    let elapsedSeconds: Double
    let trigger: DecisionTrigger
    let occurrence: Occurrence
    let songSeconds: Double
}

struct SelectionMarkerResult: Equatable {
    let id: String
    let classification: MarkerClassification
    let expected: ExpectedOccurrence
    let markerElapsedSeconds: Double?
    let predictedElapsedSeconds: Double?
    let signedErrorSeconds: Double?
    let observedProgramOffsetSeconds: Double?
    let includedInMetrics: Bool
    let identityProvenance: String
    let note: String?
}

struct SelectionMetrics: Equatable {
    let count: Int
    let medianAbsoluteErrorSeconds: Double
    let worstAbsoluteErrorSeconds: Double
}

struct PauseReplayResult: Equatable {
    let id: String
    let elapsedDurationSeconds: Double
    let mediaDeltaSeconds: Double?
    let programDateDeltaSeconds: Double?

    var clockStayedFrozen: Bool? {
        guard let mediaDeltaSeconds, let programDateDeltaSeconds else { return nil }
        return abs(mediaDeltaSeconds) <= 1 && abs(programDateDeltaSeconds) <= 1
    }
}

struct SelectionAnalysis: Equatable {
    let sessionID: UUID
    let offsetSeconds: Double
    let transitions: [SelectionTransition]
    let markerResults: [SelectionMarkerResult]
    let pauseResults: [PauseReplayResult]
    let metrics: SelectionMetrics?
    let unavailableReasons: [SelectionUnavailableReason: Int]
    let clockInvalidReasons: [MediaClockInvalidReason: Int]
}

enum SelectionReplay {
    static func analyze(events: [TraceEvent], annotations: SelectionAnnotations,
                        offsetSeconds: Double) throws -> SelectionAnalysis {
        guard offsetSeconds.isFinite else { throw SelectionReplayError.invalid("offset must be finite") }
        _ = try TraceReplay.snapshots(events)
        try annotations.validate(events: events)
        guard let first = events.first, case .started(let session) = first.payload else {
            throw SelectionReplayError.invalid("trace has no session start")
        }

        let selectionPolicy = OccurrenceSelectionPolicy(feedToProgramOffset: offsetSeconds,
                                                        maxSelectedAge: 20 * 60,
                                                        maxFeedSilence: 2 * 60)
        var state = SessionState(historyPolicy: OccurrenceHistoryPolicy(maxOccurrences: 100,
                                                                        maxHistoryAge: 6 * 60 * 60,
                                                                        correctionWindow: 120),
                                 selectionPolicy: selectionPolicy,
                                 clockPolicy: MediaClockPolicy(correlationTolerance: 2,
                                                              progressionTolerance: 2))
        var decisions: [DecisionRecord] = []
        var transitions: [SelectionTransition] = []
        var lastSelectedID: OccurrenceID?
        var unavailableReasons: [SelectionUnavailableReason: Int] = [:]
        var clockInvalidReasons: [MediaClockInvalidReason: Int] = [:]
        let generation = first.sessionID.uuidString

        func record(_ decision: SessionDecision) {
            decisions.append(DecisionRecord(decision: decision))
            if case .invalid(let reason)? = decision.clock {
                clockInvalidReasons[reason, default: 0] += 1
            }
            switch decision.selection {
            case .unavailable(let reason):
                unavailableReasons[reason, default: 0] += 1
            case .selected(let selection):
                guard selection.occurrence.id != lastSelectedID else { return }
                transitions.append(SelectionTransition(elapsedSeconds: decision.elapsedSeconds,
                                                       trigger: decision.trigger,
                                                       occurrence: selection.occurrence,
                                                       songSeconds: selection.songSeconds))
                lastSelectedID = selection.occurrence.id
            }
        }

        for event in events {
            switch event.payload {
            case .feed(let observation):
                let mutation: FeedMutation
                if let failure = observation.failure {
                    mutation = try state.failFeed(requestID: observation.requestID,
                                                  requestedElapsedSeconds: observation.requestedElapsedSeconds,
                                                  receivedElapsedSeconds: event.elapsedSeconds,
                                                  reason: failure)
                } else {
                    let inputs = observation.entries.map { entry in
                        OccurrenceInput(station: session.station, providerID: entry.providerID,
                                        kind: entry.kind, title: entry.title, artist: entry.artist,
                                        album: entry.album, artworkURL: entry.artworkURL,
                                        playedAt: entry.playedAt)
                    }
                    mutation = try state.receiveFeed(requestID: observation.requestID,
                                                     requestedElapsedSeconds: observation.requestedElapsedSeconds,
                                                     receivedElapsedSeconds: event.elapsedSeconds,
                                                     entries: inputs)
                }
                if let decision = mutation.decision { record(decision) }
            case .playback(let playback):
                let decision = state.observePlayer(MediaClockSample(
                    generation: generation,
                    elapsedSeconds: event.elapsedSeconds,
                    mediaSeconds: playback.mediaSeconds,
                    programDate: playback.programDate,
                    isAdvancing: playback.rate > 0 && playback.timeControlStatus == "playing"
                ))
                record(decision)
            case .started, .metadata, .notice, .marker, .ended:
                break
            }
        }

        let markerResults = annotations.markers.map { annotation in
            markerResult(annotation, transitions: transitions, decisions: decisions)
        }
        let includedErrors = markerResults.compactMap { result -> Double? in
            guard result.includedInMetrics else { return nil }
            return result.signedErrorSeconds
        }
        let metrics = metrics(for: includedErrors)
        let pauses = annotations.pauses.map { pauseResult($0, decisions: decisions) }
        return SelectionAnalysis(sessionID: first.sessionID, offsetSeconds: offsetSeconds,
                                 transitions: transitions, markerResults: markerResults,
                                 pauseResults: pauses, metrics: metrics,
                                 unavailableReasons: unavailableReasons,
                                 clockInvalidReasons: clockInvalidReasons)
    }

    static func render(events: [TraceEvent], annotations: SelectionAnnotations,
                       offsetSeconds: Double) throws -> String {
        let analysis = try analyze(events: events, annotations: annotations,
                                   offsetSeconds: offsetSeconds)
        var lines = [
            "stream-lab select — development evidence from retained traces; not an independent holdout.",
            "",
            "session \(analysis.sessionID.uuidString)",
            "  trace:  \(annotations.traceFilename)",
            "  sha256: \(annotations.traceSHA256)",
            "  offset: \(signed(analysis.offsetSeconds))s",
            "",
            "selection transitions (\(analysis.transitions.count))",
        ]
        for transition in analysis.transitions {
            lines.append("  [\(seconds(transition.elapsedSeconds))] \(quoted(transition.occurrence.title ?? transition.occurrence.kind))"
                         + " kind=\(transition.occurrence.kind) trigger=\(transition.trigger.rawValue)"
                         + " song=\(seconds(transition.songSeconds))s")
            lines.append("    id=\(transition.occurrence.id.rawValue)")
        }

        lines.append("")
        lines.append("annotations (\(analysis.markerResults.count))")
        for result in analysis.markerResults {
            let marker = result.markerElapsedSeconds.map { seconds($0) + "s" } ?? "<missed>"
            let predicted = result.predictedElapsedSeconds.map { seconds($0) + "s" } ?? "<not selected>"
            let error = result.signedErrorSeconds.map { signed($0) + "s" } ?? "n/a"
            let observed = result.observedProgramOffsetSeconds.map { signed($0) + "s" } ?? "n/a"
            lines.append("  \(result.id) [\(result.classification.rawValue)] expected=\(quoted(result.expected.title))")
            lines.append("    marker=\(marker) predicted=\(predicted) error=\(error)"
                         + " observed-program-offset=\(observed)"
                         + " metrics=\(result.includedInMetrics ? "included" : "excluded")")
            lines.append("    identity=\(result.identityProvenance)")
            if let note = result.note { lines.append("    note=\(note)") }
        }

        lines.append("")
        lines.append("pauses (\(analysis.pauseResults.count))")
        for pause in analysis.pauseResults {
            lines.append("  \(pause.id): elapsed=\(seconds(pause.elapsedDurationSeconds))s"
                         + " media=\(optionalSigned(pause.mediaDeltaSeconds))s"
                         + " program=\(optionalSigned(pause.programDateDeltaSeconds))s"
                         + " frozen=\(pause.clockStayedFrozen.map(String.init) ?? "unavailable")")
        }

        lines.append("")
        lines.append("metrics (included song-start markers only)")
        if let metrics = analysis.metrics {
            lines.append("  count: \(metrics.count)")
            lines.append("  median absolute error: \(seconds(metrics.medianAbsoluteErrorSeconds))s")
            lines.append("  worst absolute error: \(seconds(metrics.worstAbsoluteErrorSeconds))s")
        } else {
            lines.append("  none")
        }

        lines.append("")
        lines.append("invalid player-clock samples")
        if analysis.clockInvalidReasons.isEmpty {
            lines.append("  none")
        } else {
            for reason in analysis.clockInvalidReasons.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                lines.append("  \(reason.rawValue): \(analysis.clockInvalidReasons[reason]!)")
            }
        }

        lines.append("")
        lines.append("unavailable decisions")
        if analysis.unavailableReasons.isEmpty {
            lines.append("  none")
        } else {
            for reason in analysis.unavailableReasons.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                lines.append("  \(reason.rawValue): \(analysis.unavailableReasons[reason]!)")
            }
        }
        lines.append("")
        lines.append("Evidence boundary: the same captures motivated this offset and test it.")
        lines.append("A passing replay supports a fresh opt-in experiment; it does not validate lyrics, routes, or rollout.")
        return lines.joined(separator: "\n")
    }

    private static func markerResult(_ annotation: SelectionMarkerAnnotation,
                                     transitions: [SelectionTransition],
                                     decisions: [DecisionRecord]) -> SelectionMarkerResult {
        let transition = transitions.first { annotation.expected.matches($0.occurrence) }
        let signedError = zip(transition?.elapsedSeconds, annotation.markerElapsedSeconds).map { $0 - $1 }
        let nearestClock: ValidMediaClock? = annotation.markerElapsedSeconds.flatMap { markerElapsed in
            decisions.compactMap { record -> ValidMediaClock? in
                guard record.decision.trigger == .playerSample,
                      case .valid(let clock)? = record.decision.clock else { return nil }
                return clock
            }.min(by: { abs($0.elapsedSeconds - markerElapsed) < abs($1.elapsedSeconds - markerElapsed) })
        }
        let playedAt = Date(timeIntervalSince1970: Double(annotation.expected.playedAtMilliseconds) / 1000)
        let observedOffset = nearestClock?.programDate.timeIntervalSince(playedAt)
        return SelectionMarkerResult(id: annotation.id,
                                     classification: annotation.classification,
                                     expected: annotation.expected,
                                     markerElapsedSeconds: annotation.markerElapsedSeconds,
                                     predictedElapsedSeconds: transition?.elapsedSeconds,
                                     signedErrorSeconds: signedError,
                                     observedProgramOffsetSeconds: observedOffset,
                                     includedInMetrics: annotation.includeInMetrics,
                                     identityProvenance: annotation.identityProvenance,
                                     note: annotation.note)
    }

    private static func pauseResult(_ annotation: PauseAnnotation,
                                    decisions: [DecisionRecord]) -> PauseReplayResult {
        let clocks = decisions.compactMap { record -> ValidMediaClock? in
            guard record.decision.trigger == .playerSample,
                  case .valid(let clock)? = record.decision.clock else { return nil }
            return clock
        }
        let start = clocks.filter { $0.elapsedSeconds >= annotation.pauseElapsedSeconds }
            .min(by: { $0.elapsedSeconds < $1.elapsedSeconds })
        let end = clocks.filter { $0.elapsedSeconds >= annotation.resumeElapsedSeconds }
            .min(by: { $0.elapsedSeconds < $1.elapsedSeconds })
        return PauseReplayResult(id: annotation.id,
                                 elapsedDurationSeconds: annotation.resumeElapsedSeconds - annotation.pauseElapsedSeconds,
                                 mediaDeltaSeconds: zip(end?.mediaSeconds, start?.mediaSeconds).map { $0 - $1 },
                                 programDateDeltaSeconds: zip(end?.programDate, start?.programDate)
                                    .map { $0.timeIntervalSince($1) })
    }

    private static func metrics(for signedErrors: [Double]) -> SelectionMetrics? {
        guard !signedErrors.isEmpty else { return nil }
        let absolute = signedErrors.map(abs).sorted()
        let middle = absolute.count / 2
        let median = absolute.count.isMultiple(of: 2)
            ? (absolute[middle - 1] + absolute[middle]) / 2
            : absolute[middle]
        return SelectionMetrics(count: absolute.count,
                                medianAbsoluteErrorSeconds: median,
                                worstAbsoluteErrorSeconds: absolute.last!)
    }

    private static func seconds(_ value: Double) -> String { String(format: "%.3f", value) }
    private static func signed(_ value: Double) -> String { String(format: "%+.3f", value) }
    private static func optionalSigned(_ value: Double?) -> String { value.map(signed) ?? "unavailable" }
    private static func quoted(_ value: String) -> String { String(reflecting: value) }
}

private struct DecisionRecord {
    let decision: SessionDecision
}

private func zip<A, B>(_ first: A?, _ second: B?) -> (A, B)? {
    guard let first, let second else { return nil }
    return (first, second)
}
