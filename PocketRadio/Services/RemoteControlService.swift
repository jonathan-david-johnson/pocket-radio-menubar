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
        let event = array[3] as? String ?? ""
        let payload = array[4] as? [String: Any] ?? [:]

        switch event {
        case "phx_reply":
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
        guard let commandId = raw["command_id"] as? String,
              let targetId = raw["target_device_id"] as? String,
              let command = raw["command"] as? String else { return }
        guard targetId == deviceId else { return }
        guard !seenCommandIds.contains(commandId) else {
            print("🌐 RemoteControl: dropping duplicate commandId=\(commandId)")
            return
        }
        seenCommandIds.insert(commandId)

        let fromId = raw["from_device_id"] as? String ?? "?"
        print("🌐 RemoteControl: received command=\(command) from=\(fromId) id=\(commandId)")

        guard let player else { return }
        switch command {
        case "play":
            if !player.isPlaying { player.togglePlayback() }
        case "pause":
            if player.isPlaying { player.togglePlayback() }
        case "stop":
            if player.isPlaying { player.togglePlayback() }
        case "load_station":
            if let cmdPayload = raw["payload"] as? [String: Any],
               let stationUrl = cmdPayload["station_url"] as? String,
               let stationName = cmdPayload["station_name"] as? String,
               let stationId = cmdPayload["station_id"] as? String {
                let station = RadioStation(id: stationId, name: stationName, streamURL: stationUrl, logoURL: nil)
                player.playStation(station)
            }
        default:
            print("🌐 RemoteControl: unknown command=\(command)")
        }

        sendPresence()
    }

    // MARK: - Sending

    private func sendPresence() {
        guard let player else { return }
        let playbackState: String
        if player.isPlaying {
            playbackState = "playing"
        } else if player.currentSource != nil {
            playbackState = "paused"
        } else {
            playbackState = "idle"
        }

        var stationId: String? = nil
        var stationName: String? = nil
        if case .radio(let s) = player.currentSource {
            stationId = s.id
            stationName = s.name
        }

        let deviceName = Host.current().localizedName ?? "Mac"
        let presence: [String: Any] = [
            "device_id": deviceId,
            "device_type": "macos",
            "device_name": deviceName,
            "role": "receiver",
            "playback": [
                "state": playbackState,
                "station_id": stationId as Any,
                "station_name": stationName as Any,
            ],
            "updated_at": ISO8601DateFormatter().string(from: Date())
        ]
        let presencePayload: [String: Any] = [
            "type": "presence",
            "event": "track",
            "payload": presence
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
