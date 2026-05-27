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

    func testReplacementCanDeletePassedThroughDelimiterWithoutClipboardFallback() {
        let defaults = UserDefaults(suiteName: "Textora.EasySwitch.ReplacementServiceDelimiterTests.\(UUID().uuidString)")!
        var backspaces = 0
        var typed: [String] = []
        var pasted: [String] = []
        let service = ReplacementService(
            userDictionary: UserDictionary(defaults: defaults),
            eventSink: .init(
                postBackspace: { backspaces += 1 },
                typeText: { typed.append($0); return false },
                pasteText: { pasted.append($0) },
                selectKeyboardLayout: { _ in true }
            )
        )

        let expectation = expectation(description: "replacement completed")
        service.replacePreviousWord(
            original: "ghbdtn",
            replacement: "привет",
            delimiter: " ",
            targetKeyboardLayout: .russian,
            switchKeyboardLayout: false,
            typedDelimiterAlreadyPassedThrough: true
        ) {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(backspaces, 7)
        XCTAssertEqual(typed, ["привет "])
        XCTAssertEqual(pasted, [])
    }

    func testReplacementCanPreferClipboardInsertionForElectronHosts() {
        let defaults = UserDefaults(suiteName: "Textora.EasySwitch.ReplacementServiceClipboardTests.\(UUID().uuidString)")!
        var backspaces = 0
        var typed: [String] = []
        var pasted: [String] = []
        let service = ReplacementService(
            userDictionary: UserDictionary(defaults: defaults),
            eventSink: .init(
                postBackspace: { backspaces += 1 },
                typeText: { typed.append($0); return true },
                pasteText: { pasted.append($0) },
                selectKeyboardLayout: { _ in true }
            )
        )

        let expectation = expectation(description: "replacement completed")
        service.replacePreviousWord(
            original: "Руддщ",
            replacement: "Hello",
            delimiter: " ",
            targetKeyboardLayout: .english,
            switchKeyboardLayout: false,
            preferClipboardInsertion: true
        ) {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(backspaces, 5)
        XCTAssertEqual(typed, [])
        XCTAssertEqual(pasted, ["Hello "])
    }

    func testLayoutReplacementCanReplayPhysicalKeysWithoutClipboard() {
        let defaults = UserDefaults(suiteName: "Textora.EasySwitch.ReplacementServicePhysicalTests.\(UUID().uuidString)")!
        var backspaces = 0
        var typed: [String] = []
        var physical: [String] = []
        var pasted: [String] = []
        var selected: [EasySwitchKeyboardLayout] = []
        let service = ReplacementService(
            userDictionary: UserDictionary(defaults: defaults),
            eventSink: .init(
                postBackspace: { backspaces += 1 },
                typeText: { typed.append($0); return true },
                typePhysicalText: { physical.append($0); return true },
                pasteText: { pasted.append($0) },
                selectKeyboardLayout: { selected.append($0); return true }
            )
        )

        let expectation = expectation(description: "replacement completed")
        service.replacePreviousWord(
            original: "ghbdtn",
            replacement: "привет",
            delimiter: " ",
            targetKeyboardLayout: .russian,
            switchKeyboardLayout: true,
            typedDelimiterAlreadyPassedThrough: true
        ) {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(backspaces, 7)
        XCTAssertEqual(selected, [.russian])
        XCTAssertEqual(physical, ["ghbdtn "])
        XCTAssertEqual(typed, [])
        XCTAssertEqual(pasted, [])
    }

    func testUndoRestoresOriginalAndAddsPersistentIgnore() {
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
        XCTAssertTrue(dictionary.ignoredWords.contains("ghbdtn"))
    }
}
