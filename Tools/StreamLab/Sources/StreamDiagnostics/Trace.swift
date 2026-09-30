import Foundation

enum TraceDate {
    /// Persisted UTC correlation dates use millisecond resolution. Monotonic elapsed
    /// and media time retain full `Double` precision for interval measurements.
    static func snapToMilliseconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }
}

/// Version 1 uses Swift's tagged Codable enum representation for `payload`.
/// Each file is one player-item session. Times are observations, not song-start claims.
public struct TraceEvent: Codable, Equatable {
    public var schemaVersion: Int = 1
    public let sessionID: UUID
    public let sequence: Int
    public let elapsedSeconds: Double
    /// Whole milliseconds since 1970, snapped on init so an event equals itself after a
    /// write/read round trip. Correlates a trace with feed and ICY timestamps, which are
    /// whole seconds at best; `elapsedSeconds` is the precise axis for timing work.
    public let wallTime: Date
    public let payload: TracePayload

    public init(sessionID: UUID, sequence: Int, elapsedSeconds: Double, wallTime: Date, payload: TracePayload) {
        self.sessionID = sessionID
        self.sequence = sequence
        self.elapsedSeconds = elapsedSeconds
        self.wallTime = TraceDate.snapToMilliseconds(wallTime)
        self.payload = payload
    }
}

public struct SessionInfo: Codable, Equatable {
    public let station: String
    public let streamURL: String
    public let feedURL: String?
    public let muted: Bool
    public let recorderVersion: String
    public let operatingSystem: String

    public init(station: String, streamURL: String, feedURL: String?, muted: Bool) {
        self.station = station
        self.streamURL = TracePrivacy.url(streamURL)
        self.feedURL = feedURL.map(TracePrivacy.url)
        self.muted = muted
        self.recorderVersion = "stream-lab/1"
        self.operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    }
}

public enum TracePayload: Codable, Equatable {
    case started(SessionInfo)
    case metadata(MetadataObservation)
    case feed(FeedObservation)
    case playback(PlaybackObservation)
    case notice(String)
    case marker(String)
    case ended(String)
}

public struct ObservationSnapshot: Codable, Equatable {
    public fileprivate(set) var sessionID: UUID?
    public fileprivate(set) var session: SessionInfo?
    public fileprivate(set) var sequence: Int = -1
    public fileprivate(set) var elapsedSeconds: Double = 0
    public fileprivate(set) var lastMarker: String?
    public fileprivate(set) var endReason: String?
    public fileprivate(set) var metadata: MetadataObservation?
    public fileprivate(set) var feed: FeedObservation?
    public fileprivate(set) var playback: PlaybackObservation?
    public fileprivate(set) var lastNotice: String?
}

public enum TraceError: Error, CustomStringConvertible {
    case invalid(String)
    case limitExceeded

    public var description: String {
        switch self {
        case .invalid(let reason): return "Invalid trace: \(reason)"
        case .limitExceeded: return "Trace size limit reached; capture is incomplete. Use a shorter session."
        }
    }
}

/// Pure observation reducer: deliberately does NOT equate feed-top with audible content.
public struct TraceReducer {
    public private(set) var snapshot = ObservationSnapshot()

    public init() {}

    public mutating func apply(_ event: TraceEvent) throws {
        guard event.schemaVersion == 1 else { throw TraceError.invalid("unsupported schema version") }
        guard event.elapsedSeconds.isFinite, event.elapsedSeconds >= snapshot.elapsedSeconds else {
            throw TraceError.invalid("invalid or backward elapsed time")
        }
        // Wall time is correlation evidence and may move backward after a system-clock
        // correction. Sequence and monotonic elapsed time define trace ordering.
        guard event.wallTime.timeIntervalSince1970.isFinite else { throw TraceError.invalid("invalid wall clock") }
        guard event.sequence == snapshot.sequence + 1 else { throw TraceError.invalid("sequence gap or reordering") }
        guard snapshot.endReason == nil else { throw TraceError.invalid("event after session end") }
        if let id = snapshot.sessionID {
            guard id == event.sessionID else { throw TraceError.invalid("wrong session") }
        } else {
            guard case .started = event.payload else { throw TraceError.invalid("missing session start") }
        }
        switch event.payload {
        case .started(let session):
            guard snapshot.sessionID == nil else { throw TraceError.invalid("duplicate session start") }
            snapshot.sessionID = event.sessionID
            snapshot.session = session
        case .metadata(let observation): snapshot.metadata = observation
        case .feed(let observation): snapshot.feed = observation
        case .playback(let observation): snapshot.playback = observation
        case .notice(let notice): snapshot.lastNotice = notice
        case .marker(let marker): snapshot.lastMarker = marker
        case .ended(let reason): snapshot.endReason = reason
        }
        snapshot.sequence = event.sequence
        snapshot.elapsedSeconds = event.elapsedSeconds
    }
}

public enum TraceReplay {
    public static func snapshots(_ events: [TraceEvent]) throws -> [ObservationSnapshot] {
        var reducer = TraceReducer()
        var result: [ObservationSnapshot] = []
        for event in events {
            try reducer.apply(event)
            result.append(reducer.snapshot)
        }
        guard reducer.snapshot.endReason != nil else { throw TraceError.invalid("incomplete capture: missing session end") }
        return result
    }
}

public enum TraceJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
