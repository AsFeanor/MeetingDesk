import Foundation
import Security

/// GitHub credentials are separate from optional transcription API credentials.
enum GitHubUpdateKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.altugegesari.meetingdesk.github-updates",
         kSecAttrAccount as String: "read-only-repository-token"]
    }

    static func load() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else { throw failure(status) }
        return token
    }

    static func save(_ token: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, value in value }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let inserted = SecItemAdd(item as CFDictionary, nil)
            guard inserted == errSecSuccess else { throw failure(inserted) }
        } else if status != errSecSuccess {
            throw failure(status)
        }
    }

    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }

    private static func failure(_ status: OSStatus) -> NSError {
        // Do not include credentials, URLs containing credentials, or arbitrary error payloads.
        NSError(domain: "com.altugegesari.meetingdesk.update-keychain", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "GitHub erişim anahtarı Anahtar Zinciri’nde okunamadı veya kaydedilemedi."])
    }
}
