import Foundation

final class LanguageScorer {
    private let englishWords: Set<String>
    private let russianWords: Set<String>
    private let englishKnownWords: [String]
    private let russianKnownWords: [String]
    private let englishWordsByLength: [Int: [String]]
    private let russianWordsByLength: [Int: [String]]

    init(
        englishWords: Set<String> = LanguageScorer.loadWords(resource: "common_en_words", fallback: LanguageScorer.fallbackEnglishWords),
        russianWords: Set<String> = LanguageScorer.loadWords(resource: "common_ru_words", fallback: LanguageScorer.fallbackRussianWords),
        russianKnownWords: Set<String>? = nil
    ) {
        self.englishWords = englishWords
        self.russianWords = russianWords
        self.englishKnownWords = englishWords.sorted()
        self.russianKnownWords = russianKnownWords?.sorted()
            ?? LanguageScorer.loadWordList(resource: "common_ru_forms", fallback: russianWords)
        self.englishWordsByLength = LanguageScorer.wordsByLength(englishWords)
        self.russianWordsByLength = LanguageScorer.wordsByLength(russianWords)
    }

    func score(_ word: String, language: EasySwitchLanguage) -> Double {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        var score = 0.0
        let lower = trimmed.lowercased()
        if containsWord(trimmed, language: language, exactCase: true) {
            score += 0.7
        } else if containsWord(lower, language: language) {
            score += 0.6
        }

        score += 0.2 * characterSetScore(lower, language: language)
        score += 0.2 * ngramScore(lower, language: language)
        score -= mixedScriptPenalty(lower)
        score -= repeatedUnusualPenalty(lower, language: language)

        return min(1.0, max(0.0, score))
    }

    func containsWord(_ word: String, language: EasySwitchLanguage) -> Bool {
        containsWord(word.lowercased(), language: language, exactCase: false)
    }

    func nearestWord(to word: String, language: EasySwitchLanguage, maxDistance: Int = 1) -> String? {
        let lower = word.lowercased()
        guard !lower.isEmpty else { return nil }
        var bestWord: String?
        var bestDistance = maxDistance + 1

        let wordsByLength = dictionaryByLength(for: language)
        let minLength = max(1, lower.count - maxDistance)
        let maxLength = lower.count + maxDistance

        for length in minLength...maxLength {
            guard let candidates = wordsByLength[length] else { continue }
            for candidate in candidates {
                let distance = editDistance(lower, candidate, maxDistance: maxDistance)
                guard distance <= maxDistance else { continue }
                if distance < bestDistance
                    || (distance == bestDistance && candidate.count > (bestWord?.count ?? 0))
                    || (distance == bestDistance && candidate.count == (bestWord?.count ?? 0) && candidate < (bestWord ?? "")) {
                    bestDistance = distance
                    bestWord = candidate
                }
            }
        }

        guard let bestWord, bestWord != lower else { return nil }
        return preserveCase(from: word, in: bestWord)
    }

    private func characterSetScore(_ word: String, language: EasySwitchLanguage) -> Double {
        let scalars = word.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !scalars.isEmpty else { return 0 }
        let matching = scalars.filter { scalar in
            switch language {
            case .english:
                return isLatin(scalar)
            case .russian:
                return isCyrillic(scalar)
            }
        }
        return Double(matching.count) / Double(scalars.count)
    }

    private func ngramScore(_ word: String, language: EasySwitchLanguage) -> Double {
        let common: Set<String>
        let rare: Set<String>
        switch language {
        case .english:
            common = ["th", "he", "in", "er", "an", "re", "on", "at", "en", "ou", "ing", "ion", "ent"]
            rare = ["qq", "jj", "zx", "xq", "qz", "vv", "ww"]
        case .russian:
            common = ["пр", "ри", "ив", "ве", "ет", "ст", "но", "то", "на", "ен", "ов", "ка", "дел", "как"]
            rare = ["ьь", "ъъ", "йй", "ыы", "эы", "ыэ", "щщ"]
        }

        let hits = common.reduce(0) { $0 + (word.contains($1) ? 1 : 0) }
        let misses = rare.reduce(0) { $0 + (word.contains($1) ? 1 : 0) }
        return min(1.0, max(0.0, Double(hits) / 3.0 - Double(misses) * 0.25))
    }

    private func mixedScriptPenalty(_ word: String) -> Double {
        let hasLatin = word.unicodeScalars.contains(where: isLatin)
        let hasCyrillic = word.unicodeScalars.contains(where: isCyrillic)
        return hasLatin && hasCyrillic ? 0.45 : 0
    }

    private func repeatedUnusualPenalty(_ word: String, language: EasySwitchLanguage) -> Double {
        let unusual: Set<Character> = language == .english ? ["q", "x", "z", "j"] : ["ъ", "ь", "ы", "э", "щ"]
        var previous: Character?
        var repeats = 0
        for char in word {
            if char == previous, unusual.contains(char) {
                repeats += 1
            }
            previous = char
        }
        return min(0.25, Double(repeats) * 0.12)
    }

    private func dictionary(for language: EasySwitchLanguage) -> Set<String> {
        language == .english ? englishWords : russianWords
    }

    private func dictionaryByLength(for language: EasySwitchLanguage) -> [Int: [String]] {
        language == .english ? englishWordsByLength : russianWordsByLength
    }

    private func knownWords(for language: EasySwitchLanguage) -> [String] {
        language == .english ? englishKnownWords : russianKnownWords
    }

    private func containsWord(_ word: String, language: EasySwitchLanguage, exactCase: Bool = false) -> Bool {
        let normalized = exactCase ? word : word.lowercased()
        return knownWords(for: language).binarySearch(normalized)
    }

    private func editDistance(_ lhs: String, _ rhs: String, maxDistance: Int) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        if abs(left.count - right.count) > maxDistance {
            return maxDistance + 1
        }

        var previous = Array(0...right.count)
        var current = Array(repeating: 0, count: right.count + 1)

        for leftIndex in 1...left.count {
            current[0] = leftIndex
            var rowMinimum = current[0]
            for rightIndex in 1...right.count {
                let substitutionCost = left[leftIndex - 1] == right[rightIndex - 1] ? 0 : 1
                current[rightIndex] = min(
                    previous[rightIndex] + 1,
                    current[rightIndex - 1] + 1,
                    previous[rightIndex - 1] + substitutionCost
                )
                rowMinimum = min(rowMinimum, current[rightIndex])
            }
            if rowMinimum > maxDistance {
                return maxDistance + 1
            }
            swap(&previous, &current)
        }

        return previous[right.count]
    }

    private func preserveCase(from source: String, in candidate: String) -> String {
        guard source.contains(where: { $0.isUppercase }) else { return candidate }
        if source.allSatisfy({ !$0.isLetter || $0.isUppercase }) {
            return candidate.uppercased()
        }
        if source.first?.isUppercase == true {
            return candidate.prefix(1).uppercased() + candidate.dropFirst()
        }
        return candidate
    }

    private func isLatin(_ scalar: UnicodeScalar) -> Bool {
        (0x0041...0x005A).contains(scalar.value)
            || (0x0061...0x007A).contains(scalar.value)
            || (0x00C0...0x024F).contains(scalar.value)
    }

    private func isCyrillic(_ scalar: UnicodeScalar) -> Bool {
        (0x0400...0x04FF).contains(scalar.value)
            || (0x0500...0x052F).contains(scalar.value)
    }

    private static func loadWords(resource: String, fallback: Set<String>) -> Set<String> {
        let url = Bundle.main.url(forResource: resource, withExtension: "txt", subdirectory: "EasySwitch")
            ?? Bundle.main.url(forResource: resource, withExtension: "txt")

        guard let url,
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return fallback
        }
        let words = raw
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return Set(words).union(fallback)
    }

    private static func loadWordList(resource: String, fallback: Set<String>) -> [String] {
        let url = Bundle.main.url(forResource: resource, withExtension: "txt", subdirectory: "EasySwitch")
            ?? Bundle.main.url(forResource: resource, withExtension: "txt")

        guard let url,
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return fallback.sorted()
        }

        let words = raw
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        return uniqueSorted(words + Array(fallback))
    }

    private static func uniqueSorted(_ words: [String]) -> [String] {
        var sorted = words.sorted()
        guard !sorted.isEmpty else { return [] }

        var writeIndex = 1
        for readIndex in sorted.indices.dropFirst() where sorted[readIndex] != sorted[writeIndex - 1] {
            sorted[writeIndex] = sorted[readIndex]
            writeIndex += 1
        }
        sorted.removeSubrange(writeIndex...)
        return sorted
    }

    private static func wordsByLength(_ words: Set<String>) -> [Int: [String]] {
        Dictionary(grouping: words, by: { $0.count }).mapValues { $0.sorted() }
    }

    private static let fallbackEnglishWords: Set<String> = [
        "about", "after", "again", "also", "api", "because", "before", "could", "email", "from", "good", "google",
        "hello", "hi", "how", "i", "later", "make", "message", "need", "oauth", "please", "profile", "settings", "should",
        "switch", "text", "thanks", "that", "there", "this", "today", "tomorrow", "want", "what", "when", "where",
        "with", "work", "would", "you"
    ]

    private static let fallbackRussianWords: Set<String> = [
        "будет", "буду", "были", "было", "большое", "быть", "вам", "вас", "ваш", "все", "где", "давай", "давайте", "дела",
        "для", "должен", "если", "есть", "еще", "здесь", "как", "когда", "кофе", "меня", "можем", "может", "можно",
        "надо", "нам", "нас", "нет", "нужно", "они", "оно", "очень", "пока", "после", "почему", "привет",
        "просто", "работает", "роман", "сейчас", "спасибо", "тебя", "тоже", "тогда", "только", "тут", "уже", "хочу", "чтобы", "это"
    ]
}

private extension Array where Element == String {
    func binarySearch(_ word: String) -> Bool {
        var low = 0
        var high = count

        while low < high {
            let middle = low + (high - low) / 2
            if self[middle] == word {
                return true
            }
            if self[middle] < word {
                low = middle + 1
            } else {
                high = middle
            }
        }

        return false
    }
}
