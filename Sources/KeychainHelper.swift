import Foundation
import Security

enum KeychainHelper {
    private static let service = "io.fixness.app"
    private static let account = "apiTokens"

    private static var cache: [String: String] = [:]
    private static var cacheLoaded = false

    static let openAIKeyAccount = "openaiKey"
    static let geminiKeyAccount = "geminiKey"
    static let claudeKeyAccount = "claudeKey"
    static let customTokenAccount = "customToken"

    // MARK: - Public API

    static func save(key: String, value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        cache[key] = trimmed
        persistCache()
    }

    static func read(key: String) -> String? {
        loadCacheIfNeeded()
        let val = cache[key] ?? ""
        return val.isEmpty ? nil : val
    }

    static func delete(key: String) {
        cache[key] = ""
        persistCache()
    }

    /// Batch-save all provider tokens in a single Keychain write.
    static func saveAll(openAI: String, gemini: String, claude: String, custom: String) {
        cache[openAIKeyAccount] = openAI.trimmingCharacters(in: .whitespacesAndNewlines)
        cache[geminiKeyAccount] = gemini.trimmingCharacters(in: .whitespacesAndNewlines)
        cache[claudeKeyAccount] = claude.trimmingCharacters(in: .whitespacesAndNewlines)
        cache[customTokenAccount] = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        persistCache()
    }

    /// Read all tokens into memory. Call once after onboarding / accessibility wizard completes.
    static func warmUpCache() {
        guard !cacheLoaded else { return }
        cacheLoaded = true
        if let dict = readBlob() {
            cache = dict
        }
    }

    // MARK: - Migration (one-time: old keychain / UserDefaults / file → Data Protection Keychain)

    static func migrateIfNeeded() {
        let migrated = UserDefaults.standard.bool(forKey: "tokens.dp.migrated")
        guard !migrated else { return }

        // 1. Old single-blob entry in the legacy file-based keychain (v2).
        if let dict = readLegacyBlob() {
            for (k, v) in dict where !v.isEmpty {
                cache[k] = v
            }
            deleteLegacyBlob()
        }

        // 2. Old per-key entries in the legacy keychain (v1).
        for key in [openAIKeyAccount, geminiKeyAccount, claudeKeyAccount, customTokenAccount] {
            if let val = readLegacyEntry(key: key), !val.isEmpty {
                if (cache[key] ?? "").isEmpty { cache[key] = val }
                deleteLegacyEntry(key: key)
            }
        }

        // 3. Very old UserDefaults storage.
        for key in [openAIKeyAccount, geminiKeyAccount, claudeKeyAccount, customTokenAccount] {
            if let val = UserDefaults.standard.string(forKey: key), !val.isEmpty {
                if (cache[key] ?? "").isEmpty { cache[key] = val }
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        // 4. Intermediate file-based storage (tokens.json).
        if let fileTokens = readFromFile() {
            for (k, v) in fileTokens where !v.isEmpty {
                if (cache[k] ?? "").isEmpty { cache[k] = v }
            }
            removeTokensFile()
        }

        if cache.values.contains(where: { !$0.isEmpty }) {
            persistCache()
        }

        cacheLoaded = true
        UserDefaults.standard.set(true, forKey: "tokens.dp.migrated")
        UserDefaults.standard.set(true, forKey: "tokens.file.migrated")
        UserDefaults.standard.set(true, forKey: "keychain.migrated.v2")
        UserDefaults.standard.set(true, forKey: "keychain.migrated")
    }

    // MARK: - Data Protection Keychain (modern, no system prompts)

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    private static func loadCacheIfNeeded() {
        guard !cacheLoaded else { return }
        warmUpCache()
    }

    private static func readBlob() -> [String: String]? {
        // Try Data Protection Keychain first (modern, no prompts).
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data,
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            return dict
        }
        // Data Protection Keychain unavailable — try file fallback.
        return readFromFile()
    }

    private static func persistCache() {
        let nonEmpty = cache.filter { !$0.value.isEmpty }
        SecItemDelete(baseQuery as CFDictionary)
        guard !nonEmpty.isEmpty, let data = try? JSONEncoder().encode(nonEmpty) else {
            removeTokensFile()
            return
        }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecSuccess {
            removeTokensFile()
        } else {
            // Data Protection Keychain write failed (missing entitlement / unsigned build).
            // Persist to Application Support file so tokens survive restart.
            writeToFile(nonEmpty)
        }
    }

    private static func writeToFile(_ dict: [String: String]) {
        let dir = tokensFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: tokensFileURL, options: .atomic)
    }

    // MARK: - Legacy file-based keychain (for migration only — triggers prompts)

    private static func readLegacyBlob() -> [String: String]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    private static func deleteLegacyBlob() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func readLegacyEntry(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteLegacyEntry(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - File-based storage (intermediate format, for migration only)

    private static var tokensFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("io.fixness.app", isDirectory: true)
            .appendingPathComponent("tokens.json")
    }

    private static func readFromFile() -> [String: String]? {
        guard let data = try? Data(contentsOf: tokensFileURL) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    private static func removeTokensFile() {
        try? FileManager.default.removeItem(at: tokensFileURL)
    }
}
