import XCTest

final class DecisionEngineTests: XCTestCase {
    private var defaults: UserDefaults!
    private var userDictionary: UserDictionary!
    private var engine: EasySwitchDecisionEngine!
    private var settings: EasySwitchSettings!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "Textora.EasySwitch.DecisionEngineTests.\(UUID().uuidString)")!
        EasySwitchSettings.registerDefaults(defaults: defaults)
        userDictionary = UserDictionary(defaults: defaults)
        engine = EasySwitchDecisionEngine(
            scorer: LanguageScorer(
                englishWords: ["hello", "google", "oauth", "meettora", "response", "want"],
                russianWords: ["привет", "как", "когда", "тогда", "для", "дела", "сделай", "задачу", "блин", "пусть", "большое", "пожалуйста"],
                russianKnownWords: ["привет", "как", "когда", "тогда", "для", "дела", "сделай", "задачу", "блин", "пусть", "большое", "пожалуйста", "плиз"]
            ),
            userDictionary: userDictionary
        )
        settings = EasySwitchSettings.current(defaults: defaults)
    }

    func testWrongEnglishLayoutSwitchesToRussian() {
        let decision = engine.decision(for: "ghbdtn", currentLanguage: .english, settings: settings)
        XCTAssertEqual(decision.action, .replace)
        XCTAssertEqual(decision.converted, "привет")
    }

    func testWordScriptOverridesCurrentLayoutWhenNeeded() {
        let latinDecision = engine.decision(for: "Ghbdtn", currentLanguage: .russian, settings: settings)
        XCTAssertEqual(latinDecision.action, .replace)
        XCTAssertEqual(latinDecision.converted, "Привет")

        let cyrillicDecision = engine.decision(for: "Руддщ", currentLanguage: .english, settings: settings)
        XCTAssertEqual(cyrillicDecision.action, .replace)
        XCTAssertEqual(cyrillicDecision.converted, "Hello")
    }

    func testNormalEnglishWordsDoNotSwitch() {
        XCTAssertEqual(engine.decision(for: "hello", currentLanguage: .english, settings: settings).action, .skip)
        XCTAssertEqual(engine.decision(for: "Google", currentLanguage: .english, settings: settings).action, .skip)
    }

    func testTyposDoNotUseDictionaryCorrection() {
        for (word, language) in [("Првет", EasySwitchLanguage.russian), ("respons", .english)] {
            let decision = engine.decision(for: word, currentLanguage: language, settings: settings)
            XCTAssertEqual(decision.action, .skip, word)
            XCTAssertEqual(decision.kind, .none, word)
        }
    }

    func testValidRussianWordNearAnotherDictionaryWordDoesNotChange() {
        for word in ["блин", "пусть", "тогда", "сделай", "задачу"] {
            let decision = engine.decision(for: word, currentLanguage: .russian, settings: settings)
            XCTAssertEqual(decision.action, .skip, word)
        }
    }

    func testThreeLetterSlangDoesNotAutocorrectToNearbyDictionaryWord() {
        let decision = engine.decision(for: "Бля", currentLanguage: .russian, settings: settings)
        XCTAssertEqual(decision.action, .skip)
    }

    func testShortRussianInformalWordsAndFragmentsDoNotAutocorrect() {
        for word in ["плиз", "пасиб", "спс", "канеш", "щас", "чё", "всм", "йста"] {
            let decision = engine.decision(for: word, currentLanguage: .russian, settings: settings)
            XCTAssertEqual(decision.action, .skip, word)
        }
    }

    func testEnglishInternetSlangDoesNotSwitchOrAutocorrect() {
        for word in ["brb", "afaik", "ofc", "wdym", "tldr", "iykyk"] {
            let decision = engine.decision(for: word, currentLanguage: .english, settings: settings)
            XCTAssertEqual(decision.action, .skip, word)
        }
    }

    func testExcludedTokensDoNotSwitch() {
        XCTAssertEqual(engine.decision(for: "API", currentLanguage: .english, settings: settings).action, .skip)
        XCTAssertEqual(engine.decision(for: "user@example.com", currentLanguage: .english, settings: settings).action, .skip)
        XCTAssertEqual(engine.decision(for: "CNY", currentLanguage: .english, settings: settings).action, .skip)
        XCTAssertEqual(engine.decision(for: "MYR", currentLanguage: .english, settings: settings).action, .skip)
        XCTAssertEqual(engine.decision(for: "OAuth", currentLanguage: .english, settings: settings).action, .skip)
    }

    func testWhitelistedWordDoesNotSwitch() {
        userDictionary.whitelistWords = ["meettora"]
        XCTAssertEqual(engine.decision(for: "meettora", currentLanguage: .english, settings: settings).action, .skip)
    }
}
