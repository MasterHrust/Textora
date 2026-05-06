import AppKit
import SwiftUI

enum FloatingIssueMarkerStyle: Equatable {
    case underline
    case compactDot
}

struct FloatingIssueUnderlineView: View {
    let colors: [Color]
    let isHighlighted: Bool
    let style: FloatingIssueMarkerStyle
    let isLoading: Bool

    init(
        colors: [Color] = TextoraSuggestionColors.brandGradient,
        isHighlighted: Bool = false,
        style: FloatingIssueMarkerStyle = .underline,
        isLoading: Bool = false
    ) {
        self.colors = colors.isEmpty ? TextoraSuggestionColors.brandGradient : colors
        self.isHighlighted = isHighlighted
        self.style = style
        self.isLoading = isLoading
    }

    var body: some View {
        GeometryReader { proxy in
            let activeColors = colors.count == 1 ? [colors[0], colors[0]] : colors
            // Underline-only marker. Previously we also painted a
            // translucent fill rectangle on top of the text — it made
            // the marker easy to spot but it visually obscured the
            // underlying glyphs and (in some hosts) intercepted the
            // user's mouse / caret aiming. The product spec is now
            // "thin colored bar UNDER the words, never on top of
            // them", so we render exactly that: a 2pt gradient bar
            // pinned to the bottom edge of the issue line.
            switch style {
            case .underline:
                let underlineHeight: CGFloat = isHighlighted ? min(4, proxy.size.height) : 2
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: underlineHeight / 2)
                        .fill(
                            LinearGradient(
                                colors: activeColors,
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: proxy.size.width, height: underlineHeight)
                        .shadow(
                            color: activeColors[0].opacity(0.35),
                            radius: isHighlighted ? 2.6 : 1.5,
                            x: 0,
                            y: 0.5
                        )
                }
            case .compactDot:
                let side = min(proxy.size.width, proxy.size.height, isHighlighted ? 16 : 14)
                let lineWidth: CGFloat = isHighlighted ? 3.8 : 3.2
                let segmentColors = activeColors.isEmpty ? TextoraSuggestionColors.brandGradient : activeColors
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.70), lineWidth: lineWidth + 1.6)
                        .frame(width: side, height: side)

                    if isLoading {
                        TimelineView(.animation(minimumInterval: 1.0 / 45.0, paused: false)) { context in
                            let cycle: TimeInterval = 0.75
                            let t = context.date.timeIntervalSinceReferenceDate
                            let phase = (t.truncatingRemainder(dividingBy: cycle) / cycle) * 360.0
                            Circle()
                                .trim(from: 0.15, to: 0.9)
                                .stroke(
                                    segmentColors.first ?? .gray,
                                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                                )
                                .rotationEffect(.degrees(phase))
                                .frame(width: side, height: side)
                        }
                    } else {
                        ForEach(segmentColors.indices, id: \.self) { index in
                            Circle()
                                .trim(
                                    from: CGFloat(index) / CGFloat(segmentColors.count),
                                    to: CGFloat(index + 1) / CGFloat(segmentColors.count)
                                )
                                .stroke(
                                    segmentColors[index],
                                    style: StrokeStyle(
                                        lineWidth: lineWidth,
                                        lineCap: segmentColors.count == 1 ? .round : .butt
                                    )
                                )
                                .rotationEffect(.degrees(-90))
                                .frame(width: side, height: side)
                        }
                    }

                    Circle()
                        .stroke(Color.white.opacity(isHighlighted ? 0.42 : 0.26), lineWidth: 0.7)
                        .frame(width: max(2, side - lineWidth), height: max(2, side - lineWidth))
                }
                .shadow(
                    color: activeColors[0].opacity(isHighlighted ? 0.50 : 0.34),
                    radius: isHighlighted ? 4.2 : 2.4,
                    x: 0,
                    y: 1.1
                )
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
            }
        }
        .allowsHitTesting(false)
    }
}

enum TextoraSuggestionColors {
    static let brandGradient = [
        Color(red: 1.0, green: 0.27, blue: 0.45),
        Color(red: 0.56, green: 0.36, blue: 1.0),
        Color(red: 0.16, green: 0.72, blue: 1.0)
    ]

    static func color(for operation: RewriteOperation) -> Color {
        switch operation {
        case .fixGrammar:
            return Color(red: 0.24, green: 0.60, blue: 1.0)
        case .makeProfessional:
            return Color(red: 0.70, green: 0.42, blue: 1.0)
        case .humanize:
            return Color(red: 0.13, green: 0.78, blue: 0.72)
        case .shorten:
            return Color(red: 1.0, green: 0.57, blue: 0.18)
        }
    }

    static func gradient(for operation: RewriteOperation) -> [Color] {
        switch operation {
        case .fixGrammar:
            return [Color(red: 0.10, green: 0.55, blue: 1.0), Color(red: 0.24, green: 0.86, blue: 1.0)]
        case .makeProfessional:
            return [Color(red: 0.52, green: 0.34, blue: 1.0), Color(red: 0.94, green: 0.36, blue: 1.0)]
        case .humanize:
            return [Color(red: 0.06, green: 0.70, blue: 0.62), Color(red: 0.35, green: 0.90, blue: 0.64)]
        case .shorten:
            return [Color(red: 1.0, green: 0.46, blue: 0.16), Color(red: 1.0, green: 0.76, blue: 0.22)]
        }
    }
}

struct FloatingMarkerView: View {
    let onOpen: () -> Void
    let onHoverChanged: (Bool) -> Void
    var onHoverMoved: () -> Void = {}

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                onOpen()
            }
            .onHover { isHovering in
                onHoverChanged(isHovering)
            }
            .onContinuousHover { phase in
                if case .active = phase {
                    onHoverMoved()
                }
            }
            .help("Suggestion available")
    }
}

struct HoverSuggestionCardView: View {
    let originalText: String
    let suggestions: [OverlaySuggestion]
    let anchorSource: String
    let onApply: (OverlaySuggestion) -> Void
    let onHoverChanged: (Bool) -> Void
    let showsDiffPreview: Bool
    /// Optional dismiss action. Non-nil when the card is bound to a
    /// specific `OverlayIssue` — gives the user a "not here, not now"
    /// escape hatch so one unwanted suggestion never blocks the rest
    /// of the overlays on the same sentence.
    var onSkip: ((OverlaySuggestion) -> Void)? = nil

    @AppStorage(AppViewModel.SettingsKeys.smartAIEnabled) private var smartAIEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color(red: 0.57, green: 0.45, blue: 1.0),
                                Color(red: 0.90, green: 0.33, blue: 1.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text("Suggestion")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                Spacer()
                SmartAIToggleButton(isOn: $smartAIEnabled)
            }
            let visibleSuggestions = Array(displaySuggestions.prefix(12))
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visibleSuggestions.enumerated()), id: \.offset) { index, suggestion in
                        SuggestionSectionView(
                            original: originalText,
                            suggestion: suggestion,
                            color: labelColor(for: suggestion.operation),
                            isDimmed: smartAIEnabled && !suggestion.isRecommended && !suggestion.isOptional,
                            isSecondary: suggestion.isOptional,
                            onApply: { onApply(suggestion) },
                            onSkip: onSkip.map { skip in { skip(suggestion) } },
                            showsDiffPreview: showsDiffPreview
                        )
                        if index != visibleSuggestions.indices.last {
                            Divider().overlay(Color.white.opacity(0.08))
                        }
                    }
                }
            }
            .frame(maxHeight: suggestionListHeight(count: visibleSuggestions.count))
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(width: 440, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(red: 0.07, green: 0.08, blue: 0.13))
            }
            .shadow(color: Color.black.opacity(0.24), radius: 18, x: 0, y: 10)
            .shadow(color: Color(red: 0.35, green: 0.22, blue: 0.85).opacity(0.18), radius: 18, x: 0, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.18),
                            Color(red: 0.42, green: 0.61, blue: 1.0).opacity(0.22),
                            Color.white.opacity(0.06)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .onHover { isHovering in
            onHoverChanged(isHovering)
        }
    }

    private func labelColor(for operation: RewriteOperation) -> Color {
        TextoraSuggestionColors.color(for: operation)
    }

    private func suggestionListHeight(count: Int) -> CGFloat {
        min(CGFloat(max(1, count)) * 124, 452)
    }

    private var displaySuggestions: [OverlaySuggestion] {
        let cleaned = suggestions.map { suggestion in
            OverlaySuggestion(operation: suggestion.operation, text: suggestion.text)
        }
        guard smartAIEnabled else { return cleaned }
        let preferred = smartPreferredOperation(in: Set(cleaned.map(\.operation)))
        let fallbackOrder: [RewriteOperation] = [.fixGrammar, .makeProfessional, .shorten, .humanize]
        var orderedOps: [RewriteOperation] = []
        if let preferred {
            orderedOps.append(preferred)
        }
        for op in fallbackOrder where !orderedOps.contains(op) {
            orderedOps.append(op)
        }
        var byOperation: [RewriteOperation: OverlaySuggestion] = [:]
        for suggestion in cleaned where byOperation[suggestion.operation] == nil {
            byOperation[suggestion.operation] = suggestion
        }
        return orderedOps.compactMap { byOperation[$0] }.enumerated().map { index, suggestion in
            var copy = suggestion
            copy.isRecommended = index == 0
            copy.isOptional = secondarySmartOperations(primary: preferred).contains(suggestion.operation)
            return copy
        }
    }

    private func smartPreferredOperation(in available: Set<RewriteOperation>) -> RewriteOperation? {
        guard !available.isEmpty else { return nil }
        let cleaned = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let hasTextIssues = hasLocalSpellingIssues(cleaned) || containsMixedLatinCyrillicWord(cleaned)
        guard hasTextIssues else { return nil }
        let desired: RewriteOperation = .fixGrammar
        return available.contains(desired) ? desired : available.first
    }

    private func secondarySmartOperations(primary: RewriteOperation?) -> Set<RewriteOperation> {
        guard smartAIEnabled, primary != nil else { return [] }
        let cleaned = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard primary != .fixGrammar,
              hasLocalSpellingIssues(cleaned) || containsMixedLatinCyrillicWord(cleaned) else {
            return []
        }
        return [.fixGrammar]
    }

    private func hasLocalSpellingIssues(_ text: String) -> Bool {
        let nsText = text as NSString
        guard nsText.length >= 3 else { return false }
        let misspelled = NSSpellChecker.shared.checkSpelling(
            of: text,
            startingAt: 0,
            language: nil,
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        return misspelled.location != NSNotFound
    }

    private func containsMixedLatinCyrillicWord(_ text: String) -> Bool {
        let pattern = #"\b(?=[\p{L}\p{M}]*\p{Latin})(?=[\p{L}\p{M}]*\p{Cyrillic})[\p{L}\p{M}]{3,}\b"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private func looksFormal(_ text: String) -> Bool {
        let lower = text.lowercased()
        let cues = [
            "dear ", "kindly", "regards", "sincerely", "appreciate", "would like",
            "please find", "i am writing", "could you please", "thank you for",
            "following up", "as discussed", "regarding", "replacement logic",
            "уважа", "пожалуйста", "благодар", "с уважением", "прошу", "не могли бы"
        ]
        return cues.contains { lower.contains($0) }
    }

    private func looksOverloaded(_ text: String) -> Bool {
        let words = text.split { !$0.isLetter && !$0.isNumber }
        guard words.count >= 24 else { return false }
        let punctuationLoad = text.filter { ",;:()".contains($0) }.count
        let fillerCues = [
            "actually", "basically", "really", "very", "just", "probably",
            "как бы", "в целом", "просто", "очень"
        ]
        let lower = text.lowercased()
        let fillerCount = fillerCues.reduce(0) { partial, cue in
            partial + (lower.contains(cue) ? 1 : 0)
        }
        return words.count >= 34 || punctuationLoad >= 5 || fillerCount >= 2
    }

    private func looksPlain(_ text: String) -> Bool {
        let words = text.split { !$0.isLetter && !$0.isNumber }
        guard words.count >= 3, words.count <= 28 else { return false }
        return !looksFormal(text) && !looksOverloaded(text)
    }
}

private struct SmartAIToggleButton: View {
    @Binding var isOn: Bool
    @State private var isHovered = false

    var body: some View {
        Button {
            withAnimation(.interpolatingSpring(stiffness: 320, damping: 18)) {
                isOn.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "sparkles" : "sparkle")
                    .font(.system(size: 11, weight: .bold))
                Text("Smart AI")
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(isOn ? .white : Color.white.opacity(0.56))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(
                        isOn
                        ? LinearGradient(
                            colors: [
                                Color(red: 0.12, green: 0.60, blue: 1.0),
                                Color(red: 0.62, green: 0.30, blue: 1.0),
                                Color(red: 1.0, green: 0.32, blue: 0.72)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        : LinearGradient(
                            colors: [
                                Color.white.opacity(isHovered ? 0.12 : 0.07),
                                Color.white.opacity(isHovered ? 0.12 : 0.07)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            )
            .overlay(
                Capsule()
                    .stroke(isOn ? Color.white.opacity(0.42) : Color.white.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: Color(red: 0.35, green: 0.70, blue: 1.0).opacity(isOn ? (isHovered ? 0.48 : 0.32) : 0), radius: isHovered ? 13 : 9, x: 0, y: 0)
            .scaleEffect(isHovered ? 1.03 : 1.0)
        }
        .buttonStyle(.plain)
        .help(isOn ? "Smart AI recommendations enabled" : "Use last selected mode first")
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
    }
}

private struct SuggestionSectionView: View {
    let original: String
    let suggestion: OverlaySuggestion
    let color: Color
    var isDimmed: Bool = false
    var isSecondary: Bool = false
    let onApply: () -> Void
    /// Optional dismiss action. When provided the section shows a
    /// small "Skip" pill next to the category label; tapping it
    /// invokes `onSkip` instead of `onApply` and swallows the row's
    /// tap gesture so the user does not accidentally apply the
    /// suggestion they meant to skip.
    var onSkip: (() -> Void)? = nil
    var showsDiffPreview: Bool = true

    @State private var isHovered = false
    @State private var isSkipHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(suggestion.operation.rawValue)
                    .font(.system(size: 13.5, weight: suggestion.isRecommended || isSecondary ? .bold : .semibold))
                .foregroundStyle(labelForeground)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(labelFill)
                )
                .overlay(alignment: .topTrailing) {
                    if suggestion.isRecommended {
                        SmartAIRecommendedBadge()
                            .offset(x: 8, y: -8)
                    }
                }
                .zIndex(suggestion.isRecommended ? 1 : 0)
                Spacer(minLength: 0)
                if let onSkip {
                    Button(action: onSkip) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                            Text("Skip")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(.white.opacity(isSkipHovered ? 0.92 : 0.62))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(isSkipHovered ? 0.12 : 0.06))
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        withAnimation(.easeOut(duration: 0.12)) {
                            isSkipHovered = hovering
                        }
                    }
                    .help("Dismiss this suggestion for the current sentence")
                }
            }
            if showsDiffPreview {
                DiffPreviewView(
                    original: original,
                    suggestion: suggestion.text
                )
                .opacity(isDimmed ? 0.58 : 1.0)
            } else {
                Text(displaySuggestion(suggestion.text))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(isDimmed ? 0.56 : 0.88))
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(isHovered ? (isDimmed ? 0.045 : 0.075) : 0.001))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(isHovered ? 0.10 : 0), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            onApply()
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private func displaySuggestion(_ text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? " " : cleaned
    }

    private var labelForeground: Color {
        if isDimmed { return Color.white.opacity(0.46) }
        if isSecondary { return color.opacity(0.96) }
        return color
    }

    private var labelFill: Color {
        if isDimmed { return Color.white.opacity(isHovered ? 0.12 : 0.07) }
        return color.opacity(isHovered ? 0.20 : (isSecondary ? 0.12 : 0.15))
    }
}

private struct DiffPreviewView: View {
    let original: String
    let suggestion: String

    var body: some View {
        let snippets = contextualDiffSnippets(original: original, suggestion: suggestion)
        VStack(alignment: .leading, spacing: 8) {
            diffLine(
                title: "Before",
                text: displayText(snippets.before),
                textColor: Color(red: 1.0, green: 0.52, blue: 0.58),
                fillColor: Color(red: 0.46, green: 0.09, blue: 0.18).opacity(0.34)
            )
            diffLine(
                title: "After",
                text: displayText(snippets.after),
                textColor: Color(red: 0.60, green: 0.91, blue: 0.70),
                fillColor: Color(red: 0.07, green: 0.30, blue: 0.18).opacity(0.34)
            )
        }
    }

    private func diffLine(title: String, text: String, textColor: Color, fillColor: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            rowTitle(title)
            ExpandableDiffText(
                text: text,
                textColor: textColor,
                fillColor: fillColor
            )
        }
    }

    private func rowTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.46))
            .frame(width: 48, alignment: .leading)
            .padding(.top, 8)
    }

    private func displayText(_ text: String) -> String {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return cleaned.isEmpty ? " " : cleaned
    }

    private func contextualDiffSnippets(original: String, suggestion: String) -> (before: String, after: String) {
        let lhs = original as NSString
        let rhs = suggestion as NSString
        guard lhs.length > 0, rhs.length > 0 else {
            return (original, suggestion)
        }

        let limit = min(lhs.length, rhs.length)
        var prefix = 0
        while prefix < limit, lhs.character(at: prefix) == rhs.character(at: prefix) {
            prefix += 1
        }
        if prefix == lhs.length, prefix == rhs.length {
            return (original, suggestion)
        }

        var suffix = 0
        while suffix < lhs.length - prefix,
              suffix < rhs.length - prefix,
              lhs.character(at: lhs.length - 1 - suffix) == rhs.character(at: rhs.length - 1 - suffix) {
            suffix += 1
        }

        let lhsRange = expandedSnippetRange(in: lhs, rawStart: prefix, rawEnd: lhs.length - suffix)
        let rhsRange = expandedSnippetRange(in: rhs, rawStart: prefix, rawEnd: rhs.length - suffix)
        return (
            lhs.substring(with: lhsRange),
            rhs.substring(with: rhsRange)
        )
    }

    private func expandedSnippetRange(in text: NSString, rawStart: Int, rawEnd: Int) -> NSRange {
        guard text.length > 0 else { return NSRange(location: 0, length: 0) }
        var start = max(0, min(rawStart, text.length))
        var end = max(start, min(rawEnd, text.length))
        let changedContainsWord = containsWordLike(in: text, start: start, end: end)

        while start > 0, isWordLike(text.character(at: start - 1)) {
            start -= 1
        }
        while end < text.length, isWordLike(text.character(at: end)) {
            end += 1
        }

        if !changedContainsWord {
            while start > 0, isAttachedPunctuation(text.character(at: start - 1)) {
                start -= 1
            }
            while start > 0, isWordLike(text.character(at: start - 1)) {
                start -= 1
            }
        }

        while end < text.length, isAttachedPunctuation(text.character(at: end)) {
            end += 1
        }
        while start < end, isWhitespace(text.character(at: start)) {
            start += 1
        }
        while end > start, isWhitespace(text.character(at: end - 1)) {
            end -= 1
        }

        if start == end {
            if start > 0 {
                start -= 1
                while start > 0, isWordLike(text.character(at: start - 1)) {
                    start -= 1
                }
            } else if end < text.length {
                end += 1
                while end < text.length, isWordLike(text.character(at: end)) {
                    end += 1
                }
            }
        }

        return NSRange(location: start, length: max(0, end - start))
    }

    private func containsWordLike(in text: NSString, start: Int, end: Int) -> Bool {
        guard start < end else { return false }
        for index in start..<end where isWordLike(text.character(at: index)) {
            return true
        }
        return false
    }

    private func isWordLike(_ codeUnit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(UInt32(codeUnit)) else { return false }
        return CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
    }

    private func isWhitespace(_ codeUnit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(UInt32(codeUnit)) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private func isAttachedPunctuation(_ codeUnit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(UInt32(codeUnit)) else { return false }
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return false }
        if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) { return false }
        return true
    }
}

private struct ExpandableDiffText: View {
    let text: String
    let textColor: Color
    let fillColor: Color

    @State private var isHovered = false

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(textColor)
            .lineLimit(isHovered ? 8 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.white.opacity(isHovered ? 0.08 : 0), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.16)) {
                    isHovered = hovering
                }
            }
    }
}
