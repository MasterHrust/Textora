import SwiftUI

struct FloatingIssueUnderlineView: View {
    let colors: [Color]
    let isHighlighted: Bool

    init(colors: [Color] = TextoraSuggestionColors.brandGradient, isHighlighted: Bool = false) {
        self.colors = colors.isEmpty ? TextoraSuggestionColors.brandGradient : colors
        self.isHighlighted = isHighlighted
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
            return .blue
        case .makeProfessional:
            return .purple
        case .humanize:
            return .teal
        case .shorten:
            return .orange
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
    /// Optional dismiss action. Non-nil when the card is bound to a
    /// specific `OverlayIssue` — gives the user a "not here, not now"
    /// escape hatch so one unwanted suggestion never blocks the rest
    /// of the overlays on the same sentence.
    var onSkip: ((OverlaySuggestion) -> Void)? = nil

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
                Text(anchorSource)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(anchorSource == "caret" ? Color.green.opacity(0.92) : Color.orange.opacity(0.95))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill((anchorSource == "caret" ? Color.green : Color.orange).opacity(0.13))
                    )
            }
            let visibleSuggestions = Array(suggestions.prefix(4))
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleSuggestions) { suggestion in
                        SuggestionSectionView(
                            original: originalText,
                            suggestion: suggestion,
                            color: labelColor(for: suggestion.operation),
                            onApply: { onApply(suggestion) },
                            onSkip: onSkip.map { skip in { skip(suggestion) } }
                        )
                        if suggestion.id != visibleSuggestions.last?.id {
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
                    .fill(Color(red: 0.07, green: 0.08, blue: 0.13).opacity(0.98))
            }
            .shadow(color: Color.black.opacity(0.30), radius: 22, x: 0, y: 14)
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
        min(CGFloat(max(1, count)) * 112, 390)
    }
}

private struct SuggestionSectionView: View {
    let original: String
    let suggestion: OverlaySuggestion
    let color: Color
    let onApply: () -> Void
    /// Optional dismiss action. When provided the section shows a
    /// small "Skip" pill next to the category label; tapping it
    /// invokes `onSkip` instead of `onApply` and swallows the row's
    /// tap gesture so the user does not accidentally apply the
    /// suggestion they meant to skip.
    var onSkip: (() -> Void)? = nil

    @State private var isHovered = false
    @State private var isSkipHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(suggestion.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(color.opacity(isHovered ? 0.24 : 0.16))
                    )
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
            DiffPreviewView(
                original: original,
                suggestion: suggestion.text
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(isHovered ? 0.075 : 0.001))
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
                textColor: Color(red: 1.0, green: 0.31, blue: 0.43),
                fillColor: Color(red: 0.44, green: 0.05, blue: 0.17).opacity(0.42)
            )
            diffLine(
                title: "After",
                text: displayText(snippets.after),
                textColor: Color(red: 0.46, green: 0.92, blue: 0.64),
                fillColor: Color(red: 0.05, green: 0.28, blue: 0.18).opacity(0.42)
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
