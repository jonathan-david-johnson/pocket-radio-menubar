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
