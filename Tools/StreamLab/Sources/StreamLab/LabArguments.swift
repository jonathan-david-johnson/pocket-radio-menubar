import Foundation
import StreamDiagnostics

struct CaptureOptions {
    let station: LabStation
    let streamURL: URL
    let feedURL: URL?
    let outputURL: URL
    let duration: Double
    let feedInterval: Double
    let muted: Bool

    init(_ arguments: [String]) throws {
        var values: [String: String] = [:]
        var flags = Set<String>()
        var index = 0
        let valueKeys: Set<String> = ["--station", "--stream-url", "--feed-url", "--output", "--duration", "--feed-interval"]
        while index < arguments.count {
            let key = arguments[index]
            if ["--muted", "--no-feed"].contains(key) {
                guard flags.insert(key).inserted else { throw UsageError("Duplicate option \(key)") }
                index += 1
            } else {
                guard valueKeys.contains(key), values[key] == nil, index + 1 < arguments.count,
                      !arguments[index + 1].hasPrefix("--") else { throw UsageError("Unknown, duplicate, or incomplete option") }
                values[key] = arguments[index + 1]
                index += 2
            }
        }
        guard let stationText = values["--station"], let station = LabStation(rawValue: stationText),
              let streamText = values["--stream-url"], let stream = URL(string: streamText),
              Self.validURL(stream, allowFile: true),
              let path = values["--output"], !path.isEmpty else {
            throw UsageError("Required: --station kcrw|kexp --stream-url URL --output FILE")
        }
        guard let duration = Double(values["--duration"] ?? "300"), duration.isFinite, (1...7200).contains(duration),
              let interval = Double(values["--feed-interval"] ?? "30"), interval.isFinite, (5...300).contains(interval) else {
            throw UsageError("Duration must be 1–7200 seconds; feed interval 5–300 seconds")
        }
        guard !(flags.contains("--no-feed") && values["--feed-url"] != nil) else {
            throw UsageError("Choose --feed-url or --no-feed, not both")
        }
        var feed = station.feedURL
        if let raw = values["--feed-url"] {
            guard let url = URL(string: raw), Self.validURL(url, allowFile: false) else { throw UsageError("Invalid feed URL") }
            feed = url
        }
        self.station = station
        self.streamURL = stream
        self.feedURL = flags.contains("--no-feed") ? nil : feed
        self.outputURL = URL(fileURLWithPath: path)
        self.duration = duration
        self.feedInterval = interval
        self.muted = flags.contains("--muted")
    }

    private static func validURL(_ url: URL, allowFile: Bool) -> Bool {
        if allowFile, url.isFileURL { return true }
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host?.isEmpty == false
    }
}

struct UsageError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
