import Foundation
import Carbon

enum EasySwitchLanguage: String, CaseIterable {
    case english
    case russian
}

enum EasySwitchKeyboardLayout {
    case english
    case russian
    case other
}

enum KeyboardLayoutMapper {
    static let enToRu: [Character: Character] = [
        "`": "ё", "q": "й", "w": "ц", "e": "у", "r": "к", "t": "е", "y": "н", "u": "г", "i": "ш", "o": "щ", "p": "з",
        "[": "х", "]": "ъ", "a": "ф", "s": "ы", "d": "в", "f": "а", "g": "п", "h": "р", "j": "о", "k": "л",
        "l": "д", ";": "ж", "'": "э", "z": "я", "x": "ч", "c": "с", "v": "м", "b": "и", "n": "т", "m": "ь",
        ",": "б", ".": "ю"
    ]

    static let ruToEn: [Character: Character] = Dictionary(
        uniqueKeysWithValues: enToRu.map { ($0.value, $0.key) }
    )

    static func oppositeLanguage(for language: EasySwitchLanguage) -> EasySwitchLanguage {
        language == .english ? .russian : .english
    }

    static func convert(_ text: String, from source: EasySwitchLanguage) -> String? {
        let map = source == .english ? enToRu : ruToEn
        var result = ""
        result.reserveCapacity(text.count)
        for char in text {
            let lower = Character(String(char).lowercased())
            guard let mapped = map[lower] else { return nil }
            result.append(mapped)
        }
        return preserveCase(from: text, in: result)
    }

    private static func preserveCase(from source: String, in candidate: String) -> String {
        guard source.contains(where: { $0.isUppercase }) else { return candidate }
        if source.allSatisfy({ !$0.isLetter || $0.isUppercase }) {
            return candidate.uppercased()
        }

        var result = ""
        for (sourceChar, candidateChar) in zip(source, candidate) {
            result.append(sourceChar.isUppercase ? String(candidateChar).uppercased() : String(candidateChar))
        }
        if candidate.count > source.count {
            result.append(contentsOf: candidate.dropFirst(source.count))
        }
        return result
    }
}

enum EasySwitchInputSource {
    static func currentKeyboardLayout() -> EasySwitchKeyboardLayout {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return .other
        }
        return keyboardLayout(of: source)
    }

    static func selectKeyboardLayout(_ layout: EasySwitchKeyboardLayout) -> Bool {
        guard let source = selectableInputSource(for: layout) else { return false }
        return TISSelectInputSource(source) == noErr
    }

    private static func selectableInputSource(for layout: EasySwitchKeyboardLayout) -> TISInputSource? {
        let filter: [String: Any] = [
            kTISPropertyInputSourceIsSelectCapable as String: true
        ]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() else {
            return nil
        }
        let sources = list as NSArray
        for item in sources {
            let source = item as! TISInputSource
            if keyboardLayout(of: source) == layout {
                return source
            }
        }
        return nil
    }

    private static func keyboardLayout(of source: TISInputSource) -> EasySwitchKeyboardLayout {
        if let languagesPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) {
            let languages = Unmanaged<CFArray>.fromOpaque(languagesPointer).takeUnretainedValue() as? [String] ?? []
            if languages.contains(where: { $0.lowercased().hasPrefix("ru") }) {
                return .russian
            }
            if languages.contains(where: { $0.lowercased().hasPrefix("en") }) {
                return .english
            }
        }

        if let idPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            let identifier = (Unmanaged<CFString>.fromOpaque(idPointer).takeUnretainedValue() as String).lowercased()
            if identifier.contains("russian") || identifier.contains(".ru") {
                return .russian
            }
            if identifier.contains("abc") || identifier.contains("us") || identifier.contains("english") {
                return .english
            }
        }

        return .other
    }
}
