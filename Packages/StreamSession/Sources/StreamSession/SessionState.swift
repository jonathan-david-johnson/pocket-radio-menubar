import Foundation

public enum DecisionTrigger: String, Codable, Equatable, Sendable {
    case feedUpdate
    case playerSample
}

public struct SessionDecision: Equatable, Sendable {
    public let elapsedSeconds: Double
    public let trigger: DecisionTrigger
    public let clock: MediaClockResult?
    public let selection: SelectionOutcome

    public init(elapsedSeconds: Double, trigger: DecisionTrigger,
                clock: MediaClockResult?, selection: SelectionOutcome) {
        self.elapsedSeconds = elapsedSeconds
        self.trigger = trigger
        self.clock = clock
        self.selection = selection
    }
}

public struct FeedMutation: Equatable, Sendable {
    public let update: HistoryUpdate
    public let decision: SessionDecision?

    public init(update: HistoryUpdate, decision: SessionDecision?) {
        self.update = update
        self.decision = decision
    }
}

public struct SessionState: Sendable {
    public private(set) var history: OccurrenceHistory
    public private(set) var mediaClock: MediaClock
    public let selector: OccurrenceSelector

    public init(historyPolicy: OccurrenceHistoryPolicy = OccurrenceHistoryPolicy(),
                selectionPolicy: OccurrenceSelectionPolicy = OccurrenceSelectionPolicy(),
                clockPolicy: MediaClockPolicy = MediaClockPolicy()) {
        history = OccurrenceHistory(policy: historyPolicy)
        mediaClock = MediaClock(policy: clockPolicy)
        selector = OccurrenceSelector(policy: selectionPolicy)
    }

    public mutating func receiveFeed(requestID: Int, requestedElapsedSeconds: Double,
                                     receivedElapsedSeconds: Double,
                                     entries: [OccurrenceInput]) throws -> FeedMutation {
        let update = try history.receive(requestID: requestID,
                                         requestedElapsedSeconds: requestedElapsedSeconds,
                                         receivedElapsedSeconds: receivedElapsedSeconds,
                                         entries: entries)
        return FeedMutation(update: update,
                            decision: decisionFromCurrentClock(at: receivedElapsedSeconds,
                                                               trigger: .feedUpdate))
    }

    public mutating func failFeed(requestID: Int, requestedElapsedSeconds: Double,
                                  receivedElapsedSeconds: Double,
                                  reason: String) throws -> FeedMutation {
        let update = try history.fail(requestID: requestID,
                                      requestedElapsedSeconds: requestedElapsedSeconds,
                                      receivedElapsedSeconds: receivedElapsedSeconds,
                                      reason: reason)
        return FeedMutation(update: update,
                            decision: decisionFromCurrentClock(at: receivedElapsedSeconds,
                                                               trigger: .feedUpdate))
    }

    public mutating func observePlayer(_ sample: MediaClockSample) -> SessionDecision {
        let clock = mediaClock.observe(sample)
        let selection: SelectionOutcome
        switch clock {
        case .valid(let valid):
            selection = selector.select(from: history,
                                        playerProgramDate: valid.programDate,
                                        playerElapsedSeconds: sample.elapsedSeconds)
        case .invalid:
            selection = .unavailable(.missingPlayerProgramDate)
        }
        return SessionDecision(elapsedSeconds: sample.elapsedSeconds,
                               trigger: .playerSample,
                               clock: clock,
                               selection: selection)
    }

    private func decisionFromCurrentClock(at elapsedSeconds: Double,
                                          trigger: DecisionTrigger) -> SessionDecision? {
        guard let clock = mediaClock.current else { return nil }
        return SessionDecision(elapsedSeconds: elapsedSeconds,
                               trigger: trigger,
                               clock: .valid(clock),
                               selection: selector.select(from: history,
                                                          playerProgramDate: clock.programDate,
                                                          playerElapsedSeconds: elapsedSeconds))
    }
}
