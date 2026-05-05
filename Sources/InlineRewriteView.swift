import AppKit
import SwiftUI

// MARK: - Design tokens (dark glass popup)

private enum TextoraPopupTheme {
    static let panelWidth: CGFloat = 360
    static let cornerRadius: CGFloat = 22
    static let cardCorner: CGFloat = 14
    static let padding: CGFloat = 18
    static let bg = Color(red: 26 / 255, green: 26 / 255, blue: 30 / 255)
    static let cardBg = Color(red: 22 / 255, green: 22 / 255, blue: 26 / 255)
    static let border = Color.white.opacity(0.12)
    static let muted = Color.white.opacity(0.55)
    static let accentStart = Color(red: 62 / 255, green: 123 / 255, blue: 1)
    static let accentEnd = Color(red: 151 / 255, green: 71 / 255, blue: 1)
    static let applyGreen = Color(red: 40 / 255, green: 205 / 255, blue: 65 / 255)
    static let secondaryBtn = Color(white: 0.38)
    /// Fixed height so loading → content doesn’t jump the layout.
    static let suggestionCardContentHeight: CGFloat = 168
}

// MARK: - Custom segmented operations

private struct OperationSegmentBar: View {
    @Binding var selection: RewriteOperation

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(RewriteOperation.allCases.enumerated()), id: \.element.id) { index, op in
                let selected = op == selection
                Button {
                    selection = op
                } label: {
                    Text(op.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .foregroundStyle(selected ? .white : TextoraPopupTheme.muted)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity)
                        .background(
                            Group {
                                if selected {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(
                                            LinearGradient(
                                                colors: [TextoraPopupTheme.accentStart, TextoraPopupTheme.accentEnd],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                }
                            }
                        )
                }
                .buttonStyle(.plain)

                if index < RewriteOperation.allCases.count - 1 {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 1, height: 18)
                }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(TextoraPopupTheme.border, lineWidth: 1)
        )
    }
}

// MARK: - Main view

struct InlineRewriteView: View {
    @ObservedObject var viewModel: InlineRewriteViewModel
    let onClose: () -> Void
    let onHoverChanged: (Bool) -> Void
    let onActionInvoked: () -> Void
    @AppStorage(AppViewModel.SettingsKeys.smartAIEnabled) private var smartAIEnabled = false

    private var showSuggestionCard: Bool {
        !viewModel.noChangesNeeded && !viewModel.rewrittenText.isEmpty
    }

    private var actionsEnabled: Bool {
        showSuggestionCard && !viewModel.isLoading
    }

    private var copyEnabled: Bool {
        let hasTranslation = !viewModel.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let translationReady = hasTranslation && !viewModel.isTranslating
        return actionsEnabled || translationReady
    }

    private var translateEnabled: Bool {
        !viewModel.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !viewModel.isTranslating
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerRow

            OperationSegmentBar(selection: $viewModel.operation)
                .onChange(of: viewModel.operation) { _, _ in
                    viewModel.triggerRewrite(.operationChanged)
                }
            if smartAIEnabled {
                recommendedRow
            }

            suggestionSection
            translationSection

            if !viewModel.errorText.isEmpty {
                Text(viewModel.errorText)
                    .font(.caption)
                    .foregroundStyle(Color.red.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if viewModel.needsMailManualCapture {
                Text("Mail: select text, capture starts automatically in ~1s")
                    .font(.caption2)
                    .foregroundStyle(TextoraPopupTheme.muted)
            }
            if !viewModel.applyErrorText.isEmpty {
                Text(viewModel.applyErrorText)
                    .font(.caption)
                    .foregroundStyle(Color.orange.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
            }

            footerButtons
        }
        .padding(TextoraPopupTheme.padding)
        .frame(width: TextoraPopupTheme.panelWidth)
        .background(popupBackground)
        .preferredColorScheme(.dark)
        .onHover { isHovering in
            onHoverChanged(isHovering)
        }
    }

    private var headerRow: some View {
        ZStack(alignment: .center) {
            PopupWindowDragHandle()
                .frame(height: 44)
                .opacity(0.001)

            HStack(alignment: .center, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Textora")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Writing assistant")
                        .font(.caption)
                        .foregroundStyle(TextoraPopupTheme.muted)
                }

                Spacer(minLength: 0)

                Button {
                    let previousOperation = viewModel.operation
                    smartAIEnabled.toggle()
                    viewModel.prepareOperationForMarkerWindow()
                    if previousOperation == viewModel.operation {
                        viewModel.triggerRewrite(.operationChanged)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: smartAIEnabled ? "sparkles" : "sparkle")
                            .font(.system(size: 10, weight: .bold))
                        Text("Smart AI")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(smartAIEnabled ? .white : TextoraPopupTheme.muted)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(smartAIEnabled ? Color.white.opacity(0.14) : Color.white.opacity(0.07))
                    )
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(smartAIEnabled ? 0.20 : 0.10), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help(smartAIEnabled ? "Smart AI recommendations enabled" : "Use last selected mode first")

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.75))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .zIndex(1)
        }
    }

    private var recommendedRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
            Text("\(viewModel.operation.rawValue) (Recommended)")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(TextoraPopupTheme.muted)
        .padding(.top, -8)
    }

    @ViewBuilder
    private var suggestionSection: some View {
        Text("Suggestion")
            .font(.caption.weight(.semibold))
            .foregroundStyle(TextoraPopupTheme.muted)

        ZStack {
            if viewModel.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.regular)
                        .tint(.white)
                    Text("Rewriting…")
                        .font(.caption)
                        .foregroundStyle(TextoraPopupTheme.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.noChangesNeeded {
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(TextoraPopupTheme.applyGreen.opacity(0.18))
                            .frame(width: 56, height: 56)
                        Image(systemName: "checkmark")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(TextoraPopupTheme.applyGreen)
                    }
                    Text("Looks good — no changes needed")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if showSuggestionCard {
                ScrollView {
                    DiffTextView(original: viewModel.originalText, rewritten: viewModel.rewrittenText)
                        .font(.system(size: 14))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Waiting for suggestion…")
                    .font(.subheadline)
                    .foregroundStyle(TextoraPopupTheme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(minHeight: TextoraPopupTheme.suggestionCardContentHeight, maxHeight: TextoraPopupTheme.suggestionCardContentHeight)
        .padding(14)
        .background(suggestionCardChrome)
    }

    @ViewBuilder
    private var translationSection: some View {
        if viewModel.isTranslating || !viewModel.translateErrorText.isEmpty || !viewModel.translatedText.isEmpty {
            Text("Translation")
                .font(.caption.weight(.semibold))
                .foregroundStyle(TextoraPopupTheme.muted)

            ZStack {
                if viewModel.isTranslating {
                    HStack(spacing: 10) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .tint(.white)
                        Text("Translating…")
                            .font(.caption)
                            .foregroundStyle(TextoraPopupTheme.muted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else if !viewModel.translateErrorText.isEmpty {
                    Text(viewModel.translateErrorText)
                        .font(.caption)
                        .foregroundStyle(Color.orange.opacity(0.95))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView {
                        Text(viewModel.translatedText)
                            .font(.system(size: 13))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(minHeight: 92, maxHeight: 140)
            .padding(14)
            .background(suggestionCardChrome)
        }
    }

    private var suggestionCardChrome: some View {
        RoundedRectangle(cornerRadius: TextoraPopupTheme.cardCorner, style: .continuous)
            .fill(TextoraPopupTheme.cardBg)
            .overlay(
                RoundedRectangle(cornerRadius: TextoraPopupTheme.cardCorner, style: .continuous)
                    .stroke(TextoraPopupTheme.border, lineWidth: 1)
            )
    }

    private var footerButtons: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    // Commit any pending combo-box selection/text edit before reading target language.
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    DispatchQueue.main.async {
                        viewModel.triggerTranslate()
                    }
                } label: {
                    Text("Translate")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 112)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(translateEnabled ? Color.white.opacity(0.12) : Color.white.opacity(0.06))
                        )
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(!translateEnabled)

                LanguageComboBox(
                    text: $viewModel.translateTargetLanguage,
                    items: InlineRewriteViewModel.translateLanguageSuggestions
                )
            }

            HStack(spacing: 10) {
                Button {
                    viewModel.scheduleApply {
                        onActionInvoked()
                        onClose()
                    }
                } label: {
                    Text("Apply")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(actionsEnabled ? TextoraPopupTheme.applyGreen : TextoraPopupTheme.applyGreen.opacity(0.35))
                        )
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(!actionsEnabled)

                Button {
                    onActionInvoked()
                    viewModel.copyResult()
                    onClose()
                } label: {
                    Text("Copy")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(TextoraPopupTheme.secondaryBtn.opacity(copyEnabled ? 1 : 0.45))
                        )
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(!copyEnabled)
            }
        }
        .frame(minWidth: TextoraPopupTheme.panelWidth - TextoraPopupTheme.padding * 2)
    }

    private var popupBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: TextoraPopupTheme.cornerRadius, style: .continuous)
                .fill(TextoraPopupTheme.bg.opacity(0.92))
            RoundedRectangle(cornerRadius: TextoraPopupTheme.cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(0.55)
            RoundedRectangle(cornerRadius: TextoraPopupTheme.cornerRadius, style: .continuous)
                .stroke(TextoraPopupTheme.border, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 28, x: 0, y: 14)
    }
}

private struct PopupWindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragHandleView {
        DragHandleView()
    }

    func updateNSView(_ nsView: DragHandleView, context: Context) {}

    final class DragHandleView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }
    }
}

private struct LanguageComboBox: NSViewRepresentable {
    @Binding var text: String
    let items: [String]

    func makeNSView(context: Context) -> NSComboBox {
        let box = ClickToOpenComboBox()
        box.isEditable = true
        box.completes = true
        box.usesDataSource = false
        box.addItems(withObjectValues: items)
        box.stringValue = text
        box.delegate = context.coordinator
        box.controlSize = .small
        box.isButtonBordered = true
        return box
    }

    func updateNSView(_ nsView: NSComboBox, context: Context) {
        // While user is typing, don't overwrite text or rebuild the items list —
        // it breaks free-form input and can close/flash the dropdown.
        let isEditing = (nsView.currentEditor() != nil)
        if !isEditing, nsView.stringValue != text {
            nsView.stringValue = text
        }
        if !isEditing, context.coordinator.lastItemsHash != items.hashValue {
            nsView.removeAllItems()
            nsView.addItems(withObjectValues: items)
            context.coordinator.lastItemsHash = items.hashValue
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSComboBoxDelegate, NSTextFieldDelegate {
        var text: Binding<String>
        var lastItemsHash: Int = 0

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            if let selected = box.objectValueOfSelectedItem as? String, !selected.isEmpty {
                text.wrappedValue = selected
                return
            }
            text.wrappedValue = box.stringValue
        }
    }
}

private final class ClickToOpenComboBox: NSComboBox {
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // Open the dropdown even when clicking the text field area.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.performClick(nil)
        }
    }
}

// MARK: - Diff visualization (red strikethrough = removed, green = added)

private struct DiffTextView: View {
    let original: String
    let rewritten: String

    private static let removedColor = Color.red.opacity(0.9)
    private static let addedColor = TextoraPopupTheme.applyGreen

    var body: some View {
        buildText(from: TextDiff.computeSegments(original: original, rewritten: rewritten))
    }

    private func buildText(from segments: [TextDiff.Segment]) -> Text {
        var result = Text("")
        for seg in segments {
            switch seg {
            case .unchanged(let s):
                result = result + Text(s).foregroundStyle(.white)
            case .removed(let s):
                result = result + Text(s).foregroundStyle(Self.removedColor).strikethrough(true, color: Self.removedColor)
            case .added(let s):
                result = result + Text(s).foregroundStyle(Self.addedColor)
            }
        }
        return result
    }
}

private enum TextDiff {
    enum Segment {
        case unchanged(String)
        case removed(String)
        case added(String)
    }

    static func computeSegments(original: String, rewritten: String) -> [Segment] {
        let o = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = rewritten.trimmingCharacters(in: .whitespacesAndNewlines)
        if o.isEmpty && r.isEmpty { return [] }
        if o.isEmpty { return [.added(r)] }
        if r.isEmpty { return [.removed(o)] }
        if o == r { return [.unchanged(r)] }
        let ow = wordSplit(o)
        let rw = wordSplit(r)
        return lcsDiff(old: ow, new: rw)
    }

    private static func wordSplit(_ s: String) -> [(String, Bool)] {
        var result: [(String, Bool)] = []
        var current = ""
        for char in s {
            if char.isWhitespace {
                if !current.isEmpty {
                    result.append((current, false))
                    current = ""
                }
                result.append((String(char), true))
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { result.append((current, false)) }
        return result
    }

    private static func lcsDiff(old: [(String, Bool)], new: [(String, Bool)]) -> [Segment] {
        let n = old.count, m = new.count
        if n == 0 { return new.map { .added($0.0) } }
        if m == 0 { return old.map { .removed($0.0) } }
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n {
            for j in 1...m {
                dp[i][j] = old[i - 1].0 == new[j - 1].0
                    ? dp[i - 1][j - 1] + 1
                    : max(dp[i - 1][j], dp[i][j - 1])
            }
        }
        var rev: [Segment] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && old[i - 1].0 == new[j - 1].0 {
                rev.append(.unchanged(old[i - 1].0))
                i -= 1; j -= 1
            } else if j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j]) {
                rev.append(.added(new[j - 1].0))
                j -= 1
            } else {
                rev.append(.removed(old[i - 1].0))
                i -= 1
            }
        }
        return rev.reversed()
    }
}
