import Foundation

public enum StreamSessionError: Error, Equatable, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let reason): return "Invalid stream-session input: \(reason)"
        }
    }
}

public struct OccurrenceID: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct OccurrenceInput: Codable, Equatable, Sendable {
    public let station: String
    public let providerID: String?
    public let kind: String
    public let title: String?
    public let artist: String?
    public let album: String?
    public let artworkURL: String?
    public let playedAt: Date?

    public init(station: String, providerID: String?, kind: String, title: String?, artist: String?,
                album: String?, artworkURL: String?, playedAt: Date?) {
        self.station = station
        self.providerID = providerID
        self.kind = kind
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.playedAt = playedAt
    }
}

public struct Occurrence: Codable, Equatable, Sendable {
    public let id: OccurrenceID
    public let station: String
    public let providerID: String?
    public let kind: String
    public let title: String?
    public let artist: String?
    public let album: String?
    public let artworkURL: String?
    public let playedAt: Date?
    public let firstReceivedElapsedSeconds: Double
    public let lastReceivedElapsedSeconds: Double
    public let revision: Int

    fileprivate init(id: OccurrenceID, input: OccurrenceInput, firstReceived: Double,
                     lastReceived: Double, revision: Int) {
        self.id = id
        self.station = input.station
        self.providerID = input.providerID
        self.kind = input.kind
        self.title = input.title
        self.artist = input.artist
        self.album = input.album
        self.artworkURL = input.artworkURL
        self.playedAt = input.playedAt
        self.firstReceivedElapsedSeconds = firstReceived
        self.lastReceivedElapsedSeconds = lastReceived
        self.revision = revision
    }

    fileprivate var contentKey: String {
        OccurrenceIdentity.contentKey(station: station, kind: kind, title: title, artist: artist)
    }
}

public struct OccurrenceHistoryPolicy: Codable, Equatable, Sendable {
    public let maxOccurrences: Int
    public let maxHistoryAge: TimeInterval
    public let correctionWindow: TimeInterval

    public init(maxOccurrences: Int = 100, maxHistoryAge: TimeInterval = 6 * 60 * 60,
                correctionWindow: TimeInterval = 120) {
        self.maxOccurrences = maxOccurrences
        self.maxHistoryAge = maxHistoryAge
        self.correctionWindow = correctionWindow
    }
}

public enum FeedState: Codable, Equatable, Sendable {
    case neverReceived
    case available(receivedElapsedSeconds: Double)
    case empty(receivedElapsedSeconds: Double)
    case failed(receivedElapsedSeconds: Double, reason: String)
}

public enum HistoryUpdate: Equatable, Sendable {
    case accepted(inserted: Int, revised: Int)
    case empty
    case failed(String)
    case ignoredOutOfOrder
    case ambiguousCorrection(String)
}

public struct OccurrenceHistory: Equatable, Sendable {
    public let policy: OccurrenceHistoryPolicy
    public private(set) var feedState: FeedState = .neverReceived
    public private(set) var hasAmbiguousCorrection = false
    public private(set) var lastSuccessfulReceivedElapsedSeconds: Double?

    private var storage: [OccurrenceID: Occurrence] = [:]
    private var lastRequest: RequestKey?

    public init(policy: OccurrenceHistoryPolicy = OccurrenceHistoryPolicy()) {
        self.policy = policy
    }

    /// Chronological source-time order. Undated entries sort last and cannot be selected.
    public var occurrences: [Occurrence] {
        storage.values.sorted(by: Self.sortOccurrences)
    }

    public mutating func receive(requestID: Int, requestedElapsedSeconds: Double,
                                 receivedElapsedSeconds: Double,
                                 entries: [OccurrenceInput]) throws -> HistoryUpdate {
        let key = try validateRequest(requestID: requestID, requested: requestedElapsedSeconds,
                                      received: receivedElapsedSeconds)
        guard isNewer(key) else { return .ignoredOutOfOrder }

        if entries.isEmpty {
            lastRequest = key
            lastSuccessfulReceivedElapsedSeconds = receivedElapsedSeconds
            feedState = .empty(receivedElapsedSeconds: receivedElapsedSeconds)
            hasAmbiguousCorrection = false
            return .empty
        }

        try entries.forEach(Self.validate)
        var working = self
        var inserted = 0
        var revised = 0
        var matchedThisBatch = Set<OccurrenceID>()

        for input in entries {
            let directID = OccurrenceIdentity.id(for: input)
            if let existing = working.storage[directID] {
                let next = Self.revising(existing, with: input, received: receivedElapsedSeconds)
                if Self.materiallyDiffers(existing, next) { revised += 1 }
                working.storage[directID] = next
                matchedThisBatch.insert(directID)
                continue
            }

            let correctionCandidates: [Occurrence]
            if input.providerID == nil, let playedAt = input.playedAt {
                let contentKey = OccurrenceIdentity.contentKey(for: input)
                correctionCandidates = working.storage.values.filter { occurrence in
                    guard occurrence.providerID == nil,
                          occurrence.contentKey == contentKey,
                          let existingDate = occurrence.playedAt,
                          !matchedThisBatch.contains(occurrence.id) else { return false }
                    return abs(existingDate.timeIntervalSince(playedAt)) <= policy.correctionWindow
                }
            } else {
                correctionCandidates = []
            }

            if correctionCandidates.count > 1 {
                hasAmbiguousCorrection = true
                lastRequest = key
                feedState = .available(receivedElapsedSeconds: receivedElapsedSeconds)
                return .ambiguousCorrection(OccurrenceIdentity.contentKey(for: input))
            }

            if let corrected = correctionCandidates.first {
                let next = Self.revising(corrected, with: input, received: receivedElapsedSeconds)
                working.storage[corrected.id] = next
                matchedThisBatch.insert(corrected.id)
                revised += 1
            } else {
                let occurrence = Occurrence(id: directID, input: input,
                                            firstReceived: receivedElapsedSeconds,
                                            lastReceived: receivedElapsedSeconds,
                                            revision: 0)
                working.storage[directID] = occurrence
                matchedThisBatch.insert(directID)
                inserted += 1
            }
        }

        working.lastRequest = key
        working.lastSuccessfulReceivedElapsedSeconds = receivedElapsedSeconds
        working.feedState = .available(receivedElapsedSeconds: receivedElapsedSeconds)
        working.hasAmbiguousCorrection = false
        working.evict()
        self = working
        return .accepted(inserted: inserted, revised: revised)
    }

    public mutating func fail(requestID: Int, requestedElapsedSeconds: Double,
                              receivedElapsedSeconds: Double, reason: String) throws -> HistoryUpdate {
        let key = try validateRequest(requestID: requestID, requested: requestedElapsedSeconds,
                                      received: receivedElapsedSeconds)
        guard isNewer(key) else { return .ignoredOutOfOrder }
        lastRequest = key
        feedState = .failed(receivedElapsedSeconds: receivedElapsedSeconds, reason: reason)
        return .failed(reason)
    }

    private func validateRequest(requestID: Int, requested: Double, received: Double) throws -> RequestKey {
        guard policy.maxOccurrences > 0,
              policy.maxHistoryAge.isFinite, policy.maxHistoryAge >= 0,
              policy.correctionWindow.isFinite, policy.correctionWindow >= 0 else {
            throw StreamSessionError.invalid("history policy")
        }
        guard requestID >= 0, requested.isFinite, received.isFinite,
              requested >= 0, received >= requested else {
            throw StreamSessionError.invalid("request timing")
        }
        return RequestKey(requestedElapsedSeconds: requested, requestID: requestID)
    }

    private func isNewer(_ key: RequestKey) -> Bool {
        guard let lastRequest else { return true }
        if key.requestedElapsedSeconds != lastRequest.requestedElapsedSeconds {
            return key.requestedElapsedSeconds > lastRequest.requestedElapsedSeconds
        }
        return key.requestID > lastRequest.requestID
    }

    private mutating func evict() {
        let dated = storage.values.compactMap(\.playedAt)
        if let newest = dated.max() {
            let cutoff = newest.addingTimeInterval(-policy.maxHistoryAge)
            storage = storage.filter { _, occurrence in
                occurrence.playedAt.map { $0 >= cutoff } ?? true
            }
        }
        let ordered = occurrences
        if ordered.count > policy.maxOccurrences {
            let keep = Set(ordered.suffix(policy.maxOccurrences).map(\.id))
            storage = storage.filter { keep.contains($0.key) }
        }
    }

    private static func validate(_ input: OccurrenceInput) throws {
        guard !input.station.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !input.kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              input.playedAt?.timeIntervalSince1970.isFinite ?? true else {
            throw StreamSessionError.invalid("occurrence identity or time")
        }
    }

    private static func revising(_ existing: Occurrence, with input: OccurrenceInput,
                                 received: Double) -> Occurrence {
        let candidate = Occurrence(id: existing.id, input: input,
                                   firstReceived: existing.firstReceivedElapsedSeconds,
                                   lastReceived: received,
                                   revision: existing.revision)
        let revision = materiallyDiffers(existing, candidate) ? existing.revision + 1 : existing.revision
        return Occurrence(id: existing.id, input: input,
                          firstReceived: existing.firstReceivedElapsedSeconds,
                          lastReceived: received, revision: revision)
    }

    private static func materiallyDiffers(_ lhs: Occurrence, _ rhs: Occurrence) -> Bool {
        lhs.station != rhs.station || lhs.providerID != rhs.providerID || lhs.kind != rhs.kind
            || lhs.title != rhs.title || lhs.artist != rhs.artist || lhs.album != rhs.album
            || lhs.artworkURL != rhs.artworkURL || lhs.playedAt != rhs.playedAt
    }

    private static func sortOccurrences(_ lhs: Occurrence, _ rhs: Occurrence) -> Bool {
        switch (lhs.playedAt, rhs.playedAt) {
        case let (left?, right?):
            if left != right { return left < right }
            return lhs.id.rawValue < rhs.id.rawValue
        case (.some, .none): return true
        case (.none, .some): return false
        case (.none, .none): return lhs.id.rawValue < rhs.id.rawValue
        }
    }
}

private struct RequestKey: Equatable, Sendable {
    let requestedElapsedSeconds: Double
    let requestID: Int
}

private enum OccurrenceIdentity {
    static func id(for input: OccurrenceInput) -> OccurrenceID {
        if let providerID = clean(input.providerID), !providerID.isEmpty {
            return OccurrenceID(rawValue: join([clean(input.station) ?? "", "provider", providerID]))
        }
        let timestamp = input.playedAt.map { String(Int64(($0.timeIntervalSince1970 * 1000).rounded())) } ?? "undated"
        return OccurrenceID(rawValue: join([
            clean(input.station) ?? "", "derived", timestamp, clean(input.kind) ?? "",
            clean(input.artist) ?? "", clean(input.title) ?? "",
        ]))
    }

    static func contentKey(for input: OccurrenceInput) -> String {
        contentKey(station: input.station, kind: input.kind, title: input.title, artist: input.artist)
    }

    static func contentKey(station: String, kind: String, title: String?, artist: String?) -> String {
        join([clean(station) ?? "", clean(kind) ?? "", clean(artist) ?? "", clean(title) ?? ""])
    }

    private static func clean(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func join(_ values: [String]) -> String {
        values.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}
