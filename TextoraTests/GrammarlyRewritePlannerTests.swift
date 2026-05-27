import XCTest

final class GrammarlyRewritePlannerTests: XCTestCase {
    func testShortElectronCorrectionKeepsTrailingQuestionMarkInsidePlan() {
        let changes = GrammarlyRewritePlanner.physicalChanges(
            original: "ar u how?",
            corrected: "How are you?"
        )

        XCTAssertEqual(changes, [
            .init(range: NSRange(location: 0, length: 8), replacement: "How are you")
        ])
        XCTAssertEqual(GrammarlyRewritePlanner.applying(changes ?? [], to: "ar u how?"), "How are you?")
    }

    func testLongTextPlansMultipleSafeWordCorrections() {
        let original = "First sentnce has bad grammer.\nSecond line is teh same."
        let corrected = "First sentence has bad grammar.\nSecond line is the same."
        let changes = GrammarlyRewritePlanner.physicalChanges(original: original, corrected: corrected)

        XCTAssertEqual(GrammarlyRewritePlanner.applying(changes ?? [], to: original), corrected)
        XCTAssertEqual(changes?.count, 3)
    }

    func testRussianShortCorrectionUsesUtf16Ranges() {
        let original = "Привет, ка дела?"
        let corrected = "Привет, как дела?"
        let changes = GrammarlyRewritePlanner.physicalChanges(original: original, corrected: corrected)

        XCTAssertEqual(changes, [
            .init(range: NSRange(location: 10, length: 0), replacement: "к")
        ])
        XCTAssertEqual(GrammarlyRewritePlanner.applying(changes ?? [], to: original), corrected)
    }

    func testRussianSentencePlansMultiplePointCorrections() {
        let original = "Привет ты ка?"
        let corrected = "Привет, ты как?"
        let changes = GrammarlyRewritePlanner.physicalChanges(original: original, corrected: corrected)

        XCTAssertEqual(GrammarlyRewritePlanner.applying(changes ?? [], to: original), corrected)
        XCTAssertEqual(changes?.count, 2)
    }

    func testRussianProtectedTokensStayUntouched() {
        let original = "Привет @roman проверь https://example.com пж 😊 123"
        let corrected = "Привет, @roman проверь https://example.com, пожалуйста 😊 123"
        let changes = GrammarlyRewritePlanner.physicalChanges(original: original, corrected: corrected)

        XCTAssertEqual(GrammarlyRewritePlanner.applying(changes ?? [], to: original), corrected)
        XCTAssertEqual(protectedStrings(in: original), protectedStrings(in: corrected))
    }

    func testContractionInsertionAnchorsToApostrophe() {
        let original = "Because 8 port will fail at the same time\nSo 8 people could't work?"
        let corrected = "Because 8 ports will fail at the same time.\nSo 8 people couldn't work?"
        let changes = GrammarlyRewritePlanner.physicalChanges(original: original, corrected: corrected)
        let contractionStart = (original as NSString).range(of: "could't").location

        XCTAssertEqual(GrammarlyRewritePlanner.applying(changes ?? [], to: original), corrected)
        XCTAssertTrue(changes?.contains(
            .init(range: NSRange(location: contractionStart + 5, length: 1), replacement: "n'")
        ) ?? false)
    }

    func testProtectedTokensStayUntouchedWhileSurroundingWordsChange() {
        let original = "hey @roman chek https://example.com now 😊 with 123 items"
        let corrected = "Hey @roman check https://example.com now 😊 with 123 items."
        let changes = GrammarlyRewritePlanner.physicalChanges(original: original, corrected: corrected)

        XCTAssertEqual(GrammarlyRewritePlanner.applying(changes ?? [], to: original), corrected)
        let protectedOriginal = protectedStrings(in: original)
        let protectedCorrected = protectedStrings(in: corrected)
        XCTAssertEqual(protectedOriginal, protectedCorrected)
    }

    func testSkipsDirectProtectedTokenMutation() {
        XCTAssertEqual(GrammarlyRewritePlanner.physicalChanges(
            original: "ping @romn today",
            corrected: "ping @roman today"
        ), [])
        XCTAssertEqual(GrammarlyRewritePlanner.physicalChanges(
            original: "use https://exampl.com now",
            corrected: "use https://example.com now"
        ), [])
        XCTAssertEqual(GrammarlyRewritePlanner.physicalChanges(
            original: "we need 123 items",
            corrected: "we need 124 items"
        ), [])
    }

    func testSkipsNumberedAndBulletListMarkerChanges() {
        XCTAssertEqual(GrammarlyRewritePlanner.physicalChanges(
            original: "1. chek this",
            corrected: "2. check this"
        ), [])
        XCTAssertEqual(GrammarlyRewritePlanner.physicalChanges(
            original: "- chek this",
            corrected: "* check this"
        ), [])
    }

    func testSkipsUnsafeProtectedChangeButKeepsSafeCorrections() {
        let original = "Hi @david.setiawan can asist with 3rd party"
        let corrected = "Hi @david.setiawan can assist with third-party"
        let changes = GrammarlyRewritePlanner.physicalChanges(original: original, corrected: corrected)

        XCTAssertEqual(
            GrammarlyRewritePlanner.applying(changes ?? [], to: original),
            "Hi @david.setiawan can assist with 3rd party"
        )
    }

    private func protectedStrings(in text: String) -> [String] {
        let ns = text as NSString
        return GrammarlyRewritePlanner.protectedRanges(in: text).map { ns.substring(with: $0) }
    }
}
