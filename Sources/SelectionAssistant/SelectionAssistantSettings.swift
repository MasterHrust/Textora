import Foundation

enum SelectionAssistantSettings {
    static let settingsDidChangeNotification = Notification.Name("SelectionAssistant.settingsDidChange")

    enum Keys {
        static let enabled = "selectionAssistant.beta.enabled"
        static let toolboxEnabled = "selectionAssistant.toolbox.enabled"
        static let floatingIconEnabled = "selectionAssistant.floatingIcon.enabled"
        static let diagnosticsEnabled = "selectionAssistant.diagnostics.enabled"
        static let operation = "selectionAssistant.operation"
    }

    static func registerDefaults(defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            Keys.enabled: true,
            Keys.toolboxEnabled: true,
            Keys.floatingIconEnabled: false,
            Keys.diagnosticsEnabled: false,
            Keys.operation: RewriteOperation.fixGrammar.rawValue
        ])
        if defaults.object(forKey: Keys.enabled) as? Bool != true {
            defaults.set(true, forKey: Keys.enabled)
        }
        if defaults.object(forKey: Keys.toolboxEnabled) == nil {
            defaults.set(true, forKey: Keys.toolboxEnabled)
        }
        if defaults.object(forKey: Keys.floatingIconEnabled) == nil {
            defaults.set(false, forKey: Keys.floatingIconEnabled)
        }
        if defaults.object(forKey: Keys.diagnosticsEnabled) == nil {
            defaults.set(false, forKey: Keys.diagnosticsEnabled)
        }
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

    static func setToolboxEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Keys.toolboxEnabled)
        defaults.set(true, forKey: Keys.enabled)
        NotificationCenter.default.post(name: settingsDidChangeNotification, object: nil)
    }

    static func setFloatingIconEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Keys.floatingIconEnabled)
        defaults.set(true, forKey: Keys.enabled)
        NotificationCenter.default.post(name: settingsDidChangeNotification, object: nil)
    }

    static func setDiagnosticsEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Keys.diagnosticsEnabled)
        NotificationCenter.default.post(name: settingsDidChangeNotification, object: nil)
    }

    static func diagnosticsEnabled(defaults: UserDefaults = .standard) -> Bool {
        registerDefaults(defaults: defaults)
        return defaults.bool(forKey: Keys.diagnosticsEnabled)
    }
}
