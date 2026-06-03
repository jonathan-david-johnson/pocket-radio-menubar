//
//  TrackFingerprinter.swift
//  PocketRadio Menubar
//
//  Captures ~15s of audio from the live stream URL (separate connection — no
//  AVPlayer tapping required) and sends the raw bytes to ACRCloud for
//  fingerprint-based track identification via the REST Identification API.
//
//  Usage:
//    1. Set TrackFingerprinter.credentials at app startup.
//    2. Call start(streamURL:) when a live stream begins.
//    3. Observe onResult / onError callbacks on the main actor.
//    4. Call stop() when the stream stops or the user toggles back to Tracklist mode.
//

import CryptoKit
import Foundation
import OSLog

private let acrLog = Logger(subsystem: "com.jdj.pocketradio", category: "ACR")

// MARK: - Mode

enum TrackIdentificationMode {
    case tracklist  // station's native tracklist API (KCRW/KEXP) — default
    case acr        // ACRCloud audio fingerprint
}

// MARK: - Credentials

struct ACRCloudCredentials {
    /// e.g. "identify-eu-west-1.acrcloud.com"
    let host: String
    let accessKey: String
    let accessSecret: String
}

// MARK: - Result

struct TrackFingerprintResult {
    let title: String
    let artist: String
    let album: String
    /// ACRCloud confidence score 0–100
    let confidence: Int

    var displayTitle: String {
        artist.isEmpty ? title : "\(title) — \(artist)"
    }
}

// MARK: - Fingerprinter

final class TrackFingerprinter {

    // Set once at app startup (e.g. in PocketRadioApp.init).
    static var credentials: ACRCloudCredentials?

    /// Fired on the main actor when a track is identified with confidence >= minConfidence.
    var onResult: ((TrackFingerprintResult) -> Void)?
    /// Fired on the main actor on non-fatal errors (network, no match, missing creds).
    var onError: ((String) -> Void)?

    /// Minimum ACRCloud confidence score to surface a result (default 70).
    var minConfidence: Int = 70
    /// How often to fingerprint while running (default 30s).
    var pollInterval: TimeInterval = 30
    /// Seconds of audio to capture per fingerprint attempt (default 15).
    var captureSeconds: Double = 15

    private let streamURL: URL
    private var pollTask: Task<Void, Never>?

    init(streamURL: URL) {
        self.streamURL = streamURL
    }

    /// One-shot: capture once and call onResult/onError exactly once.
    func identifyOnce() {
        stop()
        pollTask = Task { [weak self] in
            await self?.captureAndRecognize()
        }
    }

    func start() {
        stop()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.captureAndRecognize()
                guard let interval = self?.pollInterval else { return }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Capture

    private func captureAndRecognize() async {
        guard let data = await captureAudioBytes() else {
            await fireError("Failed to capture audio from \(streamURL.host ?? streamURL.absoluteString)")
            return
        }
        await recognize(audioData: data)
    }

    /// Opens a separate HTTP connection to the stream URL and reads enough
    /// bytes for ~captureSeconds of audio. Returns raw MP3/AAC bytes.
    /// ACRCloud accepts these directly — no PCM conversion needed.
    private func captureAudioBytes() async -> Data? {
        var request = URLRequest(url: streamURL, timeoutInterval: 30)
        request.setValue("PocketRadio-Fingerprinter/1.0", forHTTPHeaderField: "User-Agent")
        // Do NOT request ICY metadata — injected title chunks corrupt the audio fingerprint.

        do {
            let (asyncBytes, _) = try await URLSession.shared.bytes(for: request)

            // Capture by wall-clock duration — avoids bitrate header guessing for
            // MP3, AAC, and other formats where icy-br may be absent or wrong.
            let deadline = Date().addingTimeInterval(captureSeconds)
            var data = Data()
            data.reserveCapacity(2_000_000)  // 2MB headroom
            for try await byte in asyncBytes {
                data.append(byte)
                if Date() >= deadline { break }
            }
            acrLog.debug("captured \(data.count) bytes in \(Int(self.captureSeconds))s")
            return data.isEmpty ? nil : data
        } catch {
            acrLog.error("capture error: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - ACRCloud recognition

    private func recognize(audioData: Data) async {
        guard let creds = Self.credentials else {
            await fireError("ACRCloud credentials not set — assign TrackFingerprinter.credentials at startup")
            return
        }

        let timestamp = String(Int(Date().timeIntervalSince1970))
        let httpURI = "/v1/identify"
        let stringToSign = ["POST", httpURI, creds.accessKey, "audio", "1", timestamp]
            .joined(separator: "\n")

        acrLog.debug("ts=\(timestamp, privacy: .public) key=\(creds.accessKey, privacy: .public) secret.count=\(creds.accessSecret.count)")
        let key = SymmetricKey(data: Data(creds.accessSecret.utf8))
        let mac = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(stringToSign.utf8), using: key)
        let signature = Data(mac).base64EncodedString()
        acrLog.debug("signature: \(signature, privacy: .public)")

        let boundary = "PocketRadioACR\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var body = Data()

        func field(_ name: String, _ value: String) {
            body += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
                .data(using: .utf8)!
        }

        field("access_key", creds.accessKey)
        field("sample_bytes", String(audioData.count))
        field("timestamp", timestamp)
        field("signature", signature)
        field("data_type", "audio")
        field("signature_version", "1")

        body += "--\(boundary)\r\nContent-Disposition: form-data; name=\"sample\"; filename=\"sample.mp3\"\r\nContent-Type: application/octet-stream\r\n\r\n"
            .data(using: .utf8)!
        body += audioData
        body += "\r\n--\(boundary)--\r\n".data(using: .utf8)!

        guard let url = URL(string: "https://\(creds.host)\(httpURI)") else {
            await fireError("Invalid ACRCloud host: \(creds.host)")
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        acrLog.debug("posting \(audioData.count) audio bytes, body=\(body.count) total")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
            acrLog.debug("ACR HTTP \(httpStatus), response \(data.count) bytes")
            guard let result = parseACRCloudResult(data) else {
                if let raw = String(data: data, encoding: .utf8) {
                    await fireError("No match — \(raw)")
                } else {
                    await fireError("No match")
                }
                return
            }
            if result.confidence >= minConfidence {
                await fireResult(result)
            } else {
                await fireError("Low confidence (\(result.confidence)) for \(result.title)")
            }
        } catch {
            await fireError("Network error: \(error.localizedDescription)")
        }
    }

    // MARK: - JSON parsing

    private func parseACRCloudResult(_ data: Data) -> TrackFingerprintResult? {
        // ACRCloud response shape:
        // { "status": { "code": 0 },
        //   "metadata": { "music": [{ "title": "...", "artists": [{"name":"..."}],
        //                             "album": {"name":"..."}, "score": 87 }] } }
        guard
            let json     = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let status   = json["status"]   as? [String: Any],
            (status["code"] as? Int) == 0,
            let metadata = json["metadata"] as? [String: Any],
            let music    = metadata["music"] as? [[String: Any]],
            let top      = music.first
        else { return nil }

        let title  = top["title"]   as? String ?? ""
        let artist = (top["artists"] as? [[String: Any]])?.first?["name"] as? String ?? ""
        let album  = (top["album"]  as? [String: Any])?["name"] as? String ?? ""
        let score  = top["score"]   as? Int ?? 0

        return TrackFingerprintResult(title: title, artist: artist, album: album, confidence: score)
    }

    // MARK: - Helpers

    private func fireResult(_ result: TrackFingerprintResult) async {
        await MainActor.run { onResult?(result) }
    }

    private func fireError(_ message: String) async {
        acrLog.debug("\(message, privacy: .public)")
        await MainActor.run { onError?(message) }
    }
}
