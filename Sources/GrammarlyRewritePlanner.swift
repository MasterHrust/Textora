import Foundation

enum GrammarlyRewritePlanner {
    struct Change: Equatable {
        let range: NSRange
        let replacement: String
    }

    static func physicalChanges(original: String, corrected: String) -> [Change]? {
        let changes = TokenDiff.changes(original: original, corrected: corrected)
        guard !changes.isEmpty else { return [] }

        let originalNS = original as NSString
        let protectedRanges = protectedRanges(in: original)
        var planned: [Change] = []
        for change in changes {
            guard change.range.location >= 0,
                  change.range.length >= 0,
                  NSMaxRange(change.range) <= originalNS.length else {
                return nil
            }

            let originalSpan = change.range.length > 0
                ? originalNS.substring(with: change.range)
                : ""
            let touchedProtectedTokens = protectedTokens(
                touchedBy: change.range,
                in: originalNS,
                protectedRanges: protectedRanges
            )
            if !touchedProtectedTokens.isEmpty {
                guard protectedTokens(in: originalSpan) == touchedProtectedTokens,
                      protectedTokens(in: change.replacement) == touchedProtectedTokens else {
                    continue
                }
            } else if !protectedTokens(in: change.replacement).isEmpty {
                continue
            }

            guard originalSpan != change.replacement else {
                continue
            }
            planned.append(Change(range: change.range, replacement: change.replacement))
        }
        return planned
    }

    static func applying(_ changes: [Change], to original: String) -> String {
        var result = original
        for change in changes.sorted(by: { $0.range.location > $1.range.location }) {
            let ns = result as NSString
            result = ns.replacingCharacters(in: change.range, with: change.replacement)
        }
        return result
    }

    static func protectedRanges(in text: String) -> [NSRange] {
        let pattern = #"(?im)^\s*(?:[-*•]|\d+[.)])\s+|(?i)(?:https?://|www\.)\S+|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}|[@#][\p{L}\p{N}_][\p{L}\p{N}_-]*|\d+(?:[.,:/-]\d+)*%?"#
        let ns = text as NSString
        var ranges: [NSRange] = []
        if let regex = try? NSRegularExpression(pattern: pattern) {
            ranges.append(contentsOf: regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
                trimmedProtectedRange($0.range, in: ns)
            })
        }
        ranges.append(contentsOf: emojiRanges(in: text))
        return ranges.sorted {
            if $0.location == $1.location {
                return $0.length < $1.length
            }
            return $0.location < $1.location
        }
    }

    private static func protectedTokens(in text: String) -> [String] {
        let ns = text as NSString
        return protectedRanges(in: text).map { ns.substring(with: $0) }
    }

    private static func protectedTokens(
        touchedBy range: NSRange,
        in text: NSString,
        protectedRanges: [NSRange]
    ) -> [String] {
        protectedRanges.compactMap { protectedRange in
            let touches: Bool
            if range.length > 0 {
                touches = NSIntersectionRange(protectedRange, range).length > 0
            } else {
                touches = range.location > protectedRange.location
                    && range.location < NSMaxRange(protectedRange)
            }
            return touches ? text.substring(with: protectedRange) : nil
        }
    }

    private static func emojiRanges(in text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            let cluster = text[index..<next]
            if cluster.unicodeScalars.contains(where: isEmojiScalar) {
                ranges.append(NSRange(index..<next, in: text))
            }
            index = next
        }
        return ranges
    }

    private static func isEmojiScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isEmojiPresentation { return true }
        if scalar.value == 0xFE0F || scalar.value == 0x200D { return true }
        guard scalar.properties.isEmoji else { return false }
        return !(0x30...0x39).contains(scalar.value)
    }

    private static func trimmedProtectedRange(_ range: NSRange, in text: NSString) -> NSRange? {
        var end = NSMaxRange(range)
        let trailingPunctuation = CharacterSet(charactersIn: ".,!?;:")
        while end > range.location {
            let unit = text.character(at: end - 1)
            guard let scalar = UnicodeScalar(unit),
                  trailingPunctuation.contains(scalar) else {
                break
            }
            end -= 1
        }
        guard end > range.location else { return nil }
        return NSRange(location: range.location, length: end - range.location)
    }

}

private enum TokenDiff {
    struct TextChange {
        let range: NSRange
        let replacement: String
    }

    struct Token {
        let text: String
        let range: NSRange
    }

    static func changes(original: String, corrected: String) -> [TextChange] {
        let origTokens = tokenize(original)
        let corrTokens = tokenize(corrected)
        let matched = lcsIndices(origTokens.map(\.text), corrTokens.map(\.text))
        let anchors: [(oi: Int, ci: Int)] = [(-1, -1)] + matched + [(origTokens.count, corrTokens.count)]
        let origNS = original as NSString
        let corrNS = corrected as NSString
        var result: [TextChange] = []

        for k in 0..<(anchors.count - 1) {
            let prev = anchors[k]
            let next = anchors[k + 1]
            let oGapStart = prev.oi + 1
            let oGapEnd = next.oi
            let cGapStart = prev.ci + 1
            let cGapEnd = next.ci
            if oGapStart == oGapEnd && cGapStart == cGapEnd { continue }

            let origFrom = prev.oi >= 0
                ? origTokens[prev.oi].range.location + origTokens[prev.oi].range.length
                : 0
            let origTo = next.oi < origTokens.count
                ? origTokens[next.oi].range.location
                : origNS.length
            let corrFrom = prev.ci >= 0
                ? corrTokens[prev.ci].range.location + corrTokens[prev.ci].range.length
                : 0
            let corrTo = next.ci < corrTokens.count
                ? corrTokens[next.ci].range.location
                : corrNS.length

            let range = NSRange(location: origFrom, length: origTo - origFrom)
            let replacement = corrNS.substring(with: NSRange(location: corrFrom, length: corrTo - corrFrom))
            if origNS.substring(with: range) != replacement {
                result.append(minimizedChange(original: origNS, range: range, replacement: replacement))
            }
        }

        return result
    }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        let ns = text as NSString
        var i = 0
        while i < ns.length {
            while i < ns.length {
                let ch = ns.character(at: i)
                guard let scalar = UnicodeScalar(ch),
                      CharacterSet.whitespacesAndNewlines.contains(scalar) else {
                    break
                }
                i += 1
            }
            guard i < ns.length else { break }
            let start = i
            while i < ns.length {
                let ch = ns.character(at: i)
                if let scalar = UnicodeScalar(ch),
                   CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    break
                }
                i += 1
            }
            tokens.append(Token(text: ns.substring(with: NSRange(location: start, length: i - start)), range: NSRange(location: start, length: i - start)))
        }
        return tokens
    }

    private static func minimizedChange(
        original: NSString,
        range: NSRange,
        replacement: String
    ) -> TextChange {
        let originalSpan = original.substring(with: range) as NSString
        let replacementNS = replacement as NSString
        var prefix = 0
        while prefix < originalSpan.length,
              prefix < replacementNS.length,
              originalSpan.character(at: prefix) == replacementNS.character(at: prefix) {
            prefix += 1
        }

        var suffix = 0
        while suffix < originalSpan.length - prefix,
              suffix < replacementNS.length - prefix,
              originalSpan.character(at: originalSpan.length - suffix - 1) == replacementNS.character(at: replacementNS.length - suffix - 1) {
            suffix += 1
        }

        let minimizedRange = NSRange(
            location: range.location + prefix,
            length: originalSpan.length - prefix - suffix
        )
        let minimizedReplacement = replacementNS.substring(
            with: NSRange(
                location: prefix,
                length: replacementNS.length - prefix - suffix
            )
        )
        if minimizedRange.length == 0,
           !minimizedReplacement.isEmpty,
           let anchored = insertionAnchoredToFollowingPunctuation(
                original: original,
                range: minimizedRange,
                replacement: minimizedReplacement
           ) {
            return anchored
        }
        return TextChange(range: minimizedRange, replacement: minimizedReplacement)
    }

    private static func insertionAnchoredToFollowingPunctuation(
        original: NSString,
        range: NSRange,
        replacement: String
    ) -> TextChange? {
        guard range.location >= 0, range.location < original.length else { return nil }
        let anchorRange = original.rangeOfComposedCharacterSequence(at: range.location)
        let anchor = original.substring(with: anchorRange)
        guard isPunctuationAnchor(anchor) else { return nil }
        return TextChange(range: anchorRange, replacement: replacement + anchor)
    }

    private static func isPunctuationAnchor(_ text: String) -> Bool {
        let explicitApostrophes: Set<UnicodeScalar> = ["'", "\u{2019}", "\u{2018}", "\u{02BC}"]
        return text.unicodeScalars.contains { scalar in
            explicitApostrophes.contains(scalar)
                || CharacterSet.punctuationCharacters.contains(scalar)
        }
    }

    private static func lcsIndices(_ a: [String], _ b: [String]) -> [(oi: Int, ci: Int)] {
        let m = a.count
        let n = b.count
        guard m > 0, n > 0 else { return [] }

        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 1...m {
            for j in 1...n {
                if a[i - 1] == b[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        var i = m
        var j = n
        var pairs: [(Int, Int)] = []
        while i > 0, j > 0 {
            if a[i - 1] == b[j - 1] {
                pairs.append((i - 1, j - 1))
                i -= 1
                j -= 1
            } else if dp[i - 1][j] >= dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return pairs.reversed().map { (oi: $0.0, ci: $0.1) }
    }
}
