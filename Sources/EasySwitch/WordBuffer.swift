import Foundation

struct EasySwitchWordBoundary: Equatable {
    let word: String
    let delimiter: String
}

final class WordBuffer {
    private(set) var currentWord = ""
    private let maxLength: Int

    init(maxLength: Int = 64) {
        self.maxLength = maxLength
    }

    func append(_ text: String) {
        currentWord.append(text)
        if currentWord.count > maxLength {
            currentWord = String(currentWord.suffix(maxLength))
        }
    }

    func backspace() {
        guard !currentWord.isEmpty else { return }
        currentWord.removeLast()
    }

    func consumeBoundary(delimiter: String) -> EasySwitchWordBoundary? {
        let word = currentWord
        currentWord = ""
        guard !word.isEmpty else { return nil }
        return EasySwitchWordBoundary(word: word, delimiter: delimiter)
    }

    func clear() {
        currentWord = ""
    }
}
