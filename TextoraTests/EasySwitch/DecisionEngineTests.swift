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

    func testSmallRussianTypoUsesDictionaryCorrection() {
        let decision = engine.decision(for: "Првет", currentLanguage: .russian, settings: settings)
        XCTAssertEqual(decision.action, .replace)
        XCTAssertEqual(decision.kind, .spelling)
        XCTAssertEqual(decision.converted, "Привет")
    }

    func testLongRussianTypoAllowsTwoEdits() {
        let decision = engine.decision(for: "билшое", currentLanguage: .russian, settings: settings)
        XCTAssertEqual(decision.action, .replace)
        XCTAssertEqual(decision.kind, .spelling)
        XCTAssertEqual(decision.converted, "большое")
    }

    func testValidRussianWordNearAnotherDictionaryWordDoesNotChange() {
        for word in ["блин", "пусть", "тогда", "сделай", "задачу"] {
            let decision = engine.decision(for: word, currentLanguage: .russian, settings: settings)
            XCTAssertEqual(decision.action, .skip, word)
        }
    }

    func testRussianWordDoesNotShrinkToShorterNearbyDictionaryWord() {
        let engine = EasySwitchDecisionEngine(
            scorer: LanguageScorer(englishWords: [], russianWords: ["дела"], russianKnownWords: ["дела"]),
            userDictionary: userDictionary
        )
        let decision = engine.decision(for: "сделай", currentLanguage: .russian, settings: settings)
        XCTAssertEqual(decision.action, .skip)
    }

    func testThreeLetterSlangDoesNotAutocorrectToNearbyDictionaryWord() {
        let decision = engine.decision(for: "Бля", currentLanguage: .russian, settings: settings)
        XCTAssertEqual(decision.action, .skip)
    }

    func testShortRussianInformalWordsAndFragmentsDoNotAutocorrect() {
        for word in ["плиз", "йста"] {
            let decision = engine.decision(for: word, currentLanguage: .russian, settings: settings)
            XCTAssertEqual(decision.action, .skip, word)
        }
    }

    func testLongRussianTypoStillUsesDictionaryCorrection() {
        let decision = engine.decision(for: "пожалйста", currentLanguage: .russian, settings: settings)
        XCTAssertEqual(decision.action, .replace)
        XCTAssertEqual(decision.kind, .spelling)
        XCTAssertEqual(decision.converted, "пожалуйста")
    }

    func testSmallEnglishTypoUsesDictionaryCorrection() {
        let decision = engine.decision(for: "iwant", currentLanguage: .english, settings: settings)
        XCTAssertEqual(decision.action, .replace)
        XCTAssertEqual(decision.kind, .spelling)
        XCTAssertEqual(decision.converted, "want")
    }

    func testEnglishMissingLastLetterUsesDictionaryCorrection() {
        let decision = engine.decision(for: "respons", currentLanguage: .english, settings: settings)
        XCTAssertEqual(decision.action, .replace)
        XCTAssertEqual(decision.kind, .spelling)
        XCTAssertEqual(decision.converted, "response")
    }

    func testEnglishPluralLikeWordDoesNotShrinkToSingularCandidate() {
        let engine = EasySwitchDecisionEngine(
            scorer: LanguageScorer(
                englishWords: ["misplay"],
                russianWords: [],
                russianKnownWords: []
            ),
            userDictionary: userDictionary
        )
        let decision = engine.decision(for: "displays", currentLanguage: .english, settings: settings)
        XCTAssertEqual(decision.action, .skip)
    }

    func testTypoCorrectionCanBeDisabledSeparately() {
        defaults.set(false, forKey: EasySwitchSettings.Keys.autoCorrectTypos)
        settings = EasySwitchSettings.current(defaults: defaults)
        XCTAssertEqual(engine.decision(for: "Првет", currentLanguage: .russian, settings: settings).action, .skip)
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
