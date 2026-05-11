import Foundation

final class UserDictionary {
    private let defaults: UserDefaults
    private let whitelistKey = "easySwitch.userDictionary.whitelist"
    private let customWordsKey = "easySwitch.userDictionary.customWords"
    private let ignoredWordsKey = "easySwitch.userDictionary.ignoredWords"
    private let learnedCorrectionsKey = "easySwitch.userDictionary.learnedCorrections"
    private var sessionIgnoredWords = Set<String>()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var whitelistWords: Set<String> {
        get { loadSet(whitelistKey) }
        set { saveSet(newValue, key: whitelistKey) }
    }

    var customWords: Set<String> {
        get { loadSet(customWordsKey) }
        set { saveSet(newValue, key: customWordsKey) }
    }

    var ignoredWords: Set<String> {
        get { loadSet(ignoredWordsKey) }
        set { saveSet(newValue, key: ignoredWordsKey) }
    }

    var learnedCorrections: [String: String] {
        get { defaults.dictionary(forKey: learnedCorrectionsKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: learnedCorrectionsKey) }
    }

    func isWhitelisted(_ word: String) -> Bool {
        let key = normalized(word)
        return whitelistWords.contains(key)
            || customWords.contains(key)
            || ignoredWords.contains(key)
            || sessionIgnoredWords.contains(key)
    }

    func addTemporaryIgnore(_ word: String) {
        sessionIgnoredWords.insert(normalized(word))
    }

    func addLearnedCorrection(original: String, replacement: String) {
        var corrections = learnedCorrections
        corrections[normalized(original)] = replacement
        learnedCorrections = corrections
    }

    private func loadSet(_ key: String) -> Set<String> {
        Set(defaults.stringArray(forKey: key)?.map(normalized) ?? [])
    }

    private func saveSet(_ set: Set<String>, key: String) {
        defaults.set(set.sorted(), forKey: key)
    }

    private func normalized(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
