import Foundation

enum AIProvider: String, CaseIterable, Identifiable {
    case openai
    case gemini
    case claude
    case other

    var id: String { rawValue }

    /// UI label; `rawValue` stays stable for UserDefaults persistence.
    var displayName: String {
        switch self {
        case .openai: return "GPT"
        case .gemini: return "Gemini"
        case .claude: return "Claude"
        case .other: return "Other"
        }
    }
}

/// Short `rawValue` labels keep the popup segmented control even (one word each).
enum RewriteOperation: String, CaseIterable, Identifiable {
    case fixGrammar = "Fix"
    case shorten = "Shorten"
    case makeProfessional = "Formal"
    case humanize = "Humanize"

    var id: String { rawValue }

    var prompt: String {
        switch self {
        case .fixGrammar:
            return """
            You are a precision grammar assistant (Grammarly-style).
            Correct grammar, spelling, punctuation, word order, and obvious shorthand while preserving intended meaning.
            Prefer the smallest complete phrase that sounds natural and correct.
            If the phrase is malformed, reorder words when needed.
            Keep the original language of the input text.
            Do not modify URLs, email addresses, phone numbers, standalone numbers, @mentions, #hashtags, code-like tokens, or words that start with @ or #.
            Do NOT "correct" currency abbreviations or unit symbols. Treat them as protected tokens: EUR, USD, GBP, JPY, CHF, CAD, AUD, CNY, RUB, UAH, etc.; €, $, £, ¥, ₽, ₴; %, ‰, kg, g, lb, km, m, cm, mm, ft, in, mph, kph, °C, °F, …
            Do not use em dashes; use commas, periods, colons, or a regular hyphen only when needed.
            Preserve the author's tone, wording, formatting, and line breaks.
            Preserve ordered-list markers exactly; never remove or rewrite a leading list number, its dot, or the following space.
            If text is already correct, return the exact original text unchanged.
            Return only the final corrected text.
            """
        case .shorten:
            return "Shorten the text while preserving key meaning and tone. Also correct grammar, spelling, punctuation, word order, and obvious shorthand when needed. Keep the original language unchanged. Preserve ordered-list markers exactly; never remove or rewrite a leading list number, its dot, or the following space. Do not modify URLs, email addresses, phone numbers, standalone numbers, @mentions, #hashtags, or code-like tokens. Do not modify currency abbreviations (EUR, USD, GBP, …) or unit symbols (€, $, £, %, kg, km, °C, …). Do not use em dashes. Return only rewritten text."
        case .makeProfessional:
            return "Rewrite in a professional, polished tone. Also correct grammar, spelling, punctuation, word order, and obvious shorthand when needed. Preserve core meaning. Keep the original language unchanged (do not translate). Preserve ordered-list markers exactly; never remove or rewrite a leading list number, its dot, or the following space. Do not modify URLs, email addresses, phone numbers, standalone numbers, @mentions, #hashtags, or code-like tokens. Do not modify currency abbreviations (EUR, USD, GBP, …) or unit symbols (€, $, £, %, kg, km, °C, …). Do not use em dashes. Return only rewritten text."
        case .humanize:
            return "Rewrite to sound natural, human, and less robotic. Also correct grammar, spelling, punctuation, word order, and obvious shorthand when needed. Preserve meaning. Keep the original language unchanged. Preserve ordered-list markers exactly; never remove or rewrite a leading list number, its dot, or the following space. Do not modify URLs, email addresses, phone numbers, standalone numbers, @mentions, #hashtags, or code-like tokens. Do not modify currency abbreviations (EUR, USD, GBP, …) or unit symbols (€, $, £, %, kg, km, °C, …). Do not use em dashes. Return only rewritten text."
        }
    }
}

struct OverlaySuggestion: Identifiable, Equatable {
    let operation: RewriteOperation
    let text: String
    var isRecommended: Bool = false
    var isOptional: Bool = false

    var id: String { operation.rawValue }
    var title: String {
        operation.rawValue
    }
}

struct TextPatch: Identifiable, Equatable {
    let id: String
    let start: Int
    let end: Int
    let originalText: String
    let replacement: String
    let reason: String?

    init(
        id: String = UUID().uuidString,
        start: Int,
        end: Int,
        originalText: String,
        replacement: String,
        reason: String? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.originalText = originalText
        self.replacement = replacement
        self.reason = reason
    }

    var range: NSRange {
        NSRange(location: start, length: max(0, end - start))
    }

    func isValid(in text: String) -> Bool {
        let ns = text as NSString
        guard start >= 0, end >= start, end <= ns.length else { return false }
        return ns.substring(with: range) == originalText
    }

    func applying(to text: String) -> String? {
        guard isValid(in: text) else { return nil }
        let ns = text as NSString
        return ns.replacingCharacters(in: range, with: replacement)
    }

    static func applyAll(_ patches: [TextPatch], to text: String) -> String? {
        guard !patches.isEmpty else { return text }
        let sorted = patches.sorted { lhs, rhs in
            if lhs.start != rhs.start {
                return lhs.start > rhs.start
            }
            return lhs.end > rhs.end
        }

        var previousStart = Int.max
        for patch in sorted {
            if patch.end > previousStart {
                return nil
            }
            previousStart = patch.start
        }

        var result = text
        for patch in sorted {
            guard let updated = patch.applying(to: result) else { return nil }
            result = updated
        }
        return result
    }
}

/// A single localized issue detected inside a segment by the AI
/// "auditor" endpoint. Multiple issues can coexist within one segment,
/// each carrying its own category (which drives the overlay color) and
/// its own `replacement` bounded by `localRange` inside the segment
/// text. UI renders one underline + hover card per issue, and the apply
/// pipeline only rewrites `localRange` instead of the whole scope.
struct OverlayIssue: Identifiable, Equatable {
    let id: UUID
    let patch: TextPatch
    /// Which of the four writing operations best describes the fix —
    /// picked by the AI based on segment context (pure grammar error →
    /// `.fixGrammar`; verbose informal run → `.shorten`; etc.).
    let category: RewriteOperation
    /// Normalized source segment this issue came from. Used for Skip so
    /// dismissing one sentence's suggestion does not hide unrelated markers.
    let segmentSignature: String?
    /// Range of the source segment inside the full focused text when the
    /// issue is rendered in full-text coordinates.
    let sourceSegmentRange: NSRange?

    init(
        id: UUID = UUID(),
        patch: TextPatch,
        category: RewriteOperation,
        segmentSignature: String? = nil,
        sourceSegmentRange: NSRange? = nil
    ) {
        self.id = id
        self.patch = patch
        self.category = category
        self.segmentSignature = segmentSignature
        self.sourceSegmentRange = sourceSegmentRange
    }

    init(
        id: UUID = UUID(),
        localRange: NSRange,
        originalText: String,
        category: RewriteOperation,
        replacement: String,
        reason: String? = nil,
        segmentSignature: String? = nil,
        sourceSegmentRange: NSRange? = nil
    ) {
        self.init(
            id: id,
            patch: TextPatch(
                id: id.uuidString,
                start: localRange.location,
                end: localRange.location + localRange.length,
                originalText: originalText,
                replacement: replacement,
                reason: reason
            ),
            category: category,
            segmentSignature: segmentSignature,
            sourceSegmentRange: sourceSegmentRange
        )
    }

    var localRange: NSRange { patch.range }
    var replacement: String { patch.replacement }
    var reason: String? { patch.reason }

    /// Priority used when multiple issues exist in one segment and we
    /// need to pick a "primary" one (e.g. for the floating-icon ring
    /// color). Lower returns sort earlier: Fix always wins, followed by
    /// Formal, Humanize, Shorten.
    static func priority(of category: RewriteOperation) -> Int {
        switch category {
        case .fixGrammar: return 0
        case .makeProfessional: return 1
        case .humanize: return 2
        case .shorten: return 3
        }
    }
}
