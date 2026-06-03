//
//  PocketCastsAPI.swift
//  PocketRadio Menubar
//
//  M2: Login/logout + Keychain token persistence for Pocket Casts.
//  Manual protobuf encode/decode — no SwiftProtobuf dependency needed.
//

import Foundation
import Security

// MARK: - Protobuf Encoding

/// Encode a length-delimited protobuf field (wire type 2).
/// Returns: tag byte + varint-encoded length + data bytes.
private func encodeField(_ fieldNumber: Int, _ value: String) -> Data {
    let tag = UInt8((fieldNumber << 3) | 2)  // wire type 2 = length-delimited
    let bytes = value.data(using: .utf8)!
    let len = bytes.count
    return Data([tag]) + encodeVarint(len) + bytes
}

/// Encode a varint (unsigned LEB128).
private func encodeVarint(_ value: Int) -> Data {
    var v = value
    var result = Data()
    repeat {
        var byte = UInt8(v & 0x7F)
        v >>= 7
        if v != 0 { byte |= 0x80 }
        result.append(byte)
    } while v != 0
    return result
}

/// Build the protobuf body for POST /user/login
/// Api_UserLoginRequest { email(1), password(2), scope(3) }
private func encodeLoginRequest(email: String, password: String, scope: String) -> Data {
    return encodeField(1, email) + encodeField(2, password) + encodeField(3, scope)
}

// MARK: - Protobuf Decoding

/// Decode a varint from Data at the given offset.
/// Returns (value, bytesConsumed).
private func decodeVarint(_ data: Data, offset: Int) -> (Int, Int) {
    var value = 0
    var shift = 0
    var pos = offset
    while pos < data.count {
        let byte = data[pos]
        value |= (Int(byte) & 0x7F) << shift
        pos += 1
        if (byte & 0x80) == 0 { break }
        shift += 7
    }
    return (value, pos - offset)
}

/// Decode a length-delimited protobuf field value.
/// Returns the UTF-8 string at the given offset after the tag.
private func decodeStringField(_ data: Data, offset: Int) -> (String, Int)? {
    var pos = offset
    guard pos + 1 < data.count else { return nil }

    let tag = data[pos]
    pos += 1
    let wireType = Int(tag & 0x07)
    guard wireType == 2 else { return nil }  // only handle length-delimited

    let (length, varintBytes) = decodeVarint(data, offset: pos)
    pos += varintBytes
    guard pos + length <= data.count else { return nil }

    let strData = data[pos..<pos + length]
    let str = String(data: strData, encoding: .utf8) ?? ""
    return (str, pos + length - offset)
}

/// Decode Api_UserLoginResponse { token(1), uuid(2), email(3) }
private func decodeLoginResponse(_ data: Data) -> (token: String, uuid: String, email: String)? {
    var token = "", uuid = "", email = ""
    var offset = 0

    while offset < data.count {
        let fieldNumber = Int(data[offset] >> 3)
        if let (value, consumed) = decodeStringField(data, offset: offset) {
            switch fieldNumber {
            case 1: token = value
            case 2: uuid = value
            case 3: email = value
            default: break
            }
            offset += consumed
        } else {
            break
        }
    }

    guard !token.isEmpty, !uuid.isEmpty else { return nil }
    return (token, uuid, email)
}

// MARK: - Login Errors

enum LoginError: LocalizedError, Equatable {
    case invalidCredentials
    case networkError(String)
    case badResponse
    case unknown

    var errorDescription: String? {
        switch self {
        case .invalidCredentials: return "Invalid email or password."
        case .networkError(let msg): return "Network error: \(msg)"
        case .badResponse: return "Unexpected server response."
        case .unknown: return "An unknown error occurred."
        }
    }
}

// MARK: - Pocket Casts API

enum PocketCastsAPI {
    private static let apiBase = "https://api.pocketcasts.com"
    private static let loginPath = "/user/login"

    /// POST /user/login with email + password → returns (token, userId, email)
    static func login(email: String, password: String) async throws -> (token: String, userId: String, email: String) {
        guard let url = URL(string: apiBase + loginPath) else {
            throw LoginError.unknown
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("PocketRadio/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = encodeLoginRequest(email: email, password: password, scope: "mobile")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LoginError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LoginError.badResponse
        }

        switch httpResponse.statusCode {
        case 200:
            guard let decoded = decodeLoginResponse(data) else {
                throw LoginError.badResponse
            }
            return (decoded.token, decoded.uuid, decoded.email)

        case 401, 403:
            throw LoginError.invalidCredentials

        default:
            throw LoginError.badResponse
        }
    }
}

// MARK: - Up Next Episode Model

struct UpNextEpisode: Equatable {
    let uuid: String
    let title: String
    let url: String
    let podcastUUID: String
    let playedUpTo: Int   // seconds of playback progress (from episodeSync)
    let duration: Int     // total duration in seconds (from episodeSync)
    var published: Date? = nil  // release date (from up_next field 5 Timestamp)
}

// MARK: - Up Next API

extension PocketCastsAPI {
    private static let upNextPath = "/up_next/sync"

    /// Fetch the user's Up Next queue. Returns episodes in order (first = currently playing or top of queue).
    static func fetchUpNext(token: String) async throws -> [UpNextEpisode] {
        guard let url = URL(string: apiBase + upNextPath) else {
            throw LoginError.unknown
        }

        let deviceID = getOrCreateDeviceID()
        let body = encodeUpNextRequest(deviceID: deviceID)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("PocketRadio/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LoginError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LoginError.badResponse
        }

        switch httpResponse.statusCode {
        case 200:
            return decodeUpNextResponse(data)
        case 401:
            throw LoginError.invalidCredentials
        default:
            throw LoginError.badResponse
        }
    }

    // MARK: Device ID

    private static func getOrCreateDeviceID() -> String {
        let key = "pocketradio-device-id"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: key)
        return newID
    }

    // MARK: Encode Up Next Request

    /// Encode Api_UpNextSyncRequest:
    ///   field 1: deviceTime (int64 varint, wire type 0)
    ///   field 2: version = "2.0" (string, wire type 2)
    ///   field 6: deviceID (string, wire type 2)
    private static func encodeUpNextRequest(deviceID: String) -> Data {
        let millis = Int64(Date().timeIntervalSince1970 * 1000)
        return encodeVarintField(1, millis)
             + encodeField(2, "2")
             + encodeField(6, deviceID)
    }

    // MARK: Decode Up Next Response

    /// Decode Api_UpNextResponse:
    ///   field 1: serverModified (int64) — skip
    ///   field 4: episodes (repeated EpisodeResponse, length-delimited)
    ///   field 5: episodeSync (repeated EpisodeSyncResponse, length-delimited)
    ///
    /// Each EpisodeResponse:
    ///   field 1: title (string)
    ///   field 2: url (string)
    ///   field 3: podcast (string)
    ///   field 4: uuid (string)
    ///   field 5: published (Timestamp sub-message) — skip
    ///
    /// Each EpisodeSyncResponse:
    ///   field 1: uuid (string)
    ///   field 2: playedUpTo (Int32Value sub-message)
    ///   field 3: duration (Int32Value sub-message)
    private static func decodeUpNextResponse(_ data: Data) -> [UpNextEpisode] {
        var episodes: [UpNextEpisode] = []
        var syncData: [String: (playedUpTo: Int, duration: Int)] = [:]
        var offset = 0

        while offset < data.count {
            guard offset < data.count else { break }
            let tag = data[offset]
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x07)
            offset += 1

            switch (fieldNumber, wireType) {
            case (4, 2):
                // EpisodeResponse sub-message
                let (length, varintBytes) = decodeVarint(data, offset: offset)
                offset += varintBytes
                guard offset + length <= data.count else { break }
                let subData = data[offset..<offset + length]
                if let episode = decodeEpisodeResponse(Data(subData)) {
                    episodes.append(episode)
                }
                offset += length

            case (5, 2):
                // EpisodeSyncResponse sub-message
                let (length, varintBytes) = decodeVarint(data, offset: offset)
                offset += varintBytes
                guard offset + length <= data.count else { break }
                let subData = data[offset..<offset + length]
                if let sync = decodeEpisodeSyncResponse(Data(subData)) {
                    syncData[sync.uuid] = (sync.playedUpTo, sync.duration)
                }
                offset += length

            case (1, 0):
                // serverModified varint — skip
                let (_, vb) = decodeVarint(data, offset: offset)
                offset += vb

            default:
                // Unknown field — skip it
                if wireType == 0 {
                    let (_, vb) = decodeVarint(data, offset: offset)
                    offset += vb
                } else if wireType == 2 {
                    let (length, vb) = decodeVarint(data, offset: offset)
                    offset += vb + length
                } else {
                    break  // can't skip, bail
                }
            }
        }

        print("🎵 PocketRadio: up_next/sync decoded \(episodes.count) episodes, \(syncData.count) sync records")
        for (uuid, sync) in syncData {
            print("🎵 PocketRadio:   sync uuid=\(uuid) playedUpTo=\(sync.playedUpTo)s duration=\(sync.duration)s")
        }

        // Merge sync data (playedUpTo, duration) into episodes by UUID
        return episodes.map { ep in
            if let sync = syncData[ep.uuid] {
                print("🎵 PocketRadio:   MATCH ep=\(ep.title.prefix(30)) uuid=\(ep.uuid) playedUpTo=\(sync.playedUpTo) duration=\(sync.duration)")
                return UpNextEpisode(
                    uuid: ep.uuid,
                    title: ep.title,
                    url: ep.url,
                    podcastUUID: ep.podcastUUID,
                    playedUpTo: sync.playedUpTo,
                    duration: sync.duration,
                    published: ep.published
                )
            }
            print("🎵 PocketRadio:   NO SYNC for ep=\(ep.title.prefix(30)) uuid=\(ep.uuid)")
            return ep
        }
    }

    private static func decodeEpisodeResponse(_ data: Data) -> UpNextEpisode? {
        var title = "", url = "", podcast = "", uuid = ""
        var published: Date? = nil
        var offset = 0

        while offset < data.count {
            guard offset < data.count else { break }
            let tag = data[offset]
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x07)
            offset += 1

            if wireType == 2 {
                let (length, vb) = decodeVarint(data, offset: offset)
                offset += vb
                guard offset + length <= data.count else { break }
                let bytes = Data(data[offset..<offset + length])
                offset += length

                switch fieldNumber {
                case 1: title = String(data: bytes, encoding: .utf8) ?? ""
                case 2: url = String(data: bytes, encoding: .utf8) ?? ""
                case 3: podcast = String(data: bytes, encoding: .utf8) ?? ""
                case 4: uuid = String(data: bytes, encoding: .utf8) ?? ""
                case 5: published = decodeTimestamp(bytes)  // google.protobuf.Timestamp
                default: break
                }
            } else if wireType == 0 {
                let (_, vb) = decodeVarint(data, offset: offset)
                offset += vb
            } else {
                break
            }
        }

        guard !uuid.isEmpty else { return nil }
        return UpNextEpisode(uuid: uuid, title: title, url: url, podcastUUID: podcast,
                             playedUpTo: 0, duration: 0, published: published)
    }

    /// Decode a google.protobuf.Timestamp sub-message:
    ///   field 1: seconds (int64 varint, since Unix epoch)
    ///   field 2: nanos (int32 varint) — ignored
    private static func decodeTimestamp(_ data: Data) -> Date? {
        var seconds: Int? = nil
        var offset = 0
        while offset < data.count {
            let tag = data[offset]
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x07)
            offset += 1
            if wireType == 0 {
                let (value, vb) = decodeVarint(data, offset: offset)
                offset += vb
                if fieldNumber == 1 { seconds = value }
            } else if wireType == 2 {
                let (length, vb) = decodeVarint(data, offset: offset)
                offset += vb + length
            } else {
                break
            }
        }
        guard let s = seconds, s > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(s))
    }

    /// Decode a Google_Protobuf_Int32Value wrapper. Returns the inner int32 value.
    /// Int32Value { value(1) = int32 varint }
    private static func decodeInt32Value(_ data: Data) -> Int? {
        var offset = 0
        while offset < data.count {
            guard offset < data.count else { break }
            let tag = data[offset]
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x07)
            offset += 1

            if fieldNumber == 1 && wireType == 0 {
                let (value, vb) = decodeVarint(data, offset: offset)
                offset += vb
                return value
            } else if wireType == 0 {
                let (_, vb) = decodeVarint(data, offset: offset)
                offset += vb
            } else if wireType == 2 {
                let (length, vb) = decodeVarint(data, offset: offset)
                offset += vb + length
            } else {
                break
            }
        }
        return nil
    }

    /// Decode Api_UpNextResponse.EpisodeSyncResponse:
    ///   field 1: uuid (string)
    ///   field 6: playedUpTo (Int32Value sub-message)
    ///   field 7: duration (Int32Value sub-message)
    private static func decodeEpisodeSyncResponse(_ data: Data) -> (uuid: String, playedUpTo: Int, duration: Int)? {
        var uuid = ""
        var playedUpTo = 0
        var duration = 0
        var offset = 0

        while offset < data.count {
            guard offset < data.count else { break }
            let tag = data[offset]
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x07)
            offset += 1

            if wireType == 2 {
                let (length, vb) = decodeVarint(data, offset: offset)
                offset += vb
                guard offset + length <= data.count else { break }
                let subData = data[offset..<offset + length]
                offset += length

                switch fieldNumber {
                case 1:
                    uuid = String(data: subData, encoding: .utf8) ?? ""
                case 6:
                    playedUpTo = decodeInt32Value(Data(subData)) ?? 0
                case 7:
                    duration = decodeInt32Value(Data(subData)) ?? 0
                default: break
                }
            } else if wireType == 0 {
                let (_, vb) = decodeVarint(data, offset: offset)
                offset += vb
            } else {
                break
            }
        }

        guard !uuid.isEmpty else { return nil }
        return (uuid, playedUpTo, duration)
    }
}

// MARK: - user/podcast/episodes (per-podcast episode sync data)

struct EpisodePlaybackInfo: Equatable {
    let uuid: String
    let playedUpTo: Int  // seconds
    let duration: Int    // seconds
}

extension PocketCastsAPI {
    private static let podcastEpisodesPath = "/user/podcast/episodes"

    /// Fetch played positions + durations for all episodes of one podcast.
    static func fetchPodcastEpisodes(token: String, podcastUUID: String) async throws -> [EpisodePlaybackInfo] {
        guard let url = URL(string: apiBase + podcastEpisodesPath) else {
            throw LoginError.unknown
        }

        // Api_UuidRequest { v(1)="2", m(2)="mobile", uuid(3)=podcastUUID }
        let body = encodeField(1, "2") + encodeField(2, "mobile") + encodeField(3, podcastUUID)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("PocketRadio/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LoginError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LoginError.badResponse
        }

        switch httpResponse.statusCode {
        case 200:
            return decodeSyncEpisodesResponse(data)
        case 401:
            throw LoginError.invalidCredentials
        default:
            throw LoginError.badResponse
        }
    }

    /// Decode Api_SyncEpisodesResponse:
    ///   field 1: episodes (repeated Api_EpisodeSyncResponse, length-delimited)
    ///
    /// Each top-level Api_EpisodeSyncResponse (NOT wrapped Int32Value — plain int32):
    ///   field 1: uuid (string)
    ///   field 3: playedUpTo (int32 varint)
    ///   field 6: duration (int32 varint)
    private static func decodeSyncEpisodesResponse(_ data: Data) -> [EpisodePlaybackInfo] {
        var result: [EpisodePlaybackInfo] = []
        var offset = 0
        while offset < data.count {
            let tag = data[offset]
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x07)
            offset += 1

            if fieldNumber == 1 && wireType == 2 {
                let (length, vb) = decodeVarint(data, offset: offset)
                offset += vb
                guard offset + length <= data.count else { break }
                let subData = data[offset..<offset + length]
                if let info = decodeEpisodeSyncTopLevel(Data(subData)) {
                    result.append(info)
                }
                offset += length
            } else if wireType == 0 {
                let (_, vb) = decodeVarint(data, offset: offset)
                offset += vb
            } else if wireType == 2 {
                let (length, vb) = decodeVarint(data, offset: offset)
                offset += vb + length
            } else {
                break
            }
        }
        return result
    }

    private static func decodeEpisodeSyncTopLevel(_ data: Data) -> EpisodePlaybackInfo? {
        var uuid = ""
        var playedUpTo = 0
        var duration = 0
        var offset = 0
        while offset < data.count {
            let tag = data[offset]
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x07)
            offset += 1

            if wireType == 2 {
                let (length, vb) = decodeVarint(data, offset: offset)
                offset += vb
                guard offset + length <= data.count else { break }
                let subData = data[offset..<offset + length]
                if fieldNumber == 1 {
                    uuid = String(data: subData, encoding: .utf8) ?? ""
                }
                offset += length
            } else if wireType == 0 {
                let (value, vb) = decodeVarint(data, offset: offset)
                offset += vb
                switch fieldNumber {
                case 3: playedUpTo = value
                case 6: duration = value
                default: break
                }
            } else {
                break
            }
        }
        guard !uuid.isEmpty else { return nil }
        return EpisodePlaybackInfo(uuid: uuid, playedUpTo: playedUpTo, duration: duration)
    }
}

// MARK: - sync/update_episode (write back playback position)

enum EpisodePlayingStatus: Int32 {
    case notPlayed = 1
    case inProgress = 2
    case completed = 3
}

extension PocketCastsAPI {
    private static let updateEpisodePath = "/sync/update_episode"

    /// POST sync/update_episode with Api_UpdateEpisodeRequest:
    ///   field 1: uuid (string)
    ///   field 2: podcast (string)
    ///   field 3: position (Google_Protobuf_Int32Value wrapper, length-delimited sub-message)
    ///   field 4: status (int32 varint)
    ///   field 5: duration (int32 varint)
    static func updateEpisodePosition(
        token: String,
        episodeUUID: String,
        podcastUUID: String,
        position: Int,
        duration: Int,
        status: EpisodePlayingStatus
    ) async throws {
        guard let url = URL(string: apiBase + updateEpisodePath) else {
            throw LoginError.unknown
        }

        // Int32Value wrapper: field 1 (varint) = position
        let positionInner = encodeVarintField(1, Int64(position))
        let positionWrapper = encodeLengthDelimitedField(3, positionInner)

        let body = encodeField(1, episodeUUID)
                 + encodeField(2, podcastUUID)
                 + positionWrapper
                 + encodeVarintField(4, Int64(status.rawValue))
                 + encodeVarintField(5, Int64(duration))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("PocketRadio/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        let (_, response): (Data, URLResponse)
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LoginError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LoginError.badResponse
        }

        switch httpResponse.statusCode {
        case 200: return
        case 401: throw LoginError.invalidCredentials
        default: throw LoginError.badResponse
        }
    }
}

private func encodeLengthDelimitedField(_ fieldNumber: Int, _ payload: Data) -> Data {
    let tag = UInt8((fieldNumber << 3) | 2)
    return Data([tag]) + encodeVarint(payload.count) + payload
}

// MARK: - up_next/sync change actions (playNow, etc.)

extension PocketCastsAPI {
    /// Send a "playNow" action that bubbles the given episode to the top of the user's Up Next queue.
    /// Matches iOS UpNextSyncTask.convertToProto for a single non-replace action.
    static func playNowAction(token: String, episode: UpNextEpisode) async throws {
        guard let url = URL(string: apiBase + upNextPath) else { throw LoginError.unknown }

        let nowMillis = Int64(Date().timeIntervalSince1970 * 1000)
        let deviceID = getOrCreateDeviceID()

        // Api_UpNextChanges.Change: uuid(1), action(2)=1, modified(3)=nowMillis, title(4), url(5), podcast(6)
        let change = encodeField(1, episode.uuid)
                   + encodeVarintField(2, 1)              // playNow
                   + encodeVarintField(3, nowMillis)
                   + encodeField(4, episode.title)
                   + encodeField(5, episode.url)
                   + encodeField(6, episode.podcastUUID)

        // Api_UpNextChanges: changes(2) = repeated Change
        let upNextChanges = encodeLengthDelimitedField(2, change)

        // Api_UpNextSyncRequest: deviceTime(1), version(2)="2", upNext(4)=Api_UpNextChanges, deviceID(6)
        let body = encodeVarintField(1, nowMillis)
                 + encodeField(2, "2")
                 + encodeLengthDelimitedField(4, upNextChanges)
                 + encodeField(6, deviceID)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("PocketRadio/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LoginError.badResponse }
        switch http.statusCode {
        case 200: return
        case 401: throw LoginError.invalidCredentials
        default: throw LoginError.badResponse
        }
    }

    /// Send a "remove" action (action=4) to remove the episode from the user's
    /// Up Next queue. Mirrors iOS UpNextChanges.Actions.remove.
    static func removeEpisodeAction(token: String, episode: UpNextEpisode) async throws {
        guard let url = URL(string: apiBase + upNextPath) else { throw LoginError.unknown }
        let nowMillis = Int64(Date().timeIntervalSince1970 * 1000)
        let deviceID = getOrCreateDeviceID()

        // Change: uuid(1), action(2)=4, modified(3). Title/url/podcast optional but include
        // to match the playNow encoding shape iOS sends.
        let change = encodeField(1, episode.uuid)
                   + encodeVarintField(2, 4)              // remove
                   + encodeVarintField(3, nowMillis)
                   + encodeField(4, episode.title)
                   + encodeField(5, episode.url)
                   + encodeField(6, episode.podcastUUID)
        let upNextChanges = encodeLengthDelimitedField(2, change)
        let body = encodeVarintField(1, nowMillis)
                 + encodeField(2, "2")
                 + encodeLengthDelimitedField(4, upNextChanges)
                 + encodeField(6, deviceID)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("PocketRadio/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LoginError.badResponse }
        switch http.statusCode {
        case 200: return
        case 401: throw LoginError.invalidCredentials
        default: throw LoginError.badResponse
        }
    }
}

// MARK: - Radio Station Model

struct RadioStation: Identifiable, Equatable {
    let id: String       // station UUID from radio-browser.info
    let name: String
    let streamURL: String
    let logoURL: String?
    // Extra metadata from radio-browser (shown in hover detail card)
    var country: String? = nil
    var language: String? = nil
    var tags: String? = nil
    var codec: String? = nil
    var bitrate: Int? = nil
    var votes: Int? = nil
    var homepage: String? = nil

    static func == (lhs: RadioStation, rhs: RadioStation) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Radio Favorites API

extension PocketCastsAPI {
    private static let supabaseURL = "https://brvtspdculqyvdrmdtef.supabase.co"
    private static let supabaseAnonKey = "sb_publishable_1MRvFzvB6O7f2zDPfs2nkA_p18FSLUF"
    private static let radioBrowserBase = "https://de1.api.radio-browser.info/json"

    /// Fetch the user's favorite radio stations from Supabase, then look up
    /// station metadata (name, stream URL, logo) from radio-browser.info.
    static func fetchFavoriteStations(userId: String) async throws -> [RadioStation] {
        // Step 1: Get favorite station IDs from Supabase
        let stationIDs = try await fetchFavoriteIDs(userId: userId)
        guard !stationIDs.isEmpty else { return [] }

        // Step 2: Look up each station on radio-browser.info (parallel)
        let stations = await withTaskGroup(of: RadioStation?.self) { group in
            for id in stationIDs {
                group.addTask {
                    try? await lookupStation(uuid: id)
                }
            }

            var results: [RadioStation] = []
            for await station in group {
                if let station = station {
                    results.append(station)
                }
            }
            return results
        }

        return stations.sorted { $0.name < $1.name }
    }

    // MARK: Supabase

    private static func fetchFavoriteIDs(userId: String) async throws -> [String] {
        guard let url = URL(string: "\(supabaseURL)/rest/v1/radio_favorites?select=station_id") else {
            throw LoginError.unknown
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue(userId, forHTTPHeaderField: "x-user-uuid")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw LoginError.badResponse
        }

        // Supabase returns JSON array: [{station_id: "uuid"}, ...]
        struct FavoritesRow: Decodable {
            let stationId: String
            enum CodingKeys: String, CodingKey {
                case stationId = "station_id"
            }
        }

        let rows = try JSONDecoder().decode([FavoritesRow].self, from: data)
        return rows.map { $0.stationId }
    }

    // MARK: Radio Browser

    private static func lookupStation(uuid: String) async throws -> RadioStation? {
        guard let url = URL(string: "\(radioBrowserBase)/stations/byuuid/\(uuid)") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue("PocketRadio/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return nil
        }

        // radio-browser returns an array of stations (usually 1)
        struct StationResponse: Decodable {
            let name: String?
            let url: String?
            let url_resolved: String?
            let favicon: String?
            let country: String?
            let language: String?
            let tags: String?
            let codec: String?
            let bitrate: Int?
            let votes: Int?
            let homepage: String?
        }

        let stations = try JSONDecoder().decode([StationResponse].self, from: data)
        guard let station = stations.first,
              let name = station.name,
              let streamURL = station.url_resolved ?? station.url else {
            return nil
        }

        return RadioStation(
            id: uuid,
            name: name,
            streamURL: streamURL,
            logoURL: station.favicon,
            country: station.country,
            language: station.language,
            tags: station.tags,
            codec: station.codec,
            bitrate: station.bitrate,
            votes: station.votes,
            homepage: station.homepage
        )
    }
}

// MARK: - User Settings (read-only: skip amounts)

struct SkipSettings: Equatable {
    let back: Int       // seconds
    let forward: Int    // seconds
}

extension PocketCastsAPI {
    private static let namedSettingsPath = "/user/named_settings/update"

    /// Read the user's synced skip amounts. The `named_settings/update` endpoint
    /// returns the server's *current* settings even when the request carries no
    /// settings to change — so by sending only the device field (no `settings`
    /// or `changedSettings`) this is effectively read-only; nothing is written.
    ///   Request  Api_NamedSettingsRequest  { m(2) = string }
    ///   Response Api_NamedSettingsResponse { skipForward(5), skipBack(6) }
    ///     each Api_Int32Setting { value(1) = Int32Value }, Int32Value { value(1) = int32 }
    static func fetchSkipSettings(token: String) async -> SkipSettings? {
        guard let url = URL(string: apiBase + namedSettingsPath) else { return nil }
        let body = encodeField(2, "PocketRadio")  // m = device; no settings → read-only

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("PocketRadio/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                print("🎵 PocketRadio: named_settings HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            let forward = decodeInt32Setting(in: data, fieldNumber: 5)
            let back = decodeInt32Setting(in: data, fieldNumber: 6)
            guard back != nil || forward != nil else {
                print("🎵 PocketRadio: named_settings returned no skip values")
                return nil
            }
            print("🎵 PocketRadio: skip settings back=\(back ?? -1)s forward=\(forward ?? -1)s")
            return SkipSettings(back: back ?? 10, forward: forward ?? 45)
        } catch {
            print("🎵 PocketRadio: named_settings fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Top-level `fieldNumber` is an Api_Int32Setting submessage; unwrap its
    /// inner Int32Value (field 1) and return the int.
    private static func decodeInt32Setting(in data: Data, fieldNumber target: Int) -> Int? {
        guard let settingBytes = firstSubmessage(in: data, fieldNumber: target),
              let valueBytes = firstSubmessage(in: settingBytes, fieldNumber: 1) else { return nil }
        return decodeInt32Value(valueBytes)
    }

    /// Bytes of the first length-delimited (wire type 2) field matching
    /// `fieldNumber`. Skips other fields by wire type.
    private static func firstSubmessage(in data: Data, fieldNumber target: Int) -> Data? {
        var offset = 0
        while offset < data.count {
            let tag = Int(data[offset]); offset += 1
            let field = tag >> 3
            let wire = tag & 0x07
            switch wire {
            case 0:
                let (_, vb) = decodeVarint(data, offset: offset); offset += vb
            case 2:
                let (len, vb) = decodeVarint(data, offset: offset); offset += vb
                guard offset + len <= data.count else { return nil }
                if field == target { return Data(data[offset..<offset + len]) }
                offset += len
            case 1: offset += 8   // 64-bit
            case 5: offset += 4   // 32-bit
            default: return nil
            }
        }
        return nil
    }
}

// MARK: - Subscribed podcasts + New Releases

struct SubscribedPodcast: Equatable {
    let uuid: String
    let title: String
}

struct NewReleaseEpisode: Identifiable, Equatable {
    let id: String          // episode UUID
    let uuid: String
    let podcastUUID: String
    let podcastTitle: String
    let title: String
    let url: String
    let duration: Int
    let published: Date
}

extension PocketCastsAPI {
    private static let podcastListPath = "/user/podcast/list"
    private static let cacheBase = "https://cache.pocketcasts.com"

    /// POST user/podcast/list — Api_UserPodcastListRequest { v(1)="2", m(2)="mobile" }.
    /// Decodes Api_UserPodcastListResponse { podcasts(1)=repeated UserPodcastResponse }
    /// where each podcast has uuid(1) + title(4).
    static func fetchSubscribedPodcasts(token: String) async throws -> [SubscribedPodcast] {
        guard let url = URL(string: apiBase + podcastListPath) else { throw LoginError.unknown }

        let body = encodeField(1, "2") + encodeField(2, "mobile")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("PocketRadio/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LoginError.badResponse }
        switch http.statusCode {
        case 200: return decodePodcastListResponse(data)
        case 401: throw LoginError.invalidCredentials
        default: throw LoginError.badResponse
        }
    }

    private static func decodePodcastListResponse(_ data: Data) -> [SubscribedPodcast] {
        var result: [SubscribedPodcast] = []
        var offset = 0
        while offset < data.count {
            let tag = data[offset]
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x07)
            offset += 1

            if fieldNumber == 1 && wireType == 2 {
                let (length, vb) = decodeVarint(data, offset: offset)
                offset += vb
                guard offset + length <= data.count else { break }
                let subData = data[offset..<offset + length]
                if let podcast = decodeUserPodcastResponse(Data(subData)) {
                    result.append(podcast)
                }
                offset += length
            } else if wireType == 0 {
                let (_, vb) = decodeVarint(data, offset: offset)
                offset += vb
            } else if wireType == 2 {
                let (length, vb) = decodeVarint(data, offset: offset)
                offset += vb + length
            } else {
                break
            }
        }
        return result
    }

    private static func decodeUserPodcastResponse(_ data: Data) -> SubscribedPodcast? {
        var uuid = ""
        var title = ""
        var offset = 0
        while offset < data.count {
            let tag = data[offset]
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x07)
            offset += 1

            if wireType == 2 {
                let (length, vb) = decodeVarint(data, offset: offset)
                offset += vb
                guard offset + length <= data.count else { break }
                let subData = data[offset..<offset + length]
                if fieldNumber == 1 {
                    uuid = String(data: subData, encoding: .utf8) ?? ""
                } else if fieldNumber == 4 {
                    title = String(data: subData, encoding: .utf8) ?? ""
                }
                offset += length
            } else if wireType == 0 {
                let (_, vb) = decodeVarint(data, offset: offset)
                offset += vb
            } else {
                break
            }
        }
        guard !uuid.isEmpty else { return nil }
        return SubscribedPodcast(uuid: uuid, title: title)
    }

    /// GET cache.pocketcasts.com/mobile/podcast/full/<uuid>. Returns the JSON episode array.
    /// No auth required; cache server follows a 302 to the actual JSON blob.
    static func fetchFullEpisodes(podcastUUID: String, podcastTitle: String) async -> [NewReleaseEpisode] {
        guard let url = URL(string: "\(cacheBase)/mobile/podcast/full/\(podcastUUID)") else { return [] }
        var request = URLRequest(url: url)
        request.setValue("PocketRadio/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            return parseFullEpisodes(data, podcastUUID: podcastUUID, podcastTitle: podcastTitle)
        } catch {
            print("🎵 PocketRadio: full episodes fetch failed for \(podcastUUID): \(error.localizedDescription)")
            return []
        }
    }

    private struct FullResponse: Decodable {
        struct Podcast: Decodable {
            let title: String?
            let episodes: [Episode]?
        }
        struct Episode: Decodable {
            let uuid: String
            let title: String?
            let url: String?
            let duration: Int?
            let published: String?
        }
        let podcast: Podcast?
    }

    private static func parseFullEpisodes(_ data: Data, podcastUUID: String, podcastTitle: String) -> [NewReleaseEpisode] {
        guard let resp = try? JSONDecoder().decode(FullResponse.self, from: data),
              let podcast = resp.podcast,
              let episodes = podcast.episodes else { return [] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let displayTitle = podcast.title?.isEmpty == false ? (podcast.title ?? podcastTitle) : podcastTitle
        return episodes.compactMap { e in
            guard let title = e.title, !title.isEmpty,
                  let url = e.url, !url.isEmpty,
                  let publishedStr = e.published,
                  let published = iso.date(from: publishedStr) else { return nil }
            return NewReleaseEpisode(
                id: e.uuid,
                uuid: e.uuid,
                podcastUUID: podcastUUID,
                podcastTitle: displayTitle,
                title: title,
                url: url,
                duration: e.duration ?? 0,
                published: published
            )
        }
    }

    /// Build the New Releases list: list subscribed podcasts, fan out to /podcast/full,
    /// filter to last `days` days, sort by published descending.
    static func fetchNewReleases(token: String, days: Int = 14) async -> [NewReleaseEpisode] {
        let podcasts: [SubscribedPodcast]
        do {
            podcasts = try await fetchSubscribedPodcasts(token: token)
        } catch {
            print("🎵 PocketRadio: subscribed podcasts fetch failed: \(error.localizedDescription)")
            return []
        }

        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 60 * 60)

        let allEpisodes = await withTaskGroup(of: [NewReleaseEpisode].self) { group -> [NewReleaseEpisode] in
            for podcast in podcasts {
                group.addTask {
                    await fetchFullEpisodes(podcastUUID: podcast.uuid, podcastTitle: podcast.title)
                }
            }
            var collected: [NewReleaseEpisode] = []
            for await eps in group {
                collected.append(contentsOf: eps)
            }
            return collected
        }

        return allEpisodes
            .filter { $0.published >= cutoff }
            .sorted { $0.published > $1.published }
    }
}

// MARK: - Episode Show Notes (description)

struct EpisodeShowNotes: Equatable {
    let description: String   // plain text, HTML stripped
    let imageURL: String?
}

extension PocketCastsAPI {
    /// Fetch show notes (description + image) for one episode. The cache server
    /// returns notes for the whole podcast keyed by episode uuid:
    ///   GET cache.pocketcasts.com/mobile/show_notes/full/<podcastUuid>
    ///   → { podcast: { episodes: [ { uuid, show_notes, image } ] } }
    static func fetchEpisodeShowNotes(podcastUUID: String, episodeUUID: String) async -> EpisodeShowNotes? {
        guard !podcastUUID.isEmpty,
              let url = URL(string: "\(cacheBase)/mobile/show_notes/full/\(podcastUUID)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("PocketRadio/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        struct Response: Decodable {
            struct Podcast: Decodable { let episodes: [Episode]? }
            struct Episode: Decodable {
                let uuid: String
                let showNotes: String?
                let image: String?
            }
            let podcast: Podcast?
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let resp = try decoder.decode(Response.self, from: data)
            guard let ep = resp.podcast?.episodes?.first(where: { $0.uuid == episodeUUID }) else { return nil }
            let text = htmlToPlainText(ep.showNotes ?? "")
            return EpisodeShowNotes(description: text, imageURL: ep.image)
        } catch {
            print("🎵 PocketRadio: show notes fetch failed for \(episodeUUID): \(error.localizedDescription)")
            return nil
        }
    }

    /// Crude HTML → plain text: drop tags, decode a few common entities,
    /// collapse whitespace. Good enough for a hover preview.
    private static func htmlToPlainText(_ html: String) -> String {
        var s = html
        // Turn block-level breaks into newlines before stripping tags.
        for tag in ["<br>", "<br/>", "<br />", "</p>", "</div>", "</li>"] {
            s = s.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }
        // Strip remaining tags.
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // Decode common entities.
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                        "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&hellip;": "…"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        // Collapse 3+ newlines to 2, trim trailing spaces per line.
        s = s.replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Radio Browser browse + search + favorite mutations

extension PocketCastsAPI {
    /// Top voted radio stations (used as the default Browse list).
    static func topStations(limit: Int = 50) async throws -> [RadioStation] {
        guard let url = URL(string: "\(radioBrowserBase)/stations/topvote?limit=\(limit)&hidebroken=true") else { return [] }
        return try await fetchStations(from: url)
    }

    /// Free-text station search via radio-browser.info.
    static func searchStations(query: String, limit: Int = 40) async throws -> [RadioStation] {
        guard var components = URLComponents(string: "\(radioBrowserBase)/stations/search") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "name", value: query),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "hidebroken", value: "true"),
            URLQueryItem(name: "order", value: "votes"),
            URLQueryItem(name: "reverse", value: "true")
        ]
        guard let url = components.url else { return [] }
        return try await fetchStations(from: url)
    }

    private static func fetchStations(from url: URL) async throws -> [RadioStation] {
        var request = URLRequest(url: url)
        request.setValue("PocketRadio/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LoginError.badResponse
        }
        struct Row: Decodable {
            let stationuuid: String
            let name: String?
            let url_resolved: String?
            let favicon: String?
            let country: String?
            let language: String?
            let tags: String?
            let codec: String?
            let bitrate: Int?
            let votes: Int?
            let homepage: String?
        }
        let rows = try JSONDecoder().decode([Row].self, from: data)
        return rows.compactMap { row in
            guard let name = row.name, !name.isEmpty,
                  let stream = row.url_resolved, !stream.isEmpty else { return nil }
            return RadioStation(
                id: row.stationuuid,
                name: name,
                streamURL: stream,
                logoURL: row.favicon,
                country: row.country,
                language: row.language,
                tags: row.tags,
                codec: row.codec,
                bitrate: row.bitrate,
                votes: row.votes,
                homepage: row.homepage
            )
        }
    }

    /// Add a station UUID to the user's Supabase favorites table.
    static func addFavorite(userId: String, stationId: String) async throws {
        guard let url = URL(string: "\(supabaseURL)/rest/v1/radio_favorites") else { throw LoginError.unknown }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue(userId, forHTTPHeaderField: "x-user-uuid")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Upsert so re-faving an existing row doesn't 409.
        request.setValue("return=minimal,resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        let body = try JSONSerialization.data(withJSONObject: [
            "user_uuid": userId,
            "station_id": stationId
        ])
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LoginError.badResponse }
        if !(200..<300).contains(http.statusCode) {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            print("🎵 PocketRadio: addFavorite HTTP \(http.statusCode): \(bodyStr)")
            throw LoginError.badResponse
        }
    }

    /// Remove a station UUID from the user's Supabase favorites table.
    static func removeFavorite(userId: String, stationId: String) async throws {
        guard let url = URL(string: "\(supabaseURL)/rest/v1/radio_favorites?station_id=eq.\(stationId)&user_uuid=eq.\(userId)") else {
            throw LoginError.unknown
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue(userId, forHTTPHeaderField: "x-user-uuid")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LoginError.badResponse }
        if !(200..<300).contains(http.statusCode) {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            print("🎵 PocketRadio: removeFavorite HTTP \(http.statusCode): \(bodyStr)")
            throw LoginError.badResponse
        }
    }
}

// MARK: - Int64 Varint Helpers

/// Encode a varint field (wire type 0) for an Int64 value.
/// Returns: tag byte + varint-encoded value bytes.
private func encodeVarintField(_ fieldNumber: Int, _ value: Int64) -> Data {
    let tag = UInt8((fieldNumber << 3) | 0)  // wire type 0 = varint
    return Data([tag]) + encodeVarint64(value)
}

/// Encode an Int64 as an unsigned varint.
private func encodeVarint64(_ value: Int64) -> Data {
    var v = UInt64(bitPattern: value)
    var result = Data()
    repeat {
        var byte = UInt8(v & 0x7F)
        v >>= 7
        if v != 0 { byte |= 0x80 }
        result.append(byte)
    } while v != 0
    return result
}

// MARK: - Radio Tracklist (KCRW, KEXP)

struct TracklistEntry: Equatable, Identifiable {
    let id = UUID()
    let title: String
    let artist: String
    let album: String?
    let albumArtURL: URL?
    let playedAt: Date?
}

extension PocketCastsAPI {
    private static let kcrwTracklistURL = "https://tracklist-api.kcrw.com/Music/all/1?page_size=10"
    private static let kexpTracklistURL = "https://api.kexp.org/v2/plays/?limit=10"

    /// Tracklist endpoint for the given station, or nil if unsupported.
    static func tracklistURL(for station: RadioStation) -> String? {
        let name = station.name.lowercased()
        if name.contains("kcrw") { return kcrwTracklistURL }
        if name.contains("kexp") { return kexpTracklistURL }
        return nil
    }

    static func fetchTracklist(for station: RadioStation) async -> [TracklistEntry] {
        guard let urlString = tracklistURL(for: station),
              let url = URL(string: urlString) else { return [] }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                print("🎵 PocketRadio: tracklist HTTP \(http.statusCode) for \(station.name)")
                return []
            }
            let name = station.name.lowercased()
            var entries: [TracklistEntry] = []
            if name.contains("kcrw") { entries = parseKCRW(data) }
            else if name.contains("kexp") { entries = parseKEXP(data) }
            return await fillMissingArtwork(entries)
        } catch {
            print("🎵 PocketRadio: tracklist fetch failed for \(station.name): \(error.localizedDescription)")
            return []
        }
    }

    /// For any entry with no albumArtURL, fire an iTunes Search lookup concurrently.
    private static func fillMissingArtwork(_ entries: [TracklistEntry]) async -> [TracklistEntry] {
        guard entries.contains(where: { $0.albumArtURL == nil }) else { return entries }
        return await withTaskGroup(of: (Int, URL?).self) { group in
            for (i, entry) in entries.enumerated() {
                guard entry.albumArtURL == nil else { continue }
                group.addTask { (i, await iTunesArtwork(artist: entry.artist, title: entry.title)) }
            }
            var results = entries
            for await (i, url) in group {
                if let url {
                    let e = results[i]
                    results[i] = TracklistEntry(title: e.title, artist: e.artist,
                                                album: e.album, albumArtURL: url,
                                                playedAt: e.playedAt)
                }
            }
            return results
        }
    }

    /// iTunes Search fallback — returns a 600×600 art URL or nil.
    private static func iTunesArtwork(artist: String, title: String) async -> URL? {
        let query = "\(artist) \(title)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "https://itunes.apple.com/search?term=\(query)&media=music&entity=song&limit=3") else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let first = results.first,
                  let art = first["artworkUrl100"] as? String else { return nil }
            // Upgrade to 600×600
            let large = art.replacingOccurrences(of: "/100x100bb.", with: "/600x600bb.")
            print("🎵 PocketRadio: iTunes art fallback for '\(title)': \(large)")
            return URL(string: large)
        } catch {
            return nil
        }
    }

    private struct KCRWTrack: Decodable {
        let title: String?
        let artist: String?
        let album: String?
        let albumImage: String?
        let albumImageLarge: String?
        let datetime: String?
    }

    private static func parseKCRW(_ data: Data) -> [TracklistEntry] {
        guard let tracks = try? JSONDecoder().decode([KCRWTrack].self, from: data) else { return [] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return tracks.compactMap { t in
            guard let title = t.title, !title.isEmpty,
                  let artist = t.artist, !artist.isEmpty, artist != "[BREAK]" else { return nil }
            let imageString = t.albumImageLarge ?? t.albumImage
            return TracklistEntry(
                title: title,
                artist: artist,
                album: t.album,
                albumArtURL: imageString.flatMap(URL.init(string:)),
                playedAt: t.datetime.flatMap(iso.date(from:))
            )
        }
    }

    private struct KEXPResponse: Decodable {
        struct Play: Decodable {
            let play_type: String
            let song: String?
            let artist: String?
            let album: String?
            let thumbnail_uri: String?
            let airdate: String?
        }
        let results: [Play]
    }

    private static func parseKEXP(_ data: Data) -> [TracklistEntry] {
        guard let resp = try? JSONDecoder().decode(KEXPResponse.self, from: data) else { return [] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return resp.results.compactMap { play in
            guard play.play_type == "trackplay",
                  let song = play.song, let artist = play.artist else { return nil }
            return TracklistEntry(
                title: song,
                artist: artist,
                album: play.album,
                albumArtURL: play.thumbnail_uri.flatMap(URL.init(string:)),
                playedAt: play.airdate.flatMap(iso.date(from:))
            )
        }
    }
}

// MARK: - Keychain Manager

enum KeychainManager {
    private static let service = "com.jdj.pocketradio"

    enum Key: String {
        case token = "pocketcasts-token"
        case userId = "pocketcasts-userid"
        case email = "pocketcasts-email"
    }

    static func save(_ value: String, for key: Key) {
        // Delete existing first
        delete(key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecValueData as String: value.data(using: .utf8)!,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(_ key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }

        return value
    }

    static func delete(_ key: Key) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func clearAll() {
        for key in [Key.token, .userId, .email] {
            delete(key)
        }
    }
}
