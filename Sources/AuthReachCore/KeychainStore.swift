import Foundation
import Security

/// Codable values in the login keychain — the native replacement for the
/// Electron app's safeStorage-encrypted files. Google OAuth client
/// credentials and per-account tokens all live here.
public struct KeychainStore: Sendable {
    public let service: String

    public init(service: String = "com.elva-labs.authreach") {
        self.service = service
    }

    public func set<T: Encodable>(_ value: T, forKey key: String) throws {
        let data = try JSONEncoder().encode(value)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.osStatus(addStatus) }
        } else {
            guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
        }
    }

    public func get<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public func remove(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    public enum KeychainError: LocalizedError {
        case osStatus(OSStatus)
        public var errorDescription: String? {
            if case .osStatus(let code) = self {
                return "Keychain error \(code): \(SecCopyErrorMessageString(code, nil) as String? ?? "unknown")"
            }
            return nil
        }
    }
}
