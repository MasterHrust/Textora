import AppKit
import SwiftUI

@MainActor
final class MessagePreviewModel: ObservableObject {
    @Published var transcript = ""
    @Published var draft = ""
    @Published var questions: [String] = []
    @Published var clarification = ""
    @Published var style = "Off"
    @Published var language = "Original language"
    @Published var busy = false
    @Published var draftUsesAI = false
    @Published var aiWasRequested = false
    @Published var canInsert = true
    @Published var notice = ""
    private var generation = 0
    func invalidate() { generation += 1; busy = false }
    func prepare(transcript: String, useAI: Bool = true,
                 operation: () async throws -> MessageDraft) async -> MessageDraft? {
        generation += 1
        let id = generation
        if self.transcript != transcript {
            draft = ""; questions = []; clarification = ""
            draftUsesAI = false; aiWasRequested = false
        }
        self.transcript = transcript; notice = ""
        if !useAI {
            // Previewing dictation must not invoke the provider, even when a
            // personal style is selected. AI improvement is a separate action.
            draft = GeneratedTextStyle.shortDashes(transcript)
            questions = []; clarification = ""
            busy = false; draftUsesAI = false; aiWasRequested = false
            return MessageDraft(draft: draft, questions: [])
        }
        busy = true; aiWasRequested = true
        do {
            let response = try await operation()
            guard generation == id, !Task.isCancelled else { return nil }
            busy = false; draft = response.draft; questions = response.questions; draftUsesAI = true
            return response
        } catch {
            guard generation == id, !Task.isCancelled else { return nil }
            busy = false
            notice = error.localizedDescription + " Your transcript is available to copy or retry."
            return nil
        }
    }
    var onInsert: ((String) -> Void)?
    var onCopy: ((String) -> Void)?
    var onRegenerate: ((String) -> Void)?
    var onClose: (() -> Void)?
}

@MainActor
final class MessagePreviewController: NSObject, NSWindowDelegate {
    let model = MessagePreviewModel()
    private var window: NSWindow?
    func show(transcript: String, style: String?, language: String?) {
        model.transcript = transcript; model.style = style ?? "Off"; model.language = language ?? "Original language"
        if window == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 650, height: 540),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Message"; window.isReleasedWhenClosed = false; window.delegate = self
            window.contentView = NSHostingView(rootView: MessagePreviewView(model: model))
            window.minSize = CGSize(width: 600, height: 480); window.center(); self.window = window
        }
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
    func hide() { window?.orderOut(nil) }
    func windowWillClose(_ notification: Notification) { model.onClose?() }
}

struct MessagePreviewView: View {
    @ObservedObject var model: MessagePreviewModel
    private let providerAvailable: Bool?
    @State private var hasProvider = false
    @State private var tab = "draft"
    init(model: MessagePreviewModel, providerAvailable: Bool? = nil) {
        self.model = model; self.providerAvailable = providerAvailable
        self._hasProvider = State(initialValue: providerAvailable ?? false)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Message").font(.title.bold())
                Spacer()
                Button { FeatureWindows.shared.showHistory() } label: { Image(systemName: "clock.arrow.circlepath") }
                    .help("Recent Results").accessibilityLabel("Recent Results")
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Label(model.draftUsesAI ? "AI draft" : "Local draft", systemImage: model.draftUsesAI ? "sparkles" : "lock.shield")
                        .font(.callout.weight(.medium))
                    Text(model.language).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(styleDescription).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
            }
            Picker("Content", selection: $tab) {
                Text("Transcript").tag("transcript"); Text("Draft").tag("draft")
            }.pickerStyle(.segmented)
            if tab == "transcript" {
                ScrollView { Text(model.transcript).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                TextEditor(text: $model.draft).font(.body).disabled(model.busy || !model.questions.isEmpty)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
            }
            if !model.questions.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.questions, id: \.self) { Text($0).font(.callout.bold()) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 150)
                TextField("Clarify the intended meaning, in any language", text: $model.clarification)
            }
            if !hasProvider {
                HStack(spacing: 12) {
                    Text(model.draftUsesAI ? "Connect an AI provider to regenerate this draft." : "AI improvement is optional. You can edit and copy this local draft without a provider.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Set up AI…") {
                        SettingsNavigation.shared.writingTab = .provider
                        AppCoordinator.shared.showSettingsWindow(section: .writing)
                    }
                }
            }
            if !model.notice.isEmpty { Text(model.notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if !model.canInsert {
                Label("The original field is unavailable. Copy the draft, then paste it into your chosen field.", systemImage: "doc.on.clipboard")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if model.canInsert {
                    Button("Insert") { model.onInsert?(model.draft) }
                        .disabled(model.busy || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.questions.isEmpty)
                }
                Button(tab == "transcript" || model.draft.isEmpty ? "Copy transcript" : "Copy draft") {
                    model.onCopy?(tab == "transcript" || model.draft.isEmpty ? model.transcript : model.draft)
                }
                if model.busy { ProgressView().controlSize(.small) }
                Button(aiActionTitle) {
                    let clarification = model.clarification; model.clarification = ""; model.onRegenerate?(clarification)
                }.disabled(!hasProvider || model.busy || !model.questions.isEmpty && model.clarification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
                Button("Close") { model.onClose?() }
            }
            Text(privacyDescription)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(22).frame(minWidth: 560, minHeight: 440)
        .onAppear(perform: refreshProviderAvailability)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refreshProviderAvailability()
        }
    }
    private var styleDescription: String {
        if model.draftUsesAI { return model.style == "Off" ? "AI style: Off" : "Style: \(model.style)" }
        return model.style == "Off" ? "AI improvement is optional" : "AI style: \(model.style) (optional)"
    }
    private var aiActionTitle: String {
        if model.busy { return "Preparing with AI…" }
        if !model.questions.isEmpty { return "Clarify and retry with AI" }
        return model.draftUsesAI ? "Regenerate with AI" : "Improve with AI"
    }
    private var privacyDescription: String {
        if model.busy { return "Your AI provider is preparing a draft from the transcript. Audio stays on this Mac." }
        if model.draftUsesAI { return "This draft used your AI provider. Audio stayed on this Mac. Review before inserting." }
        if model.aiWasRequested { return "The local draft is still available after your AI improvement request. Audio stays on this Mac." }
        return "This draft stays on this Mac. Improve with AI sends the transcript and optional writing style to your AI provider. Audio is never uploaded."
    }
    private func refreshProviderAvailability() {
        hasProvider = providerAvailable ?? (SelectionAssistantViewModel.providerConfiguration() != nil)
    }
}

struct DictationOutputSettingsView: View {
    @ObservedObject private var styleStore: PersonalStyleStore
    init(styleStore: PersonalStyleStore? = nil) { self.styleStore = styleStore ?? .shared }
    @AppStorage("dictation.outputMode") private var mode = DictationOutputMode.text.rawValue
    @AppStorage("dictation.translation.enabled") private var translationEnabled = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Result", selection: $mode) {
                Text("Text").tag(DictationOutputMode.text.rawValue)
                Text("Message").tag(DictationOutputMode.message.rawValue)
            }.pickerStyle(.segmented)
            Text(mode == "message"
                 ? (translationEnabled
                    ? "Prepare a translated draft with your AI provider. Always review it before insertion; audio stays on this Mac."
                    : "Open an editable local transcript before insertion. Edit it offline, or choose Improve with AI when you want help writing.")
                 : "Insert the transcript using offline recognition. Optional translation uses your AI provider.")
                .font(.caption).foregroundStyle(.secondary)
            if mode == "message" {
                Text(translationEnabled
                     ? "Speak in your language, then review the translated AI draft."
                     : "Example local transcript: Hi Rob, I’m running late and will finish tomorrow morning.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if (mode == "message" || translationEnabled), SelectionAssistantViewModel.providerConfiguration() == nil {
                Button(translationEnabled ? "Set up AI for translation…" : "Set up optional AI improvement…") {
                    SettingsNavigation.shared.writingTab = .provider
                    AppCoordinator.shared.showSettingsWindow(section: .writing)
                }
            }
            Text("AI writing style").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            StyleQuickControls(store: styleStore, bundleID: nil)
            Text("Style applies to translation or explicit AI improvement. Local transcripts keep your wording.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Only meter/clock views observe these high-frequency values. Recording controls
/// retain their identity while audio levels and elapsed time change.
@MainActor
final class RecordingMeterModel: ObservableObject {
    @Published var level: Float = 0
    @Published var elapsed: TimeInterval = 0
}

@MainActor
final class RecordingControlsModel: ObservableObject {
    @Published var isExpanded: Bool {
        didSet { if oldValue != isExpanded { onExpandedChanged?(isExpanded) } }
    }
    var onExpandedChanged: ((Bool) -> Void)?
    init(isExpanded: Bool = false) { self.isExpanded = isExpanded }
}

enum RecordingCapsuleLayout {
    static let width: CGFloat = 480
    static let compactHeight: CGFloat = 104
    static let expandedHeight: CGFloat = 290
    static func size(expanded: Bool) -> CGSize {
        CGSize(width: width, height: expanded ? expandedHeight : compactHeight)
    }
}

/// Kept under its existing name for callers, but deliberately contains no Menu:
/// choosing Text or Message is a direct segmented action, never a nested submenu.
struct RecordingOutputMenu: View {
    @AppStorage("dictation.outputMode") private var mode = DictationOutputMode.text.rawValue
    var body: some View {
        Picker("Result", selection: $mode) {
            Text("Text").tag(DictationOutputMode.text.rawValue)
            Text("Message").tag(DictationOutputMode.message.rawValue)
        }
        .pickerStyle(.segmented).labelsHidden()
        .frame(width: 184)
        .help("Text inserts your transcript. Message opens a local editable draft. AI is used for translation or when you choose Improve with AI.")
        .accessibilityLabel("Dictation result")
    }
}

struct RecordingCapsuleView: View {
    let meter: RecordingMeterModel
    @ObservedObject var options: RecordingControlsModel
    let onStop: () -> Void
    var showsDragHandle = false
    var isCopyOnly = false
    var isPreparing = false
    @AppStorage("dictation.translation.enabled") private var translationEnabled = false
    @AppStorage("dictation.translation.source") private var source = "auto"
    @AppStorage("dictation.translation.target") private var target = "english"
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    RecordingSignalView(meter: meter, isRecording: !isPreparing).frame(width: 58, height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isPreparing ? "Preparing" : "Listening").font(.system(size: 13, weight: .semibold))
                        Text(processingSummary)
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    RecordingClockView(meter: meter)
                    Button(action: onStop) {
                        Label(isPreparing ? "Cancel" : "Stop", systemImage: isPreparing ? "xmark" : "stop.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 10).frame(height: 30)
                            .foregroundStyle(.red)
                            .background(Color.red.opacity(0.14), in: Capsule())
                    }.buttonStyle(.plain)
                        .help(isPreparing ? "Cancel dictation preparation" : "Stop recording and process the transcript")
                        .accessibilityLabel(isPreparing ? "Cancel dictation preparation" : "Stop recording")
                    if showsDragHandle { dragHandle }
                }
                HStack(spacing: 10) {
                    Text("Result").font(.system(size: 11)).foregroundStyle(.secondary)
                    RecordingOutputMenu()
                    Spacer(minLength: 0)
                    Button { options.isExpanded.toggle() } label: {
                        HStack(spacing: 5) {
                            Text(translationSummary).lineLimit(1)
                            Image(systemName: options.isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                        }.font(.system(size: 11))
                            .padding(.horizontal, 8).frame(height: 25)
                            .background(Color.primary.opacity(0.055), in: Capsule())
                    }.buttonStyle(.plain)
                        .help("Translation languages and recording options")
                        .accessibilityLabel("Translation and recording options")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: RecordingCapsuleLayout.compactHeight)
            if options.isExpanded {
                Divider().padding(.horizontal, 16)
                RecordingLanguageOptionsView()
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(width: RecordingCapsuleLayout.width,
               height: options.isExpanded ? RecordingCapsuleLayout.expandedHeight : RecordingCapsuleLayout.compactHeight)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color(nsColor: .windowBackgroundColor).opacity(colorScheme == .dark ? 0.97 : 0.99)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .transaction { $0.animation = nil }
    }
    private var translationSummary: String {
        guard translationEnabled else { return "Translate: Off" }
        let to = TranslationLanguage(rawValue: target) ?? .english
        let from = TranslationLanguage(rawValue: source)?.flag ?? "Auto"
        return "\(from) → \(to.flag)"
    }
    private var processingSummary: String {
        if isPreparing { return isCopyOnly ? "Preparing locally - copy only" : "Preparing on this Mac" }
        if translationEnabled { return isCopyOnly ? "AI translation - copy only" : "AI translation after recording" }
        return isCopyOnly ? "Local transcript - copy only" : "Local transcript"
    }
    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary).frame(width: 24, height: 30)
            .background(Color.primary.opacity(0.055), in: Capsule())
            .help("Drag microphone").accessibilityLabel("Drag microphone")
    }
}

struct RecordingLanguageOptionsView: View {
    @AppStorage("dictation.translation.enabled") private var enabled = false
    @AppStorage("dictation.translation.source") private var source = "auto"
    @AppStorage("dictation.translation.target") private var target = "english"
    @AppStorage("dictation.translation.configured") private var configured = false
    @AppStorage("dictation.outputMode") private var mode = DictationOutputMode.text.rawValue
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Translate after recording", isOn: $enabled).toggleStyle(.switch).controlSize(.small)
                Spacer()
                Button {
                    let previous = source; source = target; target = previous; configured = true
                } label: { Image(systemName: "arrow.left.arrow.right") }
                    .buttonStyle(.borderless).disabled(!enabled || source == "auto")
                    .help(source == "auto" ? "Choose an explicit source language before swapping" : "Swap translation languages")
                    .accessibilityLabel("Swap translation languages")
            }
            languageRow("Translate from", selection: $source, allowsAutomatic: true).disabled(!enabled)
            languageRow("To", selection: $target).disabled(!enabled)
            Text(enabled
                 ? "Recognition is automatic and local. Translation sends the transcript to your AI provider."
                 : "Recognition is automatic and local. With translation off, the transcript stays on this Mac.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(mode == DictationOutputMode.message.rawValue
                 ? (enabled ? "Message opens a translated AI draft before insertion." : "Message opens a local draft. Improve with AI is optional.")
                 : "Text inserts the transcript, or keeps it ready to copy when no field is available.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .onChange(of: enabled) { _, _ in configured = true }
        .onChange(of: source) { _, _ in configured = true }
        .onChange(of: target) { _, _ in configured = true }
    }
    private func languageRow(_ title: String, selection: Binding<String>, allowsAutomatic: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 88, alignment: .leading)
            Picker(title, selection: selection) {
                if allowsAutomatic { Text("Auto-detect").tag("auto") }
                ForEach(TranslationLanguage.allCases) { language in
                    Text("\(language.flag) \(language.displayName)").tag(language.rawValue)
                }
            }.labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity)
        }
    }
}

private struct RecordingClockView: View {
    @ObservedObject var meter: RecordingMeterModel
    var body: some View {
        let seconds = max(0, Int(meter.elapsed))
        Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
            .font(.system(size: 11, design: .monospaced)).monospacedDigit()
            .foregroundStyle(.secondary).frame(width: 38)
    }
}

private struct RecordingSignalView: View {
    @ObservedObject var meter: RecordingMeterModel
    var isRecording = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(isRecording ? Color.red : Color.blue).frame(width: 7, height: 7)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || !isRecording)) { timeline in
                HStack(spacing: 2) {
                    ForEach(0..<9, id: \.self) { index in
                        let phase = timeline.date.timeIntervalSinceReferenceDate * 7 + Double(index) * 0.55
                        let motion = reduceMotion || !isRecording ? 0.35 : (sin(phase) + 1) / 2
                        Capsule().fill(LinearGradient(colors: [.blue, .purple, .pink], startPoint: .bottom, endPoint: .top))
                            .frame(width: 3, height: 4 + max(CGFloat(meter.level) * 24, CGFloat(motion) * 7))
                    }
                }.frame(height: 30)
            }
        }
    }
}
