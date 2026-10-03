import Foundation
import StreamSession

/// Session-only M11-B configuration. Never persisted to station records or saved offsets.
enum StreamExperimentMode: String, CaseIterable {
    case off = "Off"
    case observeOnly = "Observe only"
    case applyCandidate = "Apply candidate"
}

struct StreamExperimentConfiguration {
    static let measuredEndpoint = URL(string: "https://streams.kcrw.com/e24_aac/playlist.m3u8")!
    static let feedEndpoint = URL(string: "https://tracklist-api.kcrw.com/Music/all/1?page_size=5")!
    static let selectionPolicy = OccurrenceSelectionPolicy(feedToProgramOffset: 160,
                                                            maxSelectedAge: 1200,
                                                            maxFeedSilence: 120)
    static let historyPolicy = OccurrenceHistoryPolicy(maxOccurrences: 100,
                                                        maxHistoryAge: 6 * 60 * 60,
                                                        correctionWindow: 120)
    static let clockPolicy = MediaClockPolicy(correlationTolerance: 2, progressionTolerance: 2)

    /// Restrict the override to the measured Eclectic24 stream, not another station
    /// whose name happens to contain KCRW. Never print or match query credentials.
    /// A stable reason helps diagnose radio-browser records without widening scope.
    static func ineligibilityReason(for station: RadioStation) -> String? {
        guard station.name.lowercased().contains("kcrw") else {
            return "station name does not identify KCRW"
        }
        guard let url = URL(string: station.streamURL),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "station stream URL is invalid"
        }
        guard components.query == nil, components.fragment == nil,
              components.user == nil, components.password == nil else {
            return "station stream URL contains credentials, query, or fragment"
        }
        guard ["https", "http"].contains(components.scheme?.lowercased() ?? "") else {
            return "station stream scheme is unsupported"
        }
        guard components.host?.lowercased() == "streams.kcrw.com" else {
            return "station stream host is not the measured host"
        }
        // /e24_aac is the curated AAC radio-browser source. It is only an
        // identity match: Observe still plays the measured HLS playlist below.
        guard ["/e24_mp3", "/e24_aac", "/e24_aac/playlist.m3u8"].contains(components.path) else {
            return "station stream path is not the known Eclectic24 variant"
        }
        return nil
    }

    static func isEligible(_ station: RadioStation) -> Bool {
        ineligibilityReason(for: station) == nil
    }

    static func resolvedURL(for station: RadioStation, mode: StreamExperimentMode) -> URL? {
        if mode != .off, isEligible(station) { return measuredEndpoint }
        return URL(string: station.streamURL)
    }
}
