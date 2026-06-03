//
//  TrackFingerprinter.swift
//  PocketRadio Menubar
//
//  Captures ~15s of audio from the live stream URL (separate connection — no
//  AVPlayer tapping required) and sends the raw bytes to ACRCloud for
//  fingerprint-based track identification.
//
//  Usage:
//    1. Set TrackFingerprinter.credentials at app startup (once creds are ready).
//    2. Call start(streamURL:) when a live stream begins.
//    3. Observe onResult / onError callbacks on the main actor.
//    4. Call stop() when the stream stops or the user toggles back to Tracklist mode.
//
//  ACRCloud SDK integration is stubbed — see recognize(audioData:) below.
//  When the SDK is added to the project, uncomment the marked block and
//  delete the "SDK not integrated" error path.
//

import Foundation

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
        request.setValue("1", forHTTPHeaderField: "Icy-MetaData")

        do {
            let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)

            // Use icy-br to calculate exact byte target; fall back to 192kbps.
            let bitrateKbps = (response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "icy-br")
                .flatMap(Int.init) ?? 192
            let targetBytes = bitrateKbps * 1000 / 8 * Int(captureSeconds)

            var data = Data()
            data.reserveCapacity(targetBytes)
            for try await byte in asyncBytes {
                data.append(byte)
                if data.count >= targetBytes { break }
            }
            print("🎵 TrackFingerprinter: captured \(data.count) bytes (\(bitrateKbps)kbps × \(Int(captureSeconds))s)")
            return data.isEmpty ? nil : data
        } catch {
            print("🎵 TrackFingerprinter: capture error: \(error)")
            return nil
        }
    }

    // MARK: - ACRCloud recognition

    private func recognize(audioData: Data) async {
        guard let creds = Self.credentials else {
            await fireError("ACRCloud credentials not set — assign TrackFingerprinter.credentials at startup")
            return
        }

        // ─────────────────────────────────────────────────────────────────────
        // TODO: Replace this stub once ACRCloudSDK.xcframework is added to the
        //       Xcode project (drag into Frameworks, General → Embed & Sign).
        //
        // 1. Add to Podfile or drag in the .xcframework from acrcloud.com.
        // 2. Add to Info.plist if needed: NSMicrophoneUsageDescription (even for
        //    file-based recognition on some SDK versions).
        // 3. Uncomment and delete the fireError call below:
        //
        //   import ACRCloudSDK
        //
        //   let config = ACRCloudConfig()
        //   config.host           = creds.host
        //   config.accessKey      = creds.accessKey
        //   config.accessSecret   = creds.accessSecret
        //   config.recMode        = .remoteRecognize  // no mic
        //
        //   let recognizer = ACRCloudRecognizer(config: config)
        //   // recognizeWithAudio accepts raw MP3/AAC bytes (not just PCM)
        //   let jsonStr = recognizer.recognizeWithAudio(audioData, withPCMSampleRate: 0)
        //   guard let jsonStr,
        //         let jsonData = jsonStr.data(using: .utf8),
        //         let result = parseACRCloudResult(jsonData) else {
        //       await fireError("No match or parse error")
        //       return
        //   }
        //   if result.confidence >= minConfidence {
        //       await fireResult(result)
        //   } else {
        //       await fireError("Low confidence: \(result.confidence) for \(result.title)")
        //   }
        //
        // ─────────────────────────────────────────────────────────────────────

        _ = creds  // suppress unused warning until stub is replaced
        await fireError("ACRCloud SDK not yet integrated — add ACRCloudSDK.xcframework and uncomment TrackFingerprinter.recognize()")
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
        print("🎵 TrackFingerprinter: \(message)")
        await MainActor.run { onError?(message) }
    }
}
