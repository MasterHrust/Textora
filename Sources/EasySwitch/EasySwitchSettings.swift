import Foundation

struct EasySwitchSettings {
    static let settingsDidChangeNotification = Notification.Name("EasySwitch.settingsDidChange")

    enum Keys {
        static let enabled = "easySwitch.enabled"
        static let autoCorrectWrongLayout = "easySwitch.autoCorrectWrongLayout"
        static let autoCorrectTypos = "easySwitch.autoCorrectTypos"
        static let changesKeyboardLayout = "easySwitch.changesKeyboardLayout"
        static let minimumWordLength = "easySwitch.minimumWordLength"
        static let confidenceThreshold = "easySwitch.confidenceThreshold"
        static let differenceThreshold = "easySwitch.differenceThreshold"
        static let englishEnabled = "easySwitch.language.english"
        static let russianEnabled = "easySwitch.language.russian"
        static let showCorrectionNotification = "easySwitch.showCorrectionNotification"
        static let playSoundOnCorrection = "easySwitch.playSoundOnCorrection"
        static let privacyMode = "easySwitch.privacyMode"
    }

    var enabled: Bool
    var autoCorrectWrongLayout: Bool
    var autoCorrectTypos: Bool
    var changesKeyboardLayout: Bool
    var minimumWordLength: Int
    var confidenceThreshold: Double
    var differenceThreshold: Double
    var englishEnabled: Bool
    var russianEnabled: Bool
    var showCorrectionNotification: Bool
    var playSoundOnCorrection: Bool
    var privacyMode: Bool

    static func current(defaults: UserDefaults = .standard) -> EasySwitchSettings {
        registerDefaults(defaults: defaults)
        return EasySwitchSettings(
            enabled: defaults.bool(forKey: Keys.enabled),
            autoCorrectWrongLayout: defaults.bool(forKey: Keys.autoCorrectWrongLayout),
            autoCorrectTypos: defaults.bool(forKey: Keys.autoCorrectTypos),
            changesKeyboardLayout: defaults.bool(forKey: Keys.changesKeyboardLayout),
            minimumWordLength: max(1, defaults.integer(forKey: Keys.minimumWordLength)),
            confidenceThreshold: defaults.double(forKey: Keys.confidenceThreshold),
            differenceThreshold: defaults.double(forKey: Keys.differenceThreshold),
            englishEnabled: defaults.bool(forKey: Keys.englishEnabled),
            russianEnabled: defaults.bool(forKey: Keys.russianEnabled),
            showCorrectionNotification: defaults.bool(forKey: Keys.showCorrectionNotification),
            playSoundOnCorrection: defaults.bool(forKey: Keys.playSoundOnCorrection),
            privacyMode: defaults.bool(forKey: Keys.privacyMode)
        )
    }

    static func registerDefaults(defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            Keys.autoCorrectWrongLayout: true,
            Keys.autoCorrectTypos: true,
            Keys.minimumWordLength: 3,
            Keys.confidenceThreshold: 0.65,
            Keys.differenceThreshold: 0.35,
            Keys.englishEnabled: true,
            Keys.russianEnabled: true,
            Keys.showCorrectionNotification: true,
            Keys.playSoundOnCorrection: false,
            Keys.privacyMode: false
        ])
    }

    func isEnabled(_ language: EasySwitchLanguage) -> Bool {
        switch language {
        case .english:
            return englishEnabled
        case .russian:
            return russianEnabled
        }
    }
}
