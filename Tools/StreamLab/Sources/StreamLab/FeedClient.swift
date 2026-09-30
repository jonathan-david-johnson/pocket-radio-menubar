import Foundation
import StreamDiagnostics

/// No ambient cookies, account headers, disk cache, or backend credentials.
final class FeedClient {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration)
    }

    func cancel() { session.invalidateAndCancel() }

    func fetch(url: URL, station: LabStation, requestID: Int, requestedAt: Double) async -> FeedObservation {
        var status: Int?
        var headers: [String: String] = [:]
        var data = Data()
        do {
            let (bytes, response) = try await session.bytes(from: url)
            if let http = response as? HTTPURLResponse {
                status = http.statusCode
                for name in ["Date", "Age", "Cache-Control", "Last-Modified", "Content-Type"] {
                    if let value = http.value(forHTTPHeaderField: name) {
                        headers[name.lowercased()] = TracePrivacy.metadata(value)
                    }
                }
            }
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 1_048_576 else { throw TraceError.invalid("feed exceeds 1 MiB") }
                data.append(byte)
            }
            guard let status, (200..<300).contains(status) else { throw TraceError.invalid("feed HTTP status") }
            let entries = try StationFeed.decode(data, station: station)
            return FeedObservation(requestID: requestID, requestedElapsedSeconds: requestedAt, statusCode: status,
                                   headers: headers, bodyBytes: data.count, entries: entries, failure: nil)
        } catch {
            // Error descriptions can include signed URLs. Persist domain/code only.
            let nsError = error as NSError
            let failure = error is TraceError ? String(describing: error) : "\(nsError.domain):\(nsError.code)"
            return FeedObservation(requestID: requestID, requestedElapsedSeconds: requestedAt, statusCode: status,
                                   headers: headers, bodyBytes: data.count, entries: [], failure: failure)
        }
    }
}
