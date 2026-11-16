import AppKit
import Combine
import SwiftUI

struct SummaryOptions: Equatable {
    enum Detail: String, CaseIterable {
        case brief, detailed
        var title: String { self == .brief ? "Brief" : "Detailed" }
    }
    var detail: Detail = .brief
    var language: TranslationLanguage?

    static func load(_ defaults: UserDefaults) -> Self {
        Self(detail: Detail(rawValue: defaults.string(forKey: "summary.detail") ?? "") ?? .brief,
             language: defaults.string(forKey: "summary.language").flatMap(TranslationLanguage.init(rawValue:)))
    }

    func save(_ defaults: UserDefaults) {
        defaults.set(detail.rawValue, forKey: "summary.detail")
        defaults.set(language?.rawValue ?? "original", forKey: "summary.language")
    }
}

struct TextSummary: Codable, Equatable {
    struct Section: Codable, Equatable {
        let title: String
        let items: [String]
    }
    let overview: String
    let sections: [Section]

    var plainText: String {
        ([overview] + sections.map { section in
            section.title + "\n" + section.items.map { "• " + $0 }.joined(separator: "\n")
        }).joined(separator: "\n\n")
    }
}

@MainActor
final class SummaryViewModel: ObservableObject {
    @Published private(set) var source = ""
    @Published private(set) var application: String?
    @Published private(set) var result: TextSummary?
    @Published private(set) var busy = false
    @Published private(set) var error = ""
    @Published private(set) var notice = ""
    @Published var options: SummaryOptions {
        didSet {
            guard oldValue != options else { return }
            options.save(defaults)
            if !source.isEmpty { generate() }
        }
    }

    private let defaults: UserDefaults
    private let history: RecentResults
    private let pasteboard: NSPasteboard
    private let summarize: @MainActor (String, SummaryOptions) async throws -> TextSummary
    private var task: Task<Void, Never>?
    private var generation = 0
    private var sessionID = UUID()
    private var historyToken: Int?

    init(defaults: UserDefaults = .standard, history: RecentResults? = nil,
         pasteboard: NSPasteboard = .general,
         summarize: @escaping @MainActor (String, SummaryOptions) async throws -> TextSummary = {
             try await AIClient().summarize(text: $0, options: $1)
         }) {
        self.defaults = defaults
        self.history = history ?? .shared
        self.pasteboard = pasteboard
        self.summarize = summarize
        options = SummaryOptions.load(defaults)
    }

    func start(source: String, application: String?) {
        cancel()
        self.source = source
        self.application = application
        sessionID = UUID()
        historyToken = history.consentToken
        result = nil
        notice = ""
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "Select the text you want to summarize, then press the Summary shortcut."
            return
        }
        generate()
    }

    func generate() {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        cancel()
        let id = generation
        let text = source
        let requestedOptions = options
        result = nil
        error = ""
        notice = ""
        busy = true
        task = Task { [weak self, summarize] in
            do {
                let summary = try await summarize(text, requestedOptions)
                guard let self, self.generation == id, !Task.isCancelled else { return }
                self.result = summary
                self.busy = false
                self.remember(status: "Ready")
            } catch is CancellationError {
                guard let self, self.generation == id else { return }
                self.busy = false
            } catch {
                guard let self, self.generation == id, !Task.isCancelled else { return }
                self.busy = false
                self.error = error.localizedDescription
            }
        }
    }

    func copy() {
        guard let result, !busy else { return }
        pasteboard.clearContents()
        if pasteboard.setString(result.plainText, forType: .string) {
            notice = "Copied"
            remember(status: "Copied")
        } else { notice = "Could not copy. Select the summary text and copy it manually." }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        busy = false
    }

    private func remember(status: String) {
        guard let result else { return }
        history.record(OperationResult(id: sessionID, kind: .summary, source: source, result: result.plainText,
            application: application, language: options.language?.displayName, status: status), token: historyToken)
    }
}

private final class SummaryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SummaryWindowController: NSObject, NSWindowDelegate {
    let model = SummaryViewModel()
    private var window: NSWindow?

    func show(source: String, application: String?) {
        model.start(source: source, application: application)
        if window == nil {
            let window = SummaryPanel(contentRect: CGRect(x: 0, y: 0, width: 640, height: 590),
                styleMask: [.borderless, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Summary"
            window.isReleasedWhenClosed = false
            window.minSize = CGSize(width: 540, height: 450)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.hidesOnDeactivate = false
            window.isMovable = true
            window.isMovableByWindowBackground = false
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = NSHostingView(rootView: SummaryView(model: model, onClose: { [weak self] in self?.close() }))
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { model.cancel() }

    private func close() {
        model.cancel()
        window?.close()
    }
}

struct SummaryView: View {
    @ObservedObject var model: SummaryViewModel
    var onClose: () -> Void = {}
    @State private var showsSource = false
    @State private var showsLanguages = false

    var body: some View {
        VStack(spacing: 0) {
            header
            controls
            Text([model.application, "\(model.source.count.formatted()) selected characters"].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(TextoraPanelStyle.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.bottom, 12)
            divider
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    summaryContent
                    if !model.source.isEmpty { sourceCard }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            divider
            footer
        }
        .frame(minWidth: 500, minHeight: 400)
        .background(TextoraPanelStyle.background)
        .overlay {
            if showsLanguages {
                Color.clear.contentShape(Rectangle()).onTapGesture { showsLanguages = false }
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showsLanguages {
                languageDropdown.padding(.top, 112).padding(.trailing, 16)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(TextoraPanelStyle.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .environment(\.colorScheme, .dark)
        .onChange(of: model.source) { _, _ in
            showsSource = false
            showsLanguages = false
        }
    }

    private var header: some View {
        ZStack(alignment: .top) {
            SelectionWindowDragHandle()
            Capsule().fill(Color.white.opacity(0.20)).frame(width: 30, height: 3)
                .padding(.top, 5).allowsHitTesting(false)
            HStack(spacing: 10) {
                TextoraPanelLogo()
                Text("Summary").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                Spacer(minLength: 8)
                Button { FeatureWindows.shared.showHistory() } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .buttonStyle(SummaryIconButtonStyle())
                .help("Recent Results").accessibilityLabel("Recent Results")
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(SummaryIconButtonStyle())
                    .help("Close").accessibilityLabel("Close summary")
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).padding(.top, 10)
        }
        .frame(height: 64)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            HStack(spacing: 3) {
                ForEach(SummaryOptions.Detail.allCases, id: \.self) { detail in
                    Button { model.options.detail = detail } label: {
                        Text(detail.title)
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(Color.white.opacity(model.options.detail == detail ? 0.96 : 0.58))
                            .padding(.horizontal, 15).frame(height: 30)
                            .background(Capsule().fill(Color.white.opacity(model.options.detail == detail ? 0.13 : 0)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.options.detail == detail ? .isSelected : [])
                }
            }
            .padding(3)
            .background(TextoraPanelStyle.badgeBackground)
            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
            .accessibilityElement(children: .contain).accessibilityLabel("Summary length")

            Spacer(minLength: 0)
            Button { showsLanguages.toggle() } label: {
                HStack(spacing: 7) {
                    languageIcon(model.options.language)
                    Text(model.options.language?.displayName ?? "Original language")
                        .font(.system(size: 12.5, weight: .bold)).lineLimit(1)
                    Image(systemName: showsLanguages ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .heavy)).foregroundStyle(TextoraPanelStyle.secondaryText)
                }
                .foregroundStyle(.white.opacity(0.94))
                .padding(.horizontal, 12).frame(height: 34)
                .background(TextoraPanelStyle.badgeBackground)
                .overlay(Capsule().stroke(Color.white.opacity(0.20), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Summary language")
            .accessibilityValue(model.options.language?.displayName ?? "Original language")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var languageDropdown: some View {
        ScrollView {
            VStack(spacing: 3) {
                languageRow(nil)
                ForEach(TranslationLanguage.allCases) { language in languageRow(language) }
            }.padding(5)
        }
        .frame(width: 220).frame(maxHeight: 242)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(red: 0.10, green: 0.105, blue: 0.125).opacity(0.99)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.17), lineWidth: 1))
        .shadow(color: .black.opacity(0.48), radius: 16, x: 0, y: 8)
    }

    @ViewBuilder
    private func languageIcon(_ language: TranslationLanguage?) -> some View {
        if let language {
            Text(language.flag).font(.system(size: 15)).frame(width: 20)
        } else {
            Image(systemName: "globe").font(.system(size: 14)).frame(width: 20)
        }
    }

    private func languageRow(_ language: TranslationLanguage?) -> some View {
        let selected = model.options.language == language
        return Button {
            showsLanguages = false
            model.options.language = language
        } label: {
            HStack(spacing: 8) {
                languageIcon(language)
                Text(language?.displayName ?? "Original language")
                    .font(.system(size: 12.5, weight: selected ? .bold : .medium))
                Spacer(minLength: 4)
                Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).opacity(selected ? 1 : 0)
            }
            .foregroundStyle(Color.white.opacity(selected ? 1 : 0.76))
            .padding(.horizontal, 9).frame(height: 31)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(selected ? 0.11 : 0)))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    @ViewBuilder
    private var summaryContent: some View {
        if model.busy {
            card {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(.white.opacity(0.68))
                    Text("Summarizing…").font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.68))
                }.frame(maxWidth: .infinity, minHeight: 90)
            }
        } else if let result = model.result {
            card {
                VStack(alignment: .leading, spacing: 18) {
                    Text(result.overview).font(.system(size: TextoraPanelStyle.bodyFontSize, weight: .medium))
                    ForEach(result.sections.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(result.sections[index].title).font(.system(size: 11.5, weight: .heavy))
                                .foregroundStyle(TextoraPanelStyle.secondaryText)
                            ForEach(result.sections[index].items.indices, id: \.self) { item in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("•").foregroundStyle(TextoraPanelStyle.secondaryText)
                                    Text(result.sections[index].items[item]).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                }
                .font(.system(size: TextoraPanelStyle.bodyFontSize)).lineSpacing(3)
                .foregroundStyle(.white.opacity(0.94)).textSelection(.enabled)
            }
        } else if !model.error.isEmpty {
            card {
                Label(model.error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.45)).textSelection(.enabled)
            }
        } else {
            card {
                Text("Choose Regenerate to summarize this selection.")
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(TextoraPanelStyle.secondaryText)
            }
        }
    }

    private var sourceCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Button { showsSource.toggle() } label: {
                    HStack {
                        Text("Original text").font(.system(size: 11.5, weight: .heavy))
                        Spacer()
                        Image(systemName: showsSource ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .heavy))
                    }
                    .foregroundStyle(TextoraPanelStyle.secondaryText).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityValue(showsSource ? "Expanded" : "Collapsed")
                if showsSource {
                    Text(model.source).font(.system(size: TextoraPanelStyle.bodyFontSize))
                        .foregroundStyle(.white.opacity(0.66)).lineSpacing(3).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content().padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.22)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.notice == "Copied" {
                Label("Copied", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color(red: 40 / 255, green: 205 / 255, blue: 65 / 255))
            } else {
                Text(model.notice).foregroundStyle(TextoraPanelStyle.secondaryText)
            }
            Spacer(minLength: 4)
            if model.busy {
                Button("Cancel") { model.cancel() }.buttonStyle(SummaryActionButtonStyle())
            } else {
                Button { model.generate() } label: {
                    Label(model.error.isEmpty ? "Regenerate" : "Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SummaryActionButtonStyle())
                .disabled(model.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Button { model.copy() } label: { Label("Copy", systemImage: "doc.on.doc") }
                .buttonStyle(SummaryActionButtonStyle(prominent: true))
                .disabled(model.result == nil || model.busy)
                .keyboardShortcut("c", modifiers: [.command, .shift])
        }
        .font(.system(size: 11, weight: .medium)).lineLimit(2)
        .padding(14)
    }

    private var divider: some View { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
}

private struct SummaryIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .bold)).foregroundStyle(.white.opacity(0.68))
            .frame(width: 34, height: 34).background(Circle().fill(Color.white.opacity(configuration.isPressed ? 0.15 : 0.08)))
    }
}

private struct SummaryActionButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12.5, weight: .bold)).foregroundStyle(.white.opacity(isEnabled ? 0.94 : 0.42))
            .padding(.horizontal, 14).frame(height: 32)
            .background {
                if prominent && isEnabled { Capsule().fill(TextoraPanelStyle.accent) }
                else { TextoraPanelStyle.badgeBackground }
            }
            .overlay(Capsule().stroke(Color.white.opacity(0.13), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
