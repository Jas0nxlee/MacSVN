import Foundation
import Security

/// 登录信息保存在系统钥匙串里，默认有效期 30 天（见 `defaultLifetime`）。
/// 过期条目在读取时会被自动清理；用户主动“退出登录”会立即删除。
enum CredentialStore {
    private static let service = "MacSVN"

    /// 记住登录信息的时长：1 个月
    static let defaultLifetime: TimeInterval = 30 * 24 * 60 * 60

    struct Stored: Codable, Equatable {
        var username: String
        var password: String
        var savedAt: Date
        var expiresAt: Date

        func isExpired(now: Date = Date()) -> Bool {
            now >= expiresAt
        }
    }

    // MARK: 读写

    static func save(_ credentials: Credentials,
                     for key: String,
                     lifetime: TimeInterval = defaultLifetime,
                     now: Date = Date()) {
        let stored = Stored(username: credentials.username,
                            password: credentials.password,
                            savedAt: now,
                            expiresAt: now.addingTimeInterval(lifetime))
        guard let data = try? JSONEncoder().encode(stored) else { return }
        delete(for: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    /// 读取未过期的登录信息；已过期的条目会被删除并返回 nil
    static func load(for key: String, now: Date = Date()) -> Credentials? {
        guard let stored = loadStored(for: key) else { return nil }
        if stored.isExpired(now: now) {
            delete(for: key)
            return nil
        }
        return Credentials(username: stored.username, password: stored.password)
    }

    /// 读取原始记录（含时间戳），供自检与界面显示
    static func loadStored(for key: String) -> Stored? {
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
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return nil }
        return stored
    }

    static func delete(for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: 状态查询

    static func hasValid(for key: String, now: Date = Date()) -> Bool {
        load(for: key, now: now) != nil
    }

    /// 未过期的登录信息何时失效
    static func expiration(for key: String, now: Date = Date()) -> Date? {
        guard let stored = loadStored(for: key), !stored.isExpired(now: now) else { return nil }
        return stored.expiresAt
    }

    static func username(for key: String, now: Date = Date()) -> String? {
        guard let stored = loadStored(for: key), !stored.isExpired(now: now) else { return nil }
        return stored.username
    }
}
