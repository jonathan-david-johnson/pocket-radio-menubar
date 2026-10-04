import Foundation
import StreamDiagnostics
import StreamSession

enum MarkerClassification: String, Codable, Equatable {
    case songStart = "song_start"
    case commercial
    case missedSongStart = "missed_song_start"
}

struct ExpectedOccurrence: Codable, Equatable {
    let title: String
    let artist: String?
    let kind: String
    let playedAtMilliseconds: Int64

    func matches(_ occurrence: Occurrence) -> Bool {
        occurrence.title == title
            && occurrence.artist == artist
            && occurrence.kind == kind
            && occurrence.playedAt.map(Self.milliseconds) == playedAtMilliseconds
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

struct SelectionMarkerAnnotation: Codable, Equatable {
    let id: String
    let classification: MarkerClassification
    let traceSequence: Int?
    let markerElapsedSeconds: Double?
    let expected: ExpectedOccurrence
    let identityProvenance: String
    let includeInMetrics: Bool
    let note: String?
}

struct PauseAnnotation: Codable, Equatable {
    let id: String
    let pauseSequence: Int
    let pauseElapsedSeconds: Double
    let resumeSequence: Int
    let resumeElapsedSeconds: Double
}

struct SelectionAnnotations: Codable, Equatable {
    let schemaVersion: Int
    let sessionID: UUID
    let traceFilename: String
    let traceSHA256: String
    let markers: [SelectionMarkerAnnotation]
    let pauses: [PauseAnnotation]

    static func read(url: URL) throws -> SelectionAnnotations {
        guard url.isFileURL else { throw SelectionReplayError.invalid("annotation path must be a file") }
        do {
            return try JSONDecoder().decode(SelectionAnnotations.self, from: Data(contentsOf: url))
        } catch let error as SelectionReplayError {
            throw error
        } catch {
            throw SelectionReplayError.invalid("cannot decode annotations")
        }
    }

    func validate(events: [TraceEvent]) throws {
        guard schemaVersion == 1 else { throw SelectionReplayError.invalid("unsupported annotation schema") }
        guard let traceSession = events.first?.sessionID, traceSession == sessionID else {
            throw SelectionReplayError.invalid("annotation session does not match trace")
        }
        guard !traceFilename.isEmpty, !traceSHA256.isEmpty else {
            throw SelectionReplayError.invalid("annotation trace identity is incomplete")
        }
        var ids = Set<String>()
        for marker in markers {
            guard !marker.id.isEmpty, ids.insert(marker.id).inserted,
                  marker.expected.playedAtMilliseconds > 0,
                  !marker.identityProvenance.isEmpty else {
                throw SelectionReplayError.invalid("invalid or duplicate marker annotation")
            }
            switch marker.classification {
            case .missedSongStart:
                guard marker.traceSequence == nil, marker.markerElapsedSeconds == nil,
                      !marker.includeInMetrics else {
                    throw SelectionReplayError.invalid("missed marker must have no trace event and be excluded")
                }
            case .songStart, .commercial:
                guard let sequence = marker.traceSequence,
                      let elapsed = marker.markerElapsedSeconds,
                      elapsed.isFinite,
                      let event = events.first(where: { $0.sequence == sequence }),
                      abs(event.elapsedSeconds - elapsed) <= 0.001,
                      case .marker = event.payload else {
                    throw SelectionReplayError.invalid("annotation marker does not match trace event")
                }
                if marker.classification == .commercial, marker.includeInMetrics {
                    throw SelectionReplayError.invalid("commercial cannot count as a song-start metric")
                }
            }
        }

        for pause in pauses {
            guard !pause.id.isEmpty,
                  pause.pauseElapsedSeconds.isFinite, pause.resumeElapsedSeconds.isFinite,
                  pause.resumeElapsedSeconds >= pause.pauseElapsedSeconds,
                  let start = events.first(where: { $0.sequence == pause.pauseSequence }),
                  let end = events.first(where: { $0.sequence == pause.resumeSequence }),
                  abs(start.elapsedSeconds - pause.pauseElapsedSeconds) <= 0.001,
                  abs(end.elapsedSeconds - pause.resumeElapsedSeconds) <= 0.001,
                  case .marker(let startName) = start.payload, startName == "pause_requested",
                  case .marker(let endName) = end.payload, endName == "resume_requested" else {
                throw SelectionReplayError.invalid("pause annotation does not match trace markers")
            }
        }
    }
}
