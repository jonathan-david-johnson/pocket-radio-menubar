import Foundation

// Supabase Realtime Phoenix WebSocket receiver (protocol v2 — JSON array frames).
// Wire format: [joinRef, ref, topic, event, payload]
@MainActor
final class RemoteControlService {
    private static let supabaseHost = "brvtspdculqyvdrmdtef.supabase.co"
    private static let anonKey = "sb_publishable_1MRvFzvB6O7f2zDPfs2nkA_p18FSLUF"

    private let deviceIdKey = "pocketradio-device-id"

    weak var player: PlayerViewModel?

    private var userId: String = ""
    private var channelTopic: String = ""
    private var joinRef: String = ""
    private var refCounter: Int = 0
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var seenCommandIds: Set<String> = []

    var deviceId: String {
        let key = deviceIdKey
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }

    func start(userId: String) {
        stop()
        self.userId = userId
        self.channelTopic = "realtime:remote:\(userId)"
        connect()
    }

    func stop() {
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        receiveTask = nil
        heartbeatTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        userId = ""
        channelTopic = ""
        seenCommandIds = []
    }

    func trackPresence() {
        guard task != nil else { return }
        sendPresence()
    }

    // MARK: - Private

    private func connect() {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = Self.supabaseHost
        components.path = "/realtime/v1/websocket"
        components.queryItems = [
            URLQueryItem(name: "apikey", value: Self.anonKey),
            URLQueryItem(name: "vsn", value: "2.0.0"),
        ]
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.setValue(Self.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(Self.anonKey)", forHTTPHeaderField: "Authorization")

        let ws = URLSession.shared.webSocketTask(with: request)
        task = ws

        receiveTask = Task { [weak self] in
            guard let self else { return }
            ws.resume()
            await self.joinChannel()
            await self.receiveLoop(ws: ws)
        }

        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { break }
                self?.sendHeartbeat()
            }
        }
    }

    private func joinChannel() async {
        joinRef = nextRef()
        let payload: [String: Any] = [
            "config": [
                "broadcast": ["ack": false, "self": false],
                "presence": ["key": deviceId, "enabled": true],
                "postgres_changes": [] as [Any]
            ],
            "access_token": Self.anonKey
        ]
        send(joinRef: joinRef, ref: joinRef, topic: channelTopic, event: "phx_join", payload: payload)
        print("🌐 RemoteControl: joining channel=\(channelTopic) device=\(deviceId)")
    }

    private func receiveLoop(ws: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await ws.receive()
                switch message {
                case .string(let text):
                    handleFrame(text)
                case .data:
                    break
                @unknown default:
                    break
                }
            } catch {
                print("🌐 RemoteControl: receive error: \(error)")
                break
            }
        }
    }

    private func handleFrame(_ text: String) {
        guard let data = text.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              array.count >= 5 else { return }
        let ref = array[1] as? String ?? ""
        let event = array[3] as? String ?? ""
        let payload = array[4] as? [String: Any] ?? [:]

        switch event {
        case "phx_reply":
            // Only the join reply (ref == joinRef) means "channel joined".
            // Presence/heartbeat sends also get phx_reply:ok — replying to those
            // with sendPresence() would create a feedback loop.
            guard ref == joinRef else { break }
            let status = (payload["status"] as? String) ?? ""
            if status == "ok" {
                print("🌐 RemoteControl: channel joined ok")
                sendPresence()
            }
        case "broadcast":
            guard let broadcastEvent = payload["event"] as? String,
                  broadcastEvent == "command",
                  let cmdPayload = payload["payload"] as? [String: Any] else { return }
            handleCommand(cmdPayload)
        case "presence_diff":
            let joins = (payload["joins"] as? [String: Any]) ?? [:]
            let leaves = (payload["leaves"] as? [String: Any]) ?? [:]
            print("🌐 RemoteControl: presence_diff joins=\(joins.count) leaves=\(leaves.count)")
            for key in joins.keys { print("🌐 RemoteControl:   join device=\(key)") }
            for key in leaves.keys { print("🌐 RemoteControl:   leave device=\(key)") }
        case "presence_state":
            print("🌐 RemoteControl: presence_state devices=\((payload.keys).joined(separator: ","))")
        default:
            break
        }
    }

    private func handleCommand(_ raw: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: raw),
              let cmd = try? JSONDecoder().decode(RemoteCommand.self, from: data) else {
            print("🌐 RemoteControl: failed to decode command: \(raw["command"] ?? "?")")
            return
        }
        guard cmd.targetDeviceId == deviceId else { return }
        guard !seenCommandIds.contains(cmd.commandId) else {
            print("🌐 RemoteControl: dropping duplicate commandId=\(cmd.commandId)")
            return
        }
        seenCommandIds.insert(cmd.commandId)
        print("🌐 RemoteControl: received command=\(cmd.command.rawValue) from=\(cmd.fromDeviceId) id=\(cmd.commandId)")

        guard let player else { return }
        switch cmd.command {
        case .play:
            if !player.isPlaying { player.togglePlayback() }
        case .pause, .stop:
            if player.isPlaying { player.togglePlayback() }
        case .loadStation:
            if let p = cmd.payload,
               let stationUrl = p.stationUrl,
               let stationName = p.stationName,
               let stationId = p.stationId {
                let station = RadioStation(id: stationId, name: stationName, streamURL: stationUrl, logoURL: nil)
                player.playStation(station)
            }
        }

        sendPresence()
    }

    // MARK: - Sending

    private func sendPresence() {
        guard let player else { return }
        let state: PlaybackState
        if player.isPlaying {
            state = .playing
        } else if player.currentSource != nil {
            state = .paused
        } else {
            state = .idle
        }

        var stationId: String?
        var stationName: String?
        if case .radio(let s) = player.currentSource {
            stationId = s.id
            stationName = s.name
        }

        let deviceName = Host.current().localizedName ?? "Mac"
        let presence = RemotePresence(
            deviceId: deviceId,
            deviceType: "macos",
            deviceName: deviceName,
            role: "receiver",
            playback: RemotePlaybackState(state: state, stationId: stationId, stationName: stationName, artworkUrl: nil),
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )

        // Transport boundary: send() takes [String:Any]. Bounce through JSON.
        guard let presenceData = try? JSONEncoder().encode(presence),
              let presenceDict = try? JSONSerialization.jsonObject(with: presenceData) as? [String: Any] else { return }

        let presencePayload: [String: Any] = [
            "type": "presence",
            "event": "track",
            "payload": presenceDict
        ]
        send(joinRef: joinRef, ref: nextRef(), topic: channelTopic, event: "presence", payload: presencePayload)
    }

    private func sendHeartbeat() {
        send(joinRef: nil, ref: nextRef(), topic: "phoenix", event: "heartbeat", payload: [:])
    }

    private func send(joinRef: String?, ref: String, topic: String, event: String, payload: [String: Any]) {
        guard let ws = task else { return }
        let array: [Any?] = [joinRef, ref, topic, event, payload]
        guard let data = try? JSONSerialization.data(withJSONObject: array),
              let text = String(data: data, encoding: .utf8) else { return }
        ws.send(.string(text)) { error in
            if let error {
                print("🌐 RemoteControl: send error: \(error)")
            }
        }
    }

    private func nextRef() -> String {
        refCounter += 1
        return "\(refCounter)"
    }
}
