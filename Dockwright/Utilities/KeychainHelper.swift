import Foundation
import os
import Security

nonisolated enum KeychainHelper {
    private static let serviceName = "com.Aatje.Dockwright"

    // In-memory cache to avoid repeated Keychain IPC (~0.5ms per call)
    private static let cacheQueue = DispatchQueue(label: "com.dockwright.keychain.cache")
    private nonisolated(unsafe) static var _readCache: [String: String?] = [:]

    private static func invalidateCache(key: String) {
        cacheQueue.sync { _ = _readCache.removeValue(forKey: key) }
    }

    // MARK: - Save

    static func save(key: String, value: String) {
        invalidateCache(key: key)

        guard let data = value.data(using: .utf8) else { return }

        // Delete ALL existing entries (loop handles duplicates from re-signing)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
        ]
        while SecItemDelete(deleteQuery as CFDictionary) == errSecSuccess { }

        // Add fresh
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            AppLog.security.error("KeychainHelper.save failed for '\(key)': OSStatus \(Int32(status))")
        }
    }

    // MARK: - Read

    static func read(key: String) -> String? {
        // Check cache first
        let cacheHit: (found: Bool, value: String?) = cacheQueue.sync {
            if _readCache.keys.contains(key) {
                return (true, _readCache[key] ?? nil)
            }
            return (false, nil)
        }
        if cacheHit.found { return cacheHit.value }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess,
           let data = result as? Data,
           let value = String(data: data, encoding: .utf8) {
            cacheQueue.sync { _readCache[key] = value }
            return value
        }

        cacheQueue.sync { _readCache[key] = nil as String? }
        return nil
    }

    // MARK: - Delete

    static func delete(key: String) {
        invalidateCache(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Exists

    static func exists(key: String) -> Bool {
        read(key: key) != nil
    }
}
