import Foundation

public struct MediaClockPolicy: Codable, Equatable, Sendable {
    public let correlationTolerance: TimeInterval
    public let progressionTolerance: TimeInterval

    public init(correlationTolerance: TimeInterval = 2,
                progressionTolerance: TimeInterval = 2) {
        self.correlationTolerance = correlationTolerance
        self.progressionTolerance = progressionTolerance
    }
}

public struct MediaClockSample: Equatable, Sendable {
    public let generation: String
    public let elapsedSeconds: Double
    public let mediaSeconds: Double?
    public let programDate: Date?
    public let isAdvancing: Bool

    public init(generation: String, elapsedSeconds: Double, mediaSeconds: Double?,
                programDate: Date?, isAdvancing: Bool) {
        self.generation = generation
        self.elapsedSeconds = elapsedSeconds
        self.mediaSeconds = mediaSeconds
        self.programDate = programDate
        self.isAdvancing = isAdvancing
    }
}

public struct ValidMediaClock: Equatable, Sendable {
    public let generation: String
    public let elapsedSeconds: Double
    public let mediaSeconds: Double
    public let programDate: Date

    public init(generation: String, elapsedSeconds: Double, mediaSeconds: Double,
                programDate: Date) {
        self.generation = generation
        self.elapsedSeconds = elapsedSeconds
        self.mediaSeconds = mediaSeconds
        self.programDate = programDate
    }
}

public enum MediaClockInvalidReason: String, Codable, Equatable, Sendable {
    case missingPair
    case nonfinitePair
    case backwardJump
    case correlationDiscontinuity
    case mediaProgressionDiscontinuity
}

public enum MediaClockResult: Equatable, Sendable {
    case valid(ValidMediaClock)
    case invalid(MediaClockInvalidReason)
}

public struct MediaClock: Sendable {
    public let policy: MediaClockPolicy
    public private(set) var generation: String?
    public private(set) var current: ValidMediaClock?

    private var anchor: Pair?
    private var previous: Pair?

    public init(policy: MediaClockPolicy = MediaClockPolicy()) {
        self.policy = policy
    }

    public mutating func reset() {
        generation = nil
        current = nil
        anchor = nil
        previous = nil
    }

    public mutating func observe(_ sample: MediaClockSample) -> MediaClockResult {
        guard let media = sample.mediaSeconds, let observedProgram = sample.programDate else {
            invalidate()
            return .invalid(.missingPair)
        }
        guard !sample.generation.isEmpty,
              sample.elapsedSeconds.isFinite, media.isFinite,
              observedProgram.timeIntervalSince1970.isFinite,
              policy.correlationTolerance.isFinite, policy.correlationTolerance >= 0,
              policy.progressionTolerance.isFinite, policy.progressionTolerance >= 0 else {
            invalidate()
            return .invalid(.nonfinitePair)
        }

        let pair = Pair(generation: sample.generation,
                        elapsedSeconds: sample.elapsedSeconds,
                        mediaSeconds: media,
                        observedProgramDate: observedProgram,
                        isAdvancing: sample.isAdvancing)

        if generation != sample.generation || anchor == nil || previous == nil {
            generation = sample.generation
            anchor = pair
            previous = pair
            let valid = pair.valid(programDate: observedProgram)
            current = valid
            return .valid(valid)
        }

        guard let anchor, let previous else {
            invalidate()
            return .invalid(.missingPair)
        }
        let elapsedDelta = pair.elapsedSeconds - previous.elapsedSeconds
        let mediaDelta = pair.mediaSeconds - previous.mediaSeconds
        let programDelta = pair.observedProgramDate.timeIntervalSince(previous.observedProgramDate)
        guard elapsedDelta >= 0, mediaDelta >= -0.001,
              programDelta >= -policy.correlationTolerance else {
            invalidate()
            return .invalid(.backwardJump)
        }
        guard abs(programDelta - mediaDelta) <= policy.correlationTolerance else {
            invalidate()
            return .invalid(.correlationDiscontinuity)
        }
        let jumpedForwardFasterThanElapsed = mediaDelta - elapsedDelta > policy.progressionTolerance
        let fellBehindWhilePlaying = pair.isAdvancing && previous.isAdvancing
            && elapsedDelta - mediaDelta > policy.progressionTolerance
        if jumpedForwardFasterThanElapsed || fellBehindWhilePlaying {
            invalidate()
            return .invalid(.mediaProgressionDiscontinuity)
        }

        let correlatedProgram = anchor.observedProgramDate.addingTimeInterval(pair.mediaSeconds - anchor.mediaSeconds)
        guard abs(observedProgram.timeIntervalSince(correlatedProgram)) <= policy.correlationTolerance else {
            invalidate()
            return .invalid(.correlationDiscontinuity)
        }
        self.previous = pair
        let valid = pair.valid(programDate: correlatedProgram)
        current = valid
        return .valid(valid)
    }

    private mutating func invalidate() {
        generation = nil
        current = nil
        anchor = nil
        previous = nil
    }
}

private struct Pair: Sendable {
    let generation: String
    let elapsedSeconds: Double
    let mediaSeconds: Double
    let observedProgramDate: Date
    let isAdvancing: Bool

    func valid(programDate: Date) -> ValidMediaClock {
        ValidMediaClock(generation: generation, elapsedSeconds: elapsedSeconds,
                        mediaSeconds: mediaSeconds, programDate: programDate)
    }
}
