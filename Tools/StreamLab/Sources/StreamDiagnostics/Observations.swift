import Foundation

public struct MetadataValue: Codable, Equatable {
    public let identifier: String?
    public let key: String?
    public let keySpace: String?
    public let value: String?
    public let mediaStartSeconds: Double?
    public let mediaDurationSeconds: Double?

    public init(identifier: String?, key: String?, keySpace: String?, value: String?, mediaStartSeconds: Double?, mediaDurationSeconds: Double?) {
        self.identifier = identifier.map(TracePrivacy.metadata)
        self.key = key.map(TracePrivacy.metadata)
        self.keySpace = keySpace
        self.value = value.map(TracePrivacy.metadata)
        self.mediaStartSeconds = mediaStartSeconds
        self.mediaDurationSeconds = mediaDurationSeconds
    }
}

public struct MetadataObservation: Codable, Equatable {
    public let receivedElapsedSeconds: Double
    public let receivedMediaSeconds: Double?
    public let values: [MetadataValue]

    public init(receivedElapsedSeconds: Double, receivedMediaSeconds: Double?, values: [MetadataValue]) {
        self.receivedElapsedSeconds = receivedElapsedSeconds
        self.receivedMediaSeconds = receivedMediaSeconds
        self.values = values
    }
}

public struct FeedObservation: Codable, Equatable {
    public let requestID: Int
    public let requestedElapsedSeconds: Double
    public let statusCode: Int?
    public let headers: [String: String]
    public let bodyBytes: Int
    public let entries: [FeedEntry]
    public let failure: String?

    public init(requestID: Int, requestedElapsedSeconds: Double, statusCode: Int?, headers: [String: String], bodyBytes: Int, entries: [FeedEntry], failure: String?) {
        self.requestID = requestID
        self.requestedElapsedSeconds = requestedElapsedSeconds
        self.statusCode = statusCode
        self.headers = headers
        self.bodyBytes = bodyBytes
        self.entries = entries
        self.failure = failure
    }
}

public struct MediaRange: Codable, Equatable {
    public let start: Double
    public let duration: Double

    public init(start: Double, duration: Double) {
        self.start = start
        self.duration = duration
    }
}

public struct PlaybackObservation: Codable, Equatable {
    public let mediaSeconds: Double?
    /// UTC media correlation at millisecond resolution. `mediaSeconds` and event
    /// elapsed time remain the precise axes for interval measurements.
    public let programDate: Date?
    public let rate: Double
    public let timeControlStatus: String
    public let itemStatus: String
    public let waitingReason: String?
    public let loadedRanges: [MediaRange]
    public let seekableRanges: [MediaRange]
    public let bufferEmpty: Bool
    public let likelyToKeepUp: Bool

    public init(mediaSeconds: Double?, programDate: Date?, rate: Double, timeControlStatus: String, itemStatus: String,
                waitingReason: String?, loadedRanges: [MediaRange], seekableRanges: [MediaRange], bufferEmpty: Bool, likelyToKeepUp: Bool) {
        self.mediaSeconds = mediaSeconds
        self.programDate = programDate.map(TraceDate.snapToMilliseconds)
        self.rate = rate
        self.timeControlStatus = timeControlStatus
        self.itemStatus = itemStatus
        self.waitingReason = waitingReason
        self.loadedRanges = loadedRanges
        self.seekableRanges = seekableRanges
        self.bufferEmpty = bufferEmpty
        self.likelyToKeepUp = likelyToKeepUp
    }
}
