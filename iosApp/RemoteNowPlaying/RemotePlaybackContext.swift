#if canImport(NowPlaying)
import Foundation
import NowPlaying
import Security

@available(iOS 27.0, *)
struct RemotePlaybackAttributes: RemoteMediaSessionAttributes, Equatable {
    let id: String
    let queueID: String
    let playerName: String
}

/// Shared through the containing app's Keychain access group. The system
/// receives only RemotePlaybackAttributes, never a Music Assistant token.
struct RemotePlaybackContext: Codable, Equatable, Sendable {
    let sessionID: String
    let serverURL: URL
    let serverID: String
    let token: String

    private static var query: [String: Any] {[
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Music Assistant Remote Now Playing",
        kSecAttrAccount as String: "active-session"
    ]}

    static func load(sessionID: String) throws -> Self {
        var search = query
        search[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &value)
        guard status == errSecSuccess, let data = value as? Data else {
            throw KeychainError(status: status)
        }
        let context = try JSONDecoder().decode(Self.self, from: data)
        guard context.sessionID == sessionID else { throw KeychainError(status: errSecItemNotFound) }
        return context
    }

    func save() throws {
        let data = try JSONEncoder().encode(self)
        let values = [kSecValueData as String: data]
        let status = SecItemUpdate(Self.query as CFDictionary, values as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }

        var item = Self.query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private struct KeychainError: Error { let status: OSStatus }
}
#endif
