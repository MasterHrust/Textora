import AppKit
import SwiftUI

struct SelectionToolbarView: View {
    @ObservedObject var viewModel: SelectionAssistantViewModel
    let onApply: () -> Void

    private let panelWidth: CGFloat = 660

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            topRow

            if viewModel.isLanguagePickerExpanded {
                compactLanguageDropdown
            } else if viewModel.hasTranslationContent {
                translationPanel
            } else if viewModel.hasRewritePreview {
                rewritePreviewPanel
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(width: panelWidth, height: panelHeight, alignment: .topLeading)
        .background(panelBackground)
        .overlay(panelStroke)
        .shadow(color: Color(red: 0.36, green: 0.67, blue: 1.0).opacity(0.10), radius: 22, x: 0, y: 0)
        .shadow(color: .black.opacity(0.42), radius: 22, x: 0, y: 14)
    }

    private var topRow: some View {
        HStack(spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color(red: 0.24, green: 0.73, blue: 1.0),
                                Color(red: 0.88, green: 0.21, blue: 0.92)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text("Ask")
                    .font(.system(size: 14.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.94))
            }
            .frame(width: 56, alignment: .leading)

            toolbarDivider

            HStack(spacing: 2) {
                ForEach(RewriteOperation.allCases) { operation in
                    operationButton(operation)
                }
            }

            Button(action: onApply) {
                HStack(spacing: 6) {
                    statusIcon
                    Text(actionTitle)
                        .font(.system(size: 12.5, weight: .heavy))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                .foregroundStyle(viewModel.canApply ? .white : Color.white.opacity(0.58))
                .padding(.horizontal, 10)
                .frame(width: 124, height: 31)
                .background(applyButtonBackground)
                .overlay(Capsule().stroke(Color.white.opacity(viewModel.canApply ? 0.30 : 0.10), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canApply)

            toolbarDivider

            translationLanguagePickerButton

            Button {
                viewModel.translate()
            } label: {
                HStack(spacing: 6) {
                    translateStatusIcon
                    Text("Translate")
                        .font(.system(size: 12.5, weight: .heavy))
                        .lineLimit(1)
                        .minimumScaleFactor(0.86)
                }
                .foregroundStyle(viewModel.canTranslate ? .white : Color.white.opacity(0.54))
                .padding(.horizontal, 10)
                .frame(width: 102, height: 31)
                .background(Capsule().fill(Color.white.opacity(viewModel.canTranslate ? 0.11 : 0.055)))
                .overlay(Capsule().stroke(Color.white.opacity(0.13), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canTranslate)
        }
    }

    private func operationButton(_ operation: RewriteOperation) -> some View {
        let selected = viewModel.operation == operation
        let color = operationColor(operation)
        return Button {
            viewModel.operation = operation
        } label: {
            Text(operation.rawValue)
                .font(.system(size: 11.5, weight: .heavy))
                .foregroundStyle(selected ? .white : color.opacity(0.92))
                .lineLimit(1)
                .padding(.horizontal, operation == .humanize ? 6 : 7)
                .frame(height: 29)
                .background(
                    Capsule()
                        .fill(selected ? color.opacity(0.78) : Color.clear)
                )
                .overlay(
                    Capsule()
                        .stroke(selected ? Color.white.opacity(0.18) : Color.clear, lineWidth: 1)
                )
                .shadow(color: selected ? color.opacity(0.22) : .clear, radius: 8, x: 0, y: 0)
        }
        .buttonStyle(.plain)
    }

    private var translationLanguagePickerButton: some View {
        Button {
            viewModel.isLanguagePickerExpanded.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(viewModel.translationLanguage.flag)
                    .font(.system(size: 17))
                Image(systemName: viewModel.isLanguagePickerExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.68))
            }
            .frame(width: 50, height: 31)
            .background(Capsule().fill(Color.white.opacity(viewModel.isLanguagePickerExpanded ? 0.16 : 0.09)))
            .overlay(Capsule().stroke(Color.white.opacity(viewModel.isLanguagePickerExpanded ? 0.22 : 0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var compactLanguageDropdown: some View {
        let columns = Array(repeating: GridItem(.fixed(36), spacing: 6), count: 8)
        return LazyVGrid(columns: columns, alignment: .trailing, spacing: 6) {
            ForEach(TranslationLanguage.allCases) { language in
                Button {
                    viewModel.translationLanguage = language
                } label: {
                    Text(language.flag)
                        .font(.system(size: 19))
                        .frame(width: 36, height: 31)
                        .background(
                            Capsule()
                                .fill(language == viewModel.translationLanguage ? Color.white.opacity(0.17) : Color.white.opacity(0.055))
                        )
                        .overlay(
                            Capsule()
                                .stroke(language == viewModel.translationLanguage ? Color(red: 0.25, green: 0.69, blue: 1.0).opacity(0.70) : Color.white.opacity(0.08), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help(language.displayName)
            }
        }
        .padding(6)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.24))
        )
        .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .trailing)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var translationPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(viewModel.translationLanguage.flag)
                Text("Translation")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.58))
                Spacer(minLength: 0)
            }

            Group {
                switch viewModel.translationStatus {
                case .idle:
                    EmptyView()
                case .translating:
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Translating")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                case .ready:
                    ScrollView {
                        Text(viewModel.translatedText)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.90))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .error(let message):
                    Text(message)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.45))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .frame(height: 98)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.24))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var rewritePreviewPanel: some View {
        HStack(spacing: 8) {
            rewritePreviewColumn(
                title: "Before",
                text: viewModel.originalText,
                tint: Color.white.opacity(0.58)
            )
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(Color.white.opacity(0.34))
                .frame(width: 16)
            rewritePreviewColumn(
                title: "After",
                text: viewModel.rewrittenText,
                tint: Color(red: 0.25, green: 0.72, blue: 1.0),
                highlightedText: highlightedAfterText()
            )
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .frame(height: 98)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.24))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func rewritePreviewColumn(title: String, text: String, tint: Color, highlightedText: AttributedString? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10.5, weight: .heavy))
                .foregroundStyle(tint)
            ScrollView {
                Text(highlightedText ?? AttributedString(text))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .frame(width: 1, height: 28)
            .padding(.horizontal, 2)
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.08, green: 0.09, blue: 0.11).opacity(0.98),
                        Color(red: 0.12, green: 0.12, blue: 0.14).opacity(0.98)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    private var panelStroke: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .stroke(Color.white.opacity(0.15), lineWidth: 1)
    }

    private var applyButtonBackground: some View {
        Capsule()
            .fill(
                viewModel.canApply
                ? LinearGradient(
                    colors: [
                        Color(red: 0.12, green: 0.70, blue: 1.0),
                        Color(red: 0.42, green: 0.36, blue: 1.0),
                        Color(red: 0.90, green: 0.20, blue: 0.86)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                : LinearGradient(
                    colors: [Color.white.opacity(0.08), Color.white.opacity(0.05)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
    }

    private func operationColor(_ operation: RewriteOperation) -> Color {
        switch operation {
        case .fixGrammar:
            return Color(red: 0.12, green: 0.70, blue: 1.0)
        case .shorten:
            return Color(red: 1.0, green: 0.49, blue: 0.12)
        case .makeProfessional:
            return Color(red: 0.65, green: 0.35, blue: 1.0)
        case .humanize:
            return Color(red: 0.18, green: 0.78, blue: 0.68)
        }
    }

    private func highlightedAfterText() -> AttributedString {
        let text = viewModel.rewrittenText
        let ns = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12.5),
                .foregroundColor: NSColor.white.withAlphaComponent(0.88)
            ]
        )
        let success = NSColor(red: 40 / 255, green: 205 / 255, blue: 65 / 255, alpha: 1)
        let ranges = PreviewDiff.changedRangesInCorrected(original: viewModel.originalText, corrected: text)
        for range in ranges where range.location >= 0 && range.location + range.length <= ns.length {
            ns.addAttributes(
                [
                    .font: NSFont.systemFont(ofSize: 12.5, weight: .bold),
                    .foregroundColor: success
                ],
                range: range
            )
        }
        return AttributedString(ns)
    }

    private var panelHeight: CGFloat {
        if viewModel.isLanguagePickerExpanded {
            return 132
        }
        if viewModel.hasTranslationContent {
            return 164
        }
        if viewModel.hasRewritePreview {
            return 164
        }
        return 50
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch viewModel.status {
        case .checking, .waiting:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 12, height: 12)
        case .ready:
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .heavy))
        case .noChanges:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .heavy))
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .heavy))
        case .applying:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 12, height: 12)
        case .idle:
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .heavy))
        }
    }

    @ViewBuilder
    private var translateStatusIcon: some View {
        switch viewModel.translationStatus {
        case .translating:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 12, height: 12)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .heavy))
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .heavy))
        case .idle:
            Image(systemName: "globe")
                .font(.system(size: 12, weight: .heavy))
        }
    }

    private var actionTitle: String {
        switch viewModel.status {
        case .checking, .waiting:
            return "Checking"
        case .ready, .idle:
            return "Let's Improve"
        case .noChanges:
            return "Ready"
        case .error:
            return "Retry"
        case .applying:
            return "Applying"
        }
    }
}

private enum PreviewDiff {
    struct Token {
        let text: String
        let range: NSRange
    }

    static func changedRangesInCorrected(original: String, corrected: String) -> [NSRange] {
        let origTokens = tokenize(original)
        let corrTokens = tokenize(corrected)
        let matched = lcsIndices(origTokens.map(\.text), corrTokens.map(\.text))
        let anchors = [(-1, -1)] + matched + [(origTokens.count, corrTokens.count)]
        let corrNS = corrected as NSString
        var ranges: [NSRange] = []

        for index in 0..<(anchors.count - 1) {
            let prev = anchors[index]
            let next = anchors[index + 1]
            let originalGapStart = prev.0 + 1
            let originalGapEnd = next.0
            let correctedGapStart = prev.1 + 1
            let correctedGapEnd = next.1
            if originalGapStart == originalGapEnd && correctedGapStart == correctedGapEnd {
                continue
            }

            let correctedFrom = prev.1 >= 0
                ? corrTokens[prev.1].range.location + corrTokens[prev.1].range.length
                : 0
            let correctedTo = next.1 < corrTokens.count
                ? corrTokens[next.1].range.location
                : corrNS.length
            if correctedTo > correctedFrom {
                ranges.append(NSRange(location: correctedFrom, length: correctedTo - correctedFrom))
            }
        }

        return merge(ranges)
    }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        let ns = text as NSString
        var index = 0
        while index < ns.length {
            while index < ns.length, !isTokenScalar(ns.character(at: index)) {
                index += 1
            }
            let start = index
            while index < ns.length, isTokenScalar(ns.character(at: index)) {
                index += 1
            }
            if index > start {
                let range = NSRange(location: start, length: index - start)
                tokens.append(Token(text: ns.substring(with: range).lowercased(), range: range))
            }
        }
        return tokens
    }

    private static func isTokenScalar(_ value: unichar) -> Bool {
        guard let scalar = UnicodeScalar(value) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || scalar == "'"
    }

    private static func lcsIndices(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var i = 0
        var j = 0
        var result: [(Int, Int)] = []
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                result.append((i, j))
                i += 1
                j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return result
    }

    private static func merge(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.sorted { $0.location < $1.location }
        var merged: [NSRange] = []
        for range in sorted {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }
            let lastEnd = last.location + last.length
            if range.location <= lastEnd {
                merged[merged.count - 1] = NSRange(
                    location: last.location,
                    length: max(lastEnd, range.location + range.length) - last.location
                )
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
