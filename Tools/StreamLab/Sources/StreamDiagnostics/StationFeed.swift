import Foundation

public enum LabStation: String, Codable, CaseIterable {
    case kcrw, kexp

    public var feedURL: URL {
        switch self {
        case .kcrw: return URL(string: "https://tracklist-api.kcrw.com/Music/all/1?page_size=10")!
        case .kexp: return URL(string: "https://api.kexp.org/v2/plays/?limit=10")!
        }
    }
}

public struct FeedEntry: Codable, Equatable {
    public let providerID: String?
    public let kind: String
    public let title: String?
    public let artist: String?
    public let album: String?
    public let artworkURL: String?
    public let providerTimestamp: String?
    /// Parsed provider UTC time at the trace contract's millisecond resolution.
    public let playedAt: Date?
}

public enum StationFeed {
    /// Preserve source order and non-music entries. No row is declared audible.
    public static func decode(_ data: Data, station: LabStation) throws -> [FeedEntry] {
        let json = try JSONSerialization.jsonObject(with: data)
        let rows: [[String: Any]]
        switch station {
        case .kcrw:
            guard let array = json as? [[String: Any]] else { throw TraceError.invalid("KCRW feed shape") }
            rows = array
        case .kexp:
            guard let dictionary = json as? [String: Any], let array = dictionary["results"] as? [[String: Any]] else {
                throw TraceError.invalid("KEXP feed shape")
            }
            rows = array
        }
        let basic = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return rows.map { row in
            func text(_ key: String) -> String? { (row[key] as? String).map(TracePrivacy.metadata) }
            let title = text(station == .kcrw ? "title" : "song")
            let artist = text("artist")
            let rawTime = text(station == .kcrw ? "datetime" : "airdate")
            let artwork = ["albumImageLarge", "albumImage", "thumbnail_uri"]
                .compactMap { row[$0] as? String }
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let kind: String
            if station == .kexp {
                kind = text("play_type") ?? "unknown"
            } else if [title, artist].compactMap({ $0 }).contains(where: { $0.uppercased().contains("[BREAK]") }) {
                kind = "break"
            } else {
                kind = title?.isEmpty == false && artist?.isEmpty == false ? "trackplay" : "unknown"
            }
            let id = (row["id"] as? NSNumber)?.stringValue ?? text("id")
            let playedAt = rawTime
                .flatMap { fractional.date(from: $0) ?? basic.date(from: $0) }
                .map(TraceDate.snapToMilliseconds)
            return FeedEntry(providerID: id, kind: kind, title: title, artist: artist, album: text("album"),
                             artworkURL: artwork.map(TracePrivacy.url), providerTimestamp: rawTime,
                             playedAt: playedAt)
        }
    }
}
