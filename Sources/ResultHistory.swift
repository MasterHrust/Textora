import AppKit
import Combine
import CryptoKit
import Security

struct OperationResult: Identifiable, Codable, Equatable {
    enum Kind: String, Codable, CaseIterable { case rewrite, translate, dictation, message }
    var id = UUID()
    var date = Date()
    var kind: Kind
    var source: String
    var result: String
    var application: String?
    var language: String?
    var style: String?
    var status = "Ready"
}

struct HistoryPolicy: Codable, Equatable {
    var enabled = false
    var days = 7
    var limit = 200
    var valid: Self {
        Self(enabled: enabled, days: [1, 7, 30].contains(days) ? days : 7,
             limit: [50, 200, 1000].contains(limit) ? limit : 200)
    }
}

enum HistoryEncryptionKey {
    static func load(create: Bool) throws -> SymmetricKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.textora.app.recentResults", kSecAttrAccount as String: "encryption.v1",
            kSecUseDataProtectionKeychain as String: true, kSecAttrSynchronizable as String: false]
        var lookup = query; lookup[kSecReturnData as String] = true; lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var data: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &data)
        if status == errSecSuccess, let data = data as? Data, data.count == 32 { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound, create else { throw FeatureError.unavailableKeychain }
        let key = SymmetricKey(size: .bits256)
        var insert = query
        insert[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw FeatureError.unavailableKeychain }
        return key
    }
}

actor ResultHistoryStore {
    private let url: URL
    private let key: (Bool) throws -> SymmetricKey
    private var entries: [OperationResult] = []
    private var loaded = false
    private var epoch = 0
    private var policy = HistoryPolicy()

    init(url: URL, key: @escaping (Bool) throws -> SymmetricKey = HistoryEncryptionKey.load) {
        self.url = url; self.key = key
    }
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.textora.app/RecentResults/history.v1.encrypted")
    }
    func configure(_ newPolicy: HistoryPolicy, epoch newEpoch: Int, now: Date = Date()) throws -> [OperationResult] {
        guard newEpoch >= epoch else { return entries }
        epoch = newEpoch; policy = newPolicy.valid
        try load()
        try prune(now: now)
        return entries
    }
    private func load() throws {
        guard !loaded else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            let box = try AES.GCM.SealedBox(combined: Data(contentsOf: url))
            let plaintext = try AES.GCM.open(box, using: key(false))
            entries = try JSONDecoder().decode([OperationResult].self, from: plaintext)
        }
        loaded = true
    }
    func record(_ entry: OperationResult, token: Int, now: Date = Date()) throws -> [OperationResult] {
        guard policy.enabled, token == epoch, !entry.result.isEmpty else { return entries }
        try load()
        let previous = entries
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        do { trim(now: now); try persist() }
        catch { entries = previous; throw error }
        return entries
    }
    func remove(_ ids: Set<UUID>) throws -> [OperationResult] {
        try load()
        let previous = entries
        entries.removeAll { ids.contains($0.id) }
        do { try persist() } catch { entries = previous; throw error }
        return entries
    }
    func clear(epoch newEpoch: Int) throws -> [OperationResult] {
        epoch = max(epoch, newEpoch)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        entries = []; loaded = true
        return entries
    }
    func prune(now: Date = Date()) throws {
        try load()
        let before = entries
        trim(now: now)
        if before != entries {
            do { try persist() } catch { entries = before; throw error }
        }
    }
    private func trim(now: Date) {
        let oldest = now.addingTimeInterval(-Double(policy.days) * 86400)
        entries = Array(entries.filter { $0.date > oldest }.sorted { $0.date > $1.date }.prefix(policy.limit))
    }
    private func persist() throws {
        if entries.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        let plaintext = try JSONEncoder().encode(entries)
        guard let encrypted = try AES.GCM.seal(plaintext, using: key(true)).combined else { throw FeatureError.unavailableKeychain }
        var directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try encrypted.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

@MainActor
final class RecentResults: ObservableObject {
    static let shared = RecentResults()
    private let defaults: UserDefaults
    private let repository: ResultHistoryStore
    private var epoch = 0
    private var maintenance: Timer?
    private var started = false
    @Published private(set) var entries: [OperationResult] = []
    @Published private(set) var error = ""
    @Published var policy: HistoryPolicy {
        didSet {
            epoch += 1
            if let data = try? JSONEncoder().encode(policy.valid) { defaults.set(data, forKey: "recentResults.policy.v1") }
            refresh()
        }
    }
    init(defaults: UserDefaults = .standard, repository: ResultHistoryStore? = nil) {
        self.defaults = defaults
        self.repository = repository ?? ResultHistoryStore(url: ResultHistoryStore.defaultURL)
        policy = defaults.data(forKey: "recentResults.policy.v1").flatMap { try? JSONDecoder().decode(HistoryPolicy.self, from: $0) }?.valid ?? HistoryPolicy()
    }
    var consentToken: Int? { policy.enabled ? epoch : nil }
    func start() {
        guard !started else { return }; started = true
        refresh()
        maintenance = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func refresh() {
        let currentEpoch = epoch; let currentPolicy = policy
        Task {
            do {
                let rows = try await repository.configure(currentPolicy, epoch: currentEpoch)
                if epoch == currentEpoch { entries = rows; error = "" }
            } catch { if epoch == currentEpoch { self.error = error.localizedDescription } }
        }
    }
    func record(_ entry: OperationResult, token: Int?) {
        guard let token, token == epoch, policy.enabled else { return }
        let currentPolicy = policy
        Task {
            do {
                _ = try await repository.configure(currentPolicy, epoch: token)
                let rows = try await repository.record(entry, token: token)
                if token == epoch { entries = rows; error = "" }
            } catch { if token == epoch { self.error = error.localizedDescription } }
        }
    }
    func remove(_ ids: Set<UUID>) {
        Task { do { entries = try await repository.remove(ids); error = "" } catch { self.error = error.localizedDescription } }
    }
    func clear() {
        epoch += 1
        let current = epoch
        Task { do {
            let rows = try await repository.clear(epoch: current)
            if current == epoch { entries = rows; error = "" }
        } catch { self.error = error.localizedDescription } }
    }
}
