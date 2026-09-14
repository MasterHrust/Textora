import Foundation

enum SpeechLanguage: String, CaseIterable, Identifiable {
    case bulgarian = "bg", croatian = "hr", czech = "cs", danish = "da"
    case dutch = "nl", english = "en", estonian = "et", finnish = "fi"
    case french = "fr", german = "de", greek = "el", hungarian = "hu"
    case italian = "it", latvian = "lv", lithuanian = "lt", maltese = "mt"
    case polish = "pl", portuguese = "pt", romanian = "ro", russian = "ru"
    case slovak = "sk", slovenian = "sl", spanish = "es", swedish = "sv"
    case ukrainian = "uk"

    var id: String { rawValue }

    var displayName: String {
        Locale.current.localizedString(forLanguageCode: rawValue)?.capitalized ?? rawValue.uppercased()
    }

    var flag: String {
        let regions: [String: String] = [
            "bg": "BG", "hr": "HR", "cs": "CZ", "da": "DK", "nl": "NL",
            "en": "GB", "et": "EE", "fi": "FI", "fr": "FR", "de": "DE",
            "el": "GR", "hu": "HU", "it": "IT", "lv": "LV", "lt": "LT",
            "mt": "MT", "pl": "PL", "pt": "PT", "ro": "RO", "ru": "RU",
            "sk": "SK", "sl": "SI", "es": "ES", "sv": "SE", "uk": "UA"
        ]
        return (regions[rawValue] ?? "GB").unicodeScalars.compactMap {
            UnicodeScalar(127397 + $0.value).map(String.init)
        }.joined()
    }

    static func matching(languageIdentifier: String?) -> SpeechLanguage? {
        guard let identifier = languageIdentifier?.lowercased() else { return nil }
        let code = identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
        return code.flatMap(SpeechLanguage.init(rawValue:))
    }
}

struct SpeechModelDescriptor: Equatable {
    let name: String
    let fileName: String
    let downloadURL: URL
    let byteCount: Int64
    let sha256: String

    static let parakeetV3Q4 = SpeechModelDescriptor(
        name: "Parakeet V3 Q4_K_M",
        fileName: "parakeet-tdt-0.6b-v3-Q4_K_M.gguf",
        downloadURL: URL(string: "https://huggingface.co/handy-computer/parakeet-tdt-0.6b-v3-gguf/resolve/85ac09ea12fc4b1112fa76810059364bc6adc9de/parakeet-tdt-0.6b-v3-Q4_K_M.gguf")!,
        byteCount: 485_425_504,
        sha256: "b68557be1e3c40207fd7c4bd9d63f1d3316b963f15325bfb0cc16a8bb0ffd181"
    )
}

enum OfflineDictationSettings {
    static let didChangeNotification = Notification.Name("OfflineDictation.settingsDidChange")

    private enum Keys {
        static let enabled = "offlineDictation.enabled"
        static let microphoneUID = "offlineDictation.microphoneUID"
        static let fallbackLanguage = "offlineDictation.fallbackLanguage"
        static let capsuleOriginX = "offlineDictation.capsule.originX"
        static let capsuleOriginY = "offlineDictation.capsule.originY"
        static let microphoneDockOriginX = "offlineDictation.microphoneDock.originX"
        static let microphoneDockOriginY = "offlineDictation.microphoneDock.originY"
    }

    static func registerDefaults(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            Keys.enabled: false,
            Keys.microphoneUID: "",
            Keys.fallbackLanguage: SpeechLanguage.english.rawValue
        ])
    }

    static var isEnabled: Bool {
        get { isEnabled(defaults: .standard) }
        set { setEnabled(newValue, defaults: .standard) }
    }

    static var microphoneUID: String {
        get { microphoneUID(defaults: .standard) }
        set { setMicrophoneUID(newValue, defaults: .standard) }
    }

    static var fallbackLanguage: SpeechLanguage {
        get {
            fallbackLanguage(defaults: .standard)
        }
        set { setFallbackLanguage(newValue, defaults: .standard) }
    }

    static func isEnabled(defaults: UserDefaults) -> Bool {
        registerDefaults(defaults)
        return defaults.bool(forKey: Keys.enabled)
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults) {
        set(enabled, forKey: Keys.enabled, defaults: defaults)
    }

    static func microphoneUID(defaults: UserDefaults) -> String {
        registerDefaults(defaults)
        return defaults.string(forKey: Keys.microphoneUID) ?? ""
    }

    static func setMicrophoneUID(_ uid: String, defaults: UserDefaults) {
        set(uid, forKey: Keys.microphoneUID, defaults: defaults)
    }

    static func fallbackLanguage(defaults: UserDefaults) -> SpeechLanguage {
        registerDefaults(defaults)
        let raw = defaults.string(forKey: Keys.fallbackLanguage) ?? SpeechLanguage.english.rawValue
        return SpeechLanguage(rawValue: raw) ?? .english
    }

    static func setFallbackLanguage(_ language: SpeechLanguage, defaults: UserDefaults) {
        set(language.rawValue, forKey: Keys.fallbackLanguage, defaults: defaults)
    }

    static var capsuleOrigin: CGPoint? {
        get {
            guard UserDefaults.standard.object(forKey: Keys.capsuleOriginX) != nil,
                  UserDefaults.standard.object(forKey: Keys.capsuleOriginY) != nil else { return nil }
            return CGPoint(
                x: UserDefaults.standard.double(forKey: Keys.capsuleOriginX),
                y: UserDefaults.standard.double(forKey: Keys.capsuleOriginY)
            )
        }
        set {
            guard let newValue else {
                UserDefaults.standard.removeObject(forKey: Keys.capsuleOriginX)
                UserDefaults.standard.removeObject(forKey: Keys.capsuleOriginY)
                return
            }
            UserDefaults.standard.set(newValue.x, forKey: Keys.capsuleOriginX)
            UserDefaults.standard.set(newValue.y, forKey: Keys.capsuleOriginY)
        }
    }

    static var microphoneDockOrigin: CGPoint? {
        get {
            guard UserDefaults.standard.object(forKey: Keys.microphoneDockOriginX) != nil,
                  UserDefaults.standard.object(forKey: Keys.microphoneDockOriginY) != nil else { return nil }
            return CGPoint(
                x: UserDefaults.standard.double(forKey: Keys.microphoneDockOriginX),
                y: UserDefaults.standard.double(forKey: Keys.microphoneDockOriginY)
            )
        }
        set {
            guard let newValue else {
                UserDefaults.standard.removeObject(forKey: Keys.microphoneDockOriginX)
                UserDefaults.standard.removeObject(forKey: Keys.microphoneDockOriginY)
                return
            }
            UserDefaults.standard.set(newValue.x, forKey: Keys.microphoneDockOriginX)
            UserDefaults.standard.set(newValue.y, forKey: Keys.microphoneDockOriginY)
        }
    }

    private static func set(_ value: Any, forKey key: String, defaults: UserDefaults) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}

enum SpeechModelState: Equatable {
    case notDownloaded
    case downloading(Double)
    case paused(Double)
    case verifying
    case ready
    case failed(String)

    var progress: Double? {
        switch self {
        case .downloading(let value), .paused(let value): return value
        default: return nil
        }
    }
}
