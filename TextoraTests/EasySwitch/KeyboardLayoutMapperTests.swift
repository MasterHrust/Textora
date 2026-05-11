import XCTest

final class KeyboardLayoutMapperTests: XCTestCase {
    func testEnglishToRussianWords() {
        XCTAssertEqual(KeyboardLayoutMapper.convert("ghbdtn", from: .english), "привет")
        XCTAssertEqual(KeyboardLayoutMapper.convert("rfr", from: .english), "как")
        XCTAssertEqual(KeyboardLayoutMapper.convert("ltkf", from: .english), "дела")
    }

    func testRussianToEnglishWord() {
        XCTAssertEqual(KeyboardLayoutMapper.convert("привет", from: .russian), "ghbdtn")
    }

    func testPreservesCase() {
        XCTAssertEqual(KeyboardLayoutMapper.convert("Ghbdtn", from: .english), "Привет")
        XCTAssertEqual(KeyboardLayoutMapper.convert("GHBDTN", from: .english), "ПРИВЕТ")
    }
}
