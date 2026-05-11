import XCTest

final class WordBufferTests: XCTestCase {
    func testDetectsWordBeforeSpaceAndClears() {
        let buffer = WordBuffer()
        "ghbdtn".forEach { buffer.append(String($0)) }
        XCTAssertEqual(buffer.consumeBoundary(delimiter: " "), EasySwitchWordBoundary(word: "ghbdtn", delimiter: " "))
        XCTAssertEqual(buffer.currentWord, "")
    }

    func testDetectsWordBeforePunctuation() {
        let buffer = WordBuffer()
        "ghbdtn".forEach { buffer.append(String($0)) }
        XCTAssertEqual(buffer.consumeBoundary(delimiter: "?"), EasySwitchWordBoundary(word: "ghbdtn", delimiter: "?"))
    }

    func testDelimiterClearsBufferWhenNoReplacementHappens() {
        let buffer = WordBuffer()
        "Привет".forEach { buffer.append(String($0)) }
        XCTAssertEqual(buffer.consumeBoundary(delimiter: ","), EasySwitchWordBoundary(word: "Привет", delimiter: ","))
        XCTAssertEqual(buffer.currentWord, "")
    }

    func testClearsAfterReplacement() {
        let buffer = WordBuffer()
        buffer.append("hello")
        _ = buffer.consumeBoundary(delimiter: " ")
        XCTAssertEqual(buffer.currentWord, "")
    }
}
