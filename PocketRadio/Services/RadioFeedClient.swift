import Foundation
import StreamDiagnostics

/// Dedicated experimental feed path. Unlike the legacy API it returns raw entries
/// (including breaks) before artwork lookup and distinguishes errors from empty data.
struct RadioFeedResult {
    let entries: [FeedEntry]
    let statusCode: Int?
    let cacheAgeSeconds: Double?
    let failure: String?
    let headers: [String: String]
    let bodyBytes: Int

    init(entries: [FeedEntry], statusCode: Int?, cacheAgeSeconds: Double?, failure: String?,
         headers: [String: String] = [:], bodyBytes: Int = 0) {
        self.entries = entries
        self.statusCode = statusCode
        self.cacheAgeSeconds = cacheAgeSeconds
        self.failure = failure
        self.headers = headers
        self.bodyBytes = bodyBytes
    }
}

final class RadioFeedClient {
    private let session: URLSession

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func fetch() async -> RadioFeedResult {
        var request = URLRequest(url: StreamExperimentConfiguration.feedEndpoint)
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 12
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return RadioFeedResult(entries: [], statusCode: nil, cacheAgeSeconds: nil,
                                       failure: "non-HTTP response")
            }
            let age = http.value(forHTTPHeaderField: "Age").flatMap(Double.init)
            let validAge = age.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            var headers: [String: String] = [:]
            for key in ["age", "date", "cache-control", "content-type"] {
                if let value = http.value(forHTTPHeaderField: key) {
                    headers[key] = String(value.prefix(256))
                }
            }
            guard (200..<300).contains(http.statusCode) else {
                return RadioFeedResult(entries: [], statusCode: http.statusCode,
                                       cacheAgeSeconds: validAge, failure: "HTTP \(http.statusCode)",
                                       headers: headers, bodyBytes: data.count)
            }
            guard data.count <= 256 * 1024 else {
                return RadioFeedResult(entries: [], statusCode: http.statusCode,
                                       cacheAgeSeconds: validAge, failure: "feed body limit exceeded",
                                       headers: headers, bodyBytes: data.count)
            }
            let entries = try StationFeed.decode(data, station: .kcrw)
            guard entries.count <= 100 else {
                return RadioFeedResult(entries: [], statusCode: http.statusCode,
                                       cacheAgeSeconds: validAge, failure: "feed row limit exceeded",
                                       headers: headers, bodyBytes: data.count)
            }
            return RadioFeedResult(entries: entries, statusCode: http.statusCode,
                                   cacheAgeSeconds: validAge, failure: nil,
                                   headers: headers, bodyBytes: data.count)
        } catch {
            // Do not include URLSession's error description: it may contain a URL.
            return RadioFeedResult(entries: [], statusCode: nil, cacheAgeSeconds: nil,
                                   failure: "feed request or decode failed")
        }
    }
}
