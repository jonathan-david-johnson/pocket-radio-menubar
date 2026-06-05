import Foundation

struct LyricLine {
    let timestamp: TimeInterval
    let text: String
}

struct LyricsResult {
    let lines: [LyricLine]
    let plain: String?

    var hasSynced: Bool { !lines.isEmpty }
}

final class LyricsService {
    static let shared = LyricsService()

    private var cache: [String: LyricsResult] = [:]

    private init() {}

    func fetch(artist: String, title: String, album: String?) async -> LyricsResult? {
        let key = cacheKey(artist: artist, title: title)
        if let cached = cache[key] { return cached }

        var components = URLComponents(string: "https://lrclib.net/api/get")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title),
        ]
        if let album, !album.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: album))
        }
        components.queryItems = items

        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

            let synced = json["syncedLyrics"] as? String
            let plain = json["plainLyrics"] as? String

            let lines = synced.map { parseLRC($0) } ?? []
            let result = LyricsResult(lines: lines, plain: plain)
            cache[key] = result
            return result
        } catch {
            return nil
        }
    }

    func currentLine(in result: LyricsResult, at offset: TimeInterval) -> LyricLine? {
        guard !result.lines.isEmpty else { return nil }
        // Find last line whose timestamp <= offset
        var lo = 0, hi = result.lines.count - 1
        var match: LyricLine? = nil
        while lo <= hi {
            let mid = (lo + hi) / 2
            if result.lines[mid].timestamp <= offset {
                match = result.lines[mid]
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return match
    }

    // MARK: - LRC parser

    private func parseLRC(_ raw: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[") else { continue }
            guard let close = trimmed.firstIndex(of: "]") else { continue }
            let tagContent = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let text = String(trimmed[trimmed.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            if let ts = parseTimestamp(tagContent) {
                lines.append(LyricLine(timestamp: ts, text: text))
            }
        }
        return lines.sorted { $0.timestamp < $1.timestamp }
    }

    // Parses "mm:ss.xx" → TimeInterval in seconds
    private func parseTimestamp(_ s: String) -> TimeInterval? {
        let parts = s.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let minutes = Double(parts[0]),
              let seconds = Double(parts[1]) else { return nil }
        return minutes * 60 + seconds
    }

    private func cacheKey(artist: String, title: String) -> String {
        "\(artist.lowercased())|\(title.lowercased())"
    }

    func clearCache() {
        cache.removeAll()
    }
}
