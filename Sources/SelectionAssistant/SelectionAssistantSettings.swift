import Foundation

enum SelectionAssistantSettings {
    static let settingsDidChangeNotification = Notification.Name("SelectionAssistant.settingsDidChange")

    enum Keys {
        static let enabled = "selectionAssistant.beta.enabled"
        static let operation = "selectionAssistant.operation"
    }

    static func registerDefaults(defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            Keys.enabled: false,
            Keys.operation: RewriteOperation.fixGrammar.rawValue
        ])
    }

    static func selectedOperation(defaults: UserDefaults = .standard) -> RewriteOperation {
        registerDefaults(defaults: defaults)
        let raw = defaults.string(forKey: Keys.operation) ?? RewriteOperation.fixGrammar.rawValue
        return RewriteOperation(rawValue: raw) ?? .fixGrammar
    }

    static func setSelectedOperation(_ operation: RewriteOperation, defaults: UserDefaults = .standard) {
        defaults.set(operation.rawValue, forKey: Keys.operation)
        NotificationCenter.default.post(name: settingsDidChangeNotification, object: nil)
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Keys.enabled)
        NotificationCenter.default.post(name: settingsDidChangeNotification, object: nil)
    }
}
