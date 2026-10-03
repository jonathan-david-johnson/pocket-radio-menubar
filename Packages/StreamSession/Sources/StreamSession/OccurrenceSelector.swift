import Foundation

public struct OccurrenceSelectionPolicy: Codable, Equatable, Sendable {
    public let feedToProgramOffset: TimeInterval
    public let maxSelectedAge: TimeInterval
    public let maxFeedSilence: TimeInterval

    public init(feedToProgramOffset: TimeInterval = 160,
                maxSelectedAge: TimeInterval = 20 * 60,
                maxFeedSilence: TimeInterval = 2 * 60) {
        self.feedToProgramOffset = feedToProgramOffset
        self.maxSelectedAge = maxSelectedAge
        self.maxFeedSilence = maxFeedSilence
    }
}

public struct OccurrenceSelection: Equatable, Sendable {
    public let occurrence: Occurrence
    public let estimatedStart: Date
    public let songSeconds: TimeInterval

    public init(occurrence: Occurrence, estimatedStart: Date, songSeconds: TimeInterval) {
        self.occurrence = occurrence
        self.estimatedStart = estimatedStart
        self.songSeconds = songSeconds
    }
}

public enum SelectionUnavailableReason: String, Codable, Equatable, Sendable {
    case missingPlayerProgramDate
    case nonfiniteInput
    case noHistory
    case ambiguousHistory
    case staleFeed
    case historyBeginsAfterPlayer
    case selectedOccurrenceTooOld
}

public enum SelectionOutcome: Equatable, Sendable {
    case selected(OccurrenceSelection)
    case unavailable(SelectionUnavailableReason)
}

public struct OccurrenceSelector: Sendable {
    public let policy: OccurrenceSelectionPolicy

    public init(policy: OccurrenceSelectionPolicy = OccurrenceSelectionPolicy()) {
        self.policy = policy
    }

    public func select(from history: OccurrenceHistory, playerProgramDate: Date?,
                       playerElapsedSeconds: Double) -> SelectionOutcome {
        guard let playerProgramDate else { return .unavailable(.missingPlayerProgramDate) }
        guard playerProgramDate.timeIntervalSince1970.isFinite,
              playerElapsedSeconds.isFinite,
              policy.feedToProgramOffset.isFinite,
              policy.maxSelectedAge.isFinite, policy.maxSelectedAge >= 0,
              policy.maxFeedSilence.isFinite, policy.maxFeedSilence >= 0 else {
            return .unavailable(.nonfiniteInput)
        }
        guard !history.hasAmbiguousCorrection else { return .unavailable(.ambiguousHistory) }
        guard !history.occurrences.isEmpty else { return .unavailable(.noHistory) }
        guard let lastSuccess = history.lastSuccessfulReceivedElapsedSeconds else {
            return .unavailable(.noHistory)
        }
        if playerElapsedSeconds - lastSuccess > policy.maxFeedSilence {
            return .unavailable(.staleFeed)
        }

        let eligible = history.occurrences.compactMap { occurrence -> (Occurrence, Date)? in
            guard let playedAt = occurrence.playedAt else { return nil }
            let estimatedStart = playedAt.addingTimeInterval(policy.feedToProgramOffset)
            guard estimatedStart <= playerProgramDate else { return nil }
            return (occurrence, estimatedStart)
        }
        guard let (occurrence, estimatedStart) = eligible.max(by: { $0.1 < $1.1 }) else {
            return .unavailable(.historyBeginsAfterPlayer)
        }
        let songSeconds = playerProgramDate.timeIntervalSince(estimatedStart)
        guard songSeconds <= policy.maxSelectedAge else {
            return .unavailable(.selectedOccurrenceTooOld)
        }
        return .selected(OccurrenceSelection(occurrence: occurrence,
                                             estimatedStart: estimatedStart,
                                             songSeconds: songSeconds))
    }
}
