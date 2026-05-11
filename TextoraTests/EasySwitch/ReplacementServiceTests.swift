import XCTest

final class ReplacementServiceTests: XCTestCase {
    func testReplacementMarksRecursiveGuardAndCompletes() {
        let defaults = UserDefaults(suiteName: "Textora.EasySwitch.ReplacementServiceTests.\(UUID().uuidString)")!
        var backspaces = 0
        var typed: [String] = []
        let service = ReplacementService(
            userDictionary: UserDictionary(defaults: defaults),
            eventSink: .init(
                postBackspace: { backspaces += 1 },
                typeText: { typed.append($0); return true },
                pasteText: { _ in XCTFail("paste fallback should not be used") },
                selectKeyboardLayout: { _ in true }
            )
        )

        let expectation = expectation(description: "replacement completed")
        service.replacePreviousWord(
            original: "ghbdtn",
            replacement: "привет",
            delimiter: " ",
            targetKeyboardLayout: .russian,
            switchKeyboardLayout: true
        ) {
            expectation.fulfill()
        }

        XCTAssertTrue(service.isReplacing)
        wait(for: [expectation], timeout: 1)
        XCTAssertFalse(service.isReplacing)
        XCTAssertEqual(backspaces, 6)
        XCTAssertEqual(typed, ["привет "])
    }

    func testUndoRestoresOriginalAndAddsTemporaryIgnore() {
        let defaults = UserDefaults(suiteName: "Textora.EasySwitch.ReplacementServiceUndoTests.\(UUID().uuidString)")!
        let dictionary = UserDictionary(defaults: defaults)
        var typed: [String] = []
        let service = ReplacementService(
            userDictionary: dictionary,
            eventSink: .init(
                postBackspace: { },
                typeText: { typed.append($0); return true },
                pasteText: { _ in },
                selectKeyboardLayout: { _ in true }
            )
        )

        let replaceDone = expectation(description: "replace")
        service.replacePreviousWord(
            original: "ghbdtn",
            replacement: "привет",
            delimiter: " ",
            targetKeyboardLayout: .russian,
            switchKeyboardLayout: false
        ) {
            replaceDone.fulfill()
        }
        wait(for: [replaceDone], timeout: 1)

        let undoDone = expectation(description: "undo")
        XCTAssertTrue(service.undoLastReplacement { undoDone.fulfill() })
        wait(for: [undoDone], timeout: 1)

        XCTAssertEqual(typed, ["привет ", "ghbdtn "])
        XCTAssertTrue(dictionary.isWhitelisted("ghbdtn"))
    }
}
