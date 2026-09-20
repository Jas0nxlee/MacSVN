import Foundation
import Security

/// 账号密码保存在系统钥匙串中（仅在用户勾选“记住密码”时写入）
enum CredentialStore {
    private static let service = "MacSVN"

    private struct Payload: Codable {
        var username: String
        var password: String
    }

    static func save(_ credentials: Credentials, for key: String) {
        guard let data = try? JSONEncoder().encode(Payload(username: credentials.username,
                                                           password: credentials.password)) else { return }
        delete(for: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(for key: String) -> Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return nil }
        return Credentials(username: payload.username, password: payload.password)
    }

    static func delete(for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func hasStored(for key: String) -> Bool {
        load(for: key) != nil
    }
}
