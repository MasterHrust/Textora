import Foundation

struct EasySwitchDecision: Equatable {
    enum Action: Equatable {
        case replace
        case skip
    }

    enum Kind: Equatable {
        case layout
        case spelling
        case none
    }

    let action: Action
    let kind: Kind
    let original: String
    let converted: String
    let originalScore: Double
    let convertedScore: Double
    let reason: String
    let sourceLanguage: EasySwitchLanguage
    let targetLanguage: EasySwitchLanguage
}

final class EasySwitchDecisionEngine {
    private let scorer: LanguageScorer
    private let userDictionary: UserDictionary

    init(scorer: LanguageScorer = LanguageScorer(), userDictionary: UserDictionary = UserDictionary()) {
        self.scorer = scorer
        self.userDictionary = userDictionary
    }

    func decision(
        for word: String,
        currentLanguage: EasySwitchLanguage,
        settings: EasySwitchSettings
    ) -> EasySwitchDecision {
        let sourceLanguage = inferredLanguage(for: word) ?? currentLanguage
        let targetLanguage = KeyboardLayoutMapper.oppositeLanguage(for: sourceLanguage)
        let fallbackConverted = ""

        guard settings.autoCorrectWrongLayout || settings.autoCorrectTypos else {
            return skip(word, converted: fallbackConverted, sourceLanguage, targetLanguage, "auto-correct disabled")
        }
        guard settings.isEnabled(sourceLanguage) else {
            return skip(word, converted: fallbackConverted, sourceLanguage, targetLanguage, "language disabled")
        }
        guard word.count >= settings.minimumWordLength else {
            return skip(word, converted: fallbackConverted, sourceLanguage, targetLanguage, "too short")
        }
        guard !shouldExclude(word, userDictionary: userDictionary) else {
            return skip(word, converted: fallbackConverted, sourceLanguage, targetLanguage, "excluded")
        }
        guard !scorer.isProtectedInformalWord(word, language: sourceLanguage) else {
            return skip(word, converted: fallbackConverted, sourceLanguage, targetLanguage, "protected informal word")
        }

        if settings.autoCorrectWrongLayout,
           let layoutDecision = layoutDecision(for: word, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage, settings: settings) {
            return layoutDecision
        }

        if settings.autoCorrectTypos,
           let spellingDecision = spellingDecision(for: word, sourceLanguage: sourceLanguage) {
            return spellingDecision
        }

        guard let converted = KeyboardLayoutMapper.convert(word, from: sourceLanguage) else {
            return skip(word, converted: fallbackConverted, sourceLanguage, targetLanguage, "not mappable")
        }
        return EasySwitchDecision(
            action: .skip,
            kind: .none,
            original: word,
            converted: converted,
            originalScore: scorer.score(word, language: sourceLanguage),
            convertedScore: scorer.score(converted, language: targetLanguage),
            reason: "below thresholds",
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
    }

    private func layoutDecision(
        for word: String,
        sourceLanguage: EasySwitchLanguage,
        targetLanguage: EasySwitchLanguage,
        settings: EasySwitchSettings
    ) -> EasySwitchDecision? {
        guard settings.isEnabled(targetLanguage) else { return nil }
        guard let converted = KeyboardLayoutMapper.convert(word, from: sourceLanguage) else { return nil }
        let originalScore = scorer.score(word, language: sourceLanguage)
        let convertedScore = scorer.score(converted, language: targetLanguage)
        let delta = convertedScore - originalScore

        if convertedScore >= settings.confidenceThreshold && delta >= settings.differenceThreshold {
            return EasySwitchDecision(
                action: .replace,
                kind: .layout,
                original: word,
                converted: converted,
                originalScore: originalScore,
                convertedScore: convertedScore,
                reason: "converted score wins",
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
        }

        return nil
    }

    private func spellingDecision(
        for word: String,
        sourceLanguage: EasySwitchLanguage
    ) -> EasySwitchDecision? {
        let minimumSpellingLength = sourceLanguage == .russian ? 5 : 4
        guard word.count >= minimumSpellingLength else { return nil }

        if let completionDecision = suffixCompletionDecision(for: word, sourceLanguage: sourceLanguage) {
            return completionDecision
        }

        let maxDistance = word.count >= 6 ? 2 : 1
        guard !scorer.containsWord(word, language: sourceLanguage),
              let corrected = scorer.nearestWord(to: word, language: sourceLanguage, maxDistance: maxDistance),
              corrected.lowercased() != word.lowercased() else {
            return nil
        }
        guard isSafeSpellingReplacement(word, corrected: corrected, language: sourceLanguage) else { return nil }
        guard !looksLikePluralOrVerbFormBeingShortened(word, corrected: corrected, language: sourceLanguage) else { return nil }

        return EasySwitchDecision(
            action: .replace,
            kind: .spelling,
            original: word,
            converted: corrected,
            originalScore: scorer.score(word, language: sourceLanguage),
            convertedScore: scorer.score(corrected, language: sourceLanguage),
            reason: "nearest dictionary word",
            sourceLanguage: sourceLanguage,
            targetLanguage: sourceLanguage
        )
    }

    private func suffixCompletionDecision(
        for word: String,
        sourceLanguage: EasySwitchLanguage
    ) -> EasySwitchDecision? {
        let lower = word.lowercased()
        let exactKnown = scorer.containsWord(word, language: sourceLanguage)
        let allowedKnownFragments: Set<String> = sourceLanguage == .russian
            ? ["пожалуйс", "пожалуйст"]
            : []

        guard !exactKnown || allowedKnownFragments.contains(lower) else { return nil }
        guard let completed = scorer.completionCandidate(forPrefix: word, language: sourceLanguage),
              completed.lowercased() != lower else {
            return nil
        }
        guard !addsRussianReflexiveSuffix(lower, completed: completed.lowercased(), language: sourceLanguage) else {
            return nil
        }

        return EasySwitchDecision(
            action: .replace,
            kind: .spelling,
            original: word,
            converted: completed,
            originalScore: scorer.score(word, language: sourceLanguage),
            convertedScore: scorer.score(completed, language: sourceLanguage),
            reason: "safe suffix completion",
            sourceLanguage: sourceLanguage,
            targetLanguage: sourceLanguage
        )
    }

    private func addsRussianReflexiveSuffix(
        _ word: String,
        completed: String,
        language: EasySwitchLanguage
    ) -> Bool {
        guard language == .russian, completed.hasPrefix(word) else { return false }
        let suffix = String(completed.dropFirst(word.count))
        return ["ся", "сь", "тся", "ться"].contains(suffix)
    }

    private func isSafeSpellingReplacement(
        _ word: String,
        corrected: String,
        language: EasySwitchLanguage
    ) -> Bool {
        let lower = word.lowercased()
        let correctedLower = corrected.lowercased()

        if language == .russian, correctedLower.count < lower.count {
            return false
        }
        if correctedLower.count < lower.count {
            return lower.hasPrefix("i") && String(lower.dropFirst()) == correctedLower
        }

        if lower.count == correctedLower.count {
            let mismatches = zip(lower, correctedLower).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
            guard mismatches <= 1 else { return false }
            return lower.count >= (language == .russian ? 7 : 5)
        }

        return correctedLower.count - lower.count <= 2
    }

    private func looksLikePluralOrVerbFormBeingShortened(
        _ word: String,
        corrected: String,
        language: EasySwitchLanguage
    ) -> Bool {
        guard language == .english else { return false }
        let lower = word.lowercased()
        let correctedLower = corrected.lowercased()
        return lower.hasSuffix("s")
            && correctedLower.count < lower.count
            && !correctedLower.hasSuffix("s")
    }

    private func inferredLanguage(for word: String) -> EasySwitchLanguage? {
        var latinCount = 0
        var cyrillicCount = 0

        for scalar in word.unicodeScalars {
            switch scalar.value {
            case 0x0041...0x005A, 0x0061...0x007A:
                latinCount += 1
            case 0x0400...0x04FF, 0x0500...0x052F:
                cyrillicCount += 1
            default:
                continue
            }
        }

        guard latinCount != cyrillicCount else { return nil }
        return latinCount > cyrillicCount ? .english : .russian
    }

    private func skip(
        _ word: String,
        converted: String,
        _ source: EasySwitchLanguage,
        _ target: EasySwitchLanguage,
        _ reason: String
    ) -> EasySwitchDecision {
        EasySwitchDecision(
            action: .skip,
            kind: .none,
            original: word,
            converted: converted,
            originalScore: 0,
            convertedScore: 0,
            reason: reason,
            sourceLanguage: source,
            targetLanguage: target
        )
    }

    private func shouldExclude(_ word: String, userDictionary: UserDictionary) -> Bool {
        if userDictionary.isWhitelisted(word) { return true }
        if word.contains("@") || word.contains("/") || word.contains("\\") || word.contains("_") { return true }
        if word.contains(where: { $0.isNumber }) { return true }

        let lower = word.lowercased()
        if lower.contains("://") || lower.hasPrefix("www.") { return true }
        if word.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil { return true }
        if word.range(of: #"^[A-Za-z]:\\|^/|^\.\.?/"#, options: .regularExpression) != nil { return true }
        if word.range(of: #"[{}()<>=;]"#, options: .regularExpression) != nil { return true }
        if word.range(of: #"[a-z][A-Z]"#, options: .regularExpression) != nil { return true }
        if word.allSatisfy({ !$0.isLetter || $0.isUppercase }), word.count <= 5 { return true }
        if ["cny", "myr", "eur", "usd", "gbp", "jpy", "rub", "uah"].contains(lower) { return true }

        return false
    }
}
