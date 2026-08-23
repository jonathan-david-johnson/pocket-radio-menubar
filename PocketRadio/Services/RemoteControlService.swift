import Foundation

// Supabase Realtime Phoenix WebSocket receiver (protocol v2 — JSON array frames).
// Wire format: [joinRef, ref, topic, event, payload]
@MainActor
final class RemoteControlService: ObservableObject {
    private static let supabaseHost = "brvtspdculqyvdrmdtef.supabase.co"
    private static let anonKey = "sb_publishable_1MRvFzvB6O7f2zDPfs2nkA_p18FSLUF"

    private let deviceIdKey = "pocketradio-device-id"

    weak var player: PlayerViewModel?

    // MARK: - Presence & target

    @Published private(set) var presenceList: [String: RemotePresence] = [:]
    @Published private(set) var activeTargetDeviceId: String?

    func otherDevices() -> [RemotePresence] {
        presenceList.values.filter { $0.deviceId != deviceId }.sorted { $0.deviceName < $1.deviceName }
    }

    func setTarget(_ id: String?) {
        activeTargetDeviceId = id
        log("target set to \(id ?? "nil")")
    }

    // MARK: - Connection state

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
        presenceList = [:]
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
        request.setValue(userId, forHTTPHeaderField: "x-user-uuid")

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
        log("joining channel=\(channelTopic) device=\(deviceId)")
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
                log("receive error: \(error)")
                break
            }
        }
        log("receive loop ended")
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
            let status = (payload["status"] as? String) ?? ""
            if ref == joinRef {
                if status == "ok" {
                    log("channel joined ok")
                    sendPresence()
                } else {
                    log("channel join FAILED status=\(status) response=\(payload)")
                }
            } else if status != "ok" {
                log("phx_reply ERROR ref=\(ref) status=\(status) response=\(payload)")
            }
        case "broadcast":
            guard let broadcastEvent = payload["event"] as? String,
                  broadcastEvent == "command",
                  let cmdPayload = payload["payload"] as? [String: Any] else { return }
            handleCommand(cmdPayload)
        case "presence_diff":
            let joins = (payload["joins"] as? [String: Any]) ?? [:]
            let leaves = (payload["leaves"] as? [String: Any]) ?? [:]
            applyPresenceDiff(joins: joins, leaves: leaves)
        case "presence_state":
            applyPresenceState(payload)
        default:
            break
        }
    }

    // MARK: - Presence decoding

    // Supabase presence frame structure:
    //   "joins": { "presenceKey": { "metas": [{ phx_ref, ...our RemotePresence fields }] } }
    private func applyPresenceDiff(joins: [String: Any], leaves: [String: Any]) {
        for (key, val) in joins {
            if let p = decodePresence(from: val) {
                presenceList[key] = p
                log("presence join device=\(key) name=\(p.deviceName) state=\(p.playback.state.rawValue)")
            }
        }
        for key in leaves.keys {
            presenceList.removeValue(forKey: key)
            if activeTargetDeviceId == key { setTarget(nil) }
            log("presence leave device=\(key)")
        }
        log("presence_diff joins=\(joins.count) leaves=\(leaves.count) total=\(presenceList.count)")
    }

    private func applyPresenceState(_ payload: [String: Any]) {
        for (key, val) in payload {
            if let p = decodePresence(from: val) {
                presenceList[key] = p
                log("presence_state device=\(key) name=\(p.deviceName)")
            }
        }
        log("presence_state total=\(presenceList.count)")
    }

    private func decodePresence(from val: Any) -> RemotePresence? {
        guard let dict = val as? [String: Any],
              let metas = dict["metas"] as? [[String: Any]],
              let meta = metas.first,
              let data = try? JSONSerialization.data(withJSONObject: meta) else { return nil }
        return try? JSONDecoder().decode(RemotePresence.self, from: data)
    }

    // MARK: - Command handling

    private func handleCommand(_ raw: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: raw),
              let cmd = try? JSONDecoder().decode(RemoteCommand.self, from: data) else {
            log("failed to decode command: \(raw["command"] ?? "?")")
            return
        }
        guard cmd.targetDeviceId == deviceId else { return }
        guard !seenCommandIds.contains(cmd.commandId) else {
            log("dropping duplicate commandId=\(cmd.commandId)")
            return
        }
        seenCommandIds.insert(cmd.commandId)
        log("received command=\(cmd.command.rawValue) from=\(cmd.fromDeviceId) id=\(cmd.commandId)")

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
                log("loading station=\(stationName) url=\(stationUrl)")
                player.playStation(station)
            } else {
                log("loadStation: missing payload fields")
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
        log("tracked presence state=\(state.rawValue)")
    }

    private func sendHeartbeat() {
        send(joinRef: nil, ref: nextRef(), topic: "phoenix", event: "heartbeat", payload: [:])
    }

    private func send(joinRef: String?, ref: String, topic: String, event: String, payload: [String: Any]) {
        guard let ws = task else { return }
        let array: [Any?] = [joinRef, ref, topic, event, payload]
        guard let data = try? JSONSerialization.data(withJSONObject: array),
              let text = String(data: data, encoding: .utf8) else { return }
        ws.send(.string(text)) { [weak self] error in
            if let error {
                Task { @MainActor in
                    self?.log("send error event=\(event): \(error)")
                }
            }
        }
    }

    private func nextRef() -> String {
        refCounter += 1
        return "\(refCounter)"
    }

    private func log(_ message: String) {
        RemoteDebugLogger.shared.log("🌐 \(message)")
    }
}
