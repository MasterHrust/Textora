import SwiftUI

struct DictationTranslationSettings: Equatable {
    var enabled: Bool
    var source: TranslationLanguage
    var target: TranslationLanguage

    static func load(_ defaults: UserDefaults = .standard) -> Self {
        Self(enabled: defaults.bool(forKey: "dictation.translation.enabled"),
             source: TranslationLanguage(rawValue: defaults.string(forKey: "dictation.translation.source") ?? "russian") ?? .russian,
             target: TranslationLanguage(rawValue: defaults.string(forKey: "dictation.translation.target") ?? "english") ?? .english)
    }
}

struct DictationTranslationSettingsView: View {
    @AppStorage("dictation.translation.enabled") private var enabled = false
    @AppStorage("dictation.translation.source") private var source = "russian"
    @AppStorage("dictation.translation.target") private var target = "english"
    @AppStorage("dictation.translation.configured") private var configured = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Translate dictated text", isOn: $enabled)
            Group {
                languageRow("From", selection: $source)
                languageRow("To", selection: $target)
                Button {
                    let previousSource = source
                    source = target
                    target = previousSource
                    configured = true
                } label: {
                    Label("Swap languages", systemImage: "arrow.left.arrow.right")
                }
            }
            .disabled(!enabled)
            Text("Shared by Toolbox and Hotkeys. Translation sends the transcript to your AI provider. Audio stays on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Save dictation preferences") { configured = true }
                .controlSize(.small)
        }
        .onChange(of: enabled) { _, _ in configured = true }
        .onChange(of: source) { _, _ in configured = true }
        .onChange(of: target) { _, _ in configured = true }
    }

    private func languageRow(_ title: String, selection: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 42, alignment: .leading)
            Picker(title, selection: selection) {
                ForEach(TranslationLanguage.allCases) { language in
                    Text("\(language.flag) \(language.displayName)").tag(language.rawValue)
                }
            }.labelsHidden().frame(maxWidth: .infinity)
        }
    }
}

struct DictationTranslationControl: View {
    @Binding var tip: MicrophoneTip?
    @AppStorage("dictation.translation.enabled") private var enabled = false
    @AppStorage("dictation.translation.source") private var source = "russian"
    @AppStorage("dictation.translation.target") private var target = "english"
    @AppStorage("dictation.translation.configured") private var configured = false
    @Binding var isPresented: Bool
    var body: some View {
        HStack(spacing: 10) {
            Button {
                enabled.toggle()
                configured = true
            } label: {
                Image(systemName: "wand.and.stars").foregroundStyle(enabled ? .purple : .secondary)
            }
            .help("Translate dictated text")
            .accessibilityLabel("Translate dictated text")
            .modifier(MicrophoneTipAnchor(target: .translation, active: $tip))
            Button {
                isPresented = true
            } label: {
                Text((TranslationLanguage(rawValue: source) ?? .russian).flag)
                    .font(.system(size: 16))
            }
            .help("Dictation translation languages")
            .modifier(MicrophoneTipAnchor(target: .languages, active: $tip))
            .popover(isPresented: $isPresented) {
                DictationTranslationSettingsView().padding().frame(width: 310)
                    .transaction { $0.animation = nil }
            }
            Button {
                let previousSource = source
                source = target
                target = previousSource
                configured = true
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .help("Swap languages")
            .accessibilityLabel("Swap languages")
            .modifier(MicrophoneTipAnchor(target: .swap, active: $tip))
            Button { isPresented = true } label: {
                Text((TranslationLanguage(rawValue: target) ?? .english).flag)
                    .font(.system(size: 16))
            }
            .help("Target language and translation settings")
        }.buttonStyle(.borderless)
    }
}

enum MicrophoneTip: Int, CaseIterable {
    case microphone, translation, languages, swap, drag
    var next: Self? { Self(rawValue: rawValue + 1) }
    var title: String {
        switch self {
        case .microphone: return "Record your voice"
        case .translation: return "Translate after recording"
        case .languages: return "Choose the languages"
        case .swap: return "Reverse the translation"
        case .drag: return "Move the microphone"
        }
    }
    var message: String {
        switch self {
        case .microphone: return "Click to start recording. Click again to stop and insert the transcript. Speech recognition stays on this Mac."
        case .translation: return "The wand turns speech translation on or off. When enabled, only the recognized text is sent to your AI provider."
        case .languages: return "Click a flag to choose the source and target languages for speech translation."
        case .swap: return "Click these arrows to swap the source and target languages instantly."
        case .drag: return "Drag this handle to reposition the microphone. The extra controls retract 2 seconds after you move away."
        }
    }
}

struct MicrophoneTipAnchor: ViewModifier {
    let target: MicrophoneTip
    @Binding var active: MicrophoneTip?
    func body(content: Content) -> some View {
        content.background(MicrophoneTipAnchorView(target: target, active: $active))
    }
}

/// All controls share ONE popover. Advancing moves its anchor instead of
/// racing the dismissal/presentation of independent SwiftUI popovers.
@MainActor
final class MicrophoneTipPresenter {
    static let shared = MicrophoneTipPresenter()
    private final class Anchor {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }
    private var anchors: [MicrophoneTip: Anchor] = [:]
    private let popover = NSPopover()
    private var shownTip: MicrophoneTip?
    private var host: NSHostingController<MicrophoneTipContent>?
    var displayedTip: MicrophoneTip? { popover.isShown ? shownTip : nil }

    init() {
        popover.behavior = .applicationDefined
        popover.animates = false
    }

    func register(_ view: NSView, for tip: MicrophoneTip) { anchors[tip] = Anchor(view) }
    func unregister(_ view: NSView, for tip: MicrophoneTip) {
        if anchors[tip]?.view === view { anchors.removeValue(forKey: tip) }
    }

    func update(_ active: Binding<MicrophoneTip?>) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let tip = active.wrappedValue else {
                self.popover.close()
                self.popover.contentViewController = nil
                self.host = nil
                self.shownTip = nil
                return
            }
            guard let anchor = self.anchors[tip]?.view, anchor.window != nil else { return }
            guard self.shownTip != tip || !self.popover.isShown else { return }
            let finish = {
                UserDefaults.standard.set(true, forKey: "microphone.introduction.v3.completed")
                active.wrappedValue = nil
            }
            let content = MicrophoneTipContent(tip: tip, onSkip: finish, onNext: {
                if let next = tip.next { active.wrappedValue = next }
                else { finish() }
            })
            if let host = self.host { host.rootView = content }
            else { self.host = NSHostingController(rootView: content) }
            self.popover.contentViewController = self.host
            self.popover.contentSize = self.host!.view.fittingSize
            self.shownTip = tip
            self.popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
    }
}

private struct MicrophoneTipAnchorView: NSViewRepresentable {
    let target: MicrophoneTip
    @Binding var active: MicrophoneTip?
    final class Coordinator {
        let target: MicrophoneTip
        init(_ target: MicrophoneTip) { self.target = target }
    }
    func makeCoordinator() -> Coordinator { Coordinator(target) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        MicrophoneTipPresenter.shared.register(view, for: target)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        MicrophoneTipPresenter.shared.register(view, for: target)
        MicrophoneTipPresenter.shared.update($active)
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        MicrophoneTipPresenter.shared.unregister(view, for: coordinator.target)
    }
}

struct MicrophoneTipContent: View {
    let tip: MicrophoneTip
    let onSkip: () -> Void
    let onNext: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tip.title).font(.headline)
            Text(tip.message).font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Skip", action: onSkip).buttonStyle(.borderless)
                Spacer()
                Text("\(tip.rawValue + 1)/\(MicrophoneTip.allCases.count)").font(.caption).foregroundStyle(.secondary)
                Button(tip.next == nil ? "Got it" : "Next", action: onNext).buttonStyle(.borderedProminent)
            }
        }.padding(14).frame(width: 290)
    }
}

/// A lightweight, local demonstration: no screen capture or AI requests.
struct ToolPanelSelectionDemo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Toolbox starts with selected text", systemImage: "selection.pin.in.out")
                .font(.subheadline.weight(.semibold))
            Text(phase == 2 ? "Please send the report." : "please send the report")
                .font(.system(size: 13))
                .padding(6)
                .background(phase == 0 ? Color.blue.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            Text(["1. Select a word or sentence in your app.",
                  "2. Toolbox appears. Pick Fix, Shorten, Formal or Humanize.",
                  "3. Click After to replace the selection."][phase])
                .font(.caption).foregroundStyle(.secondary)
                .frame(height: 32, alignment: .topLeading)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                phase = (phase + 1) % 3
            }
        }
    }
}

struct TextoraFeatureGuide: View {
    let onDone: () -> Void
    @State private var step = 0
    init(initialStep: Int = 0, onDone: @escaping () -> Void) {
        self.onDone = onDone
        _step = State(initialValue: min(2, max(0, initialStep)))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Quick introduction · \(step + 1)/3").font(.headline)
            if step == 0 {
                ToolPanelSelectionDemo()
            } else if step == 1 {
                Label("SmartAI improves your message", systemImage: "wand.and.stars").font(.headline)
                Text("Select text to review four writing modes. The sparkle recommends an improvement; a green check means the text already looks good. Nothing is replaced until you click the result.")
                    .font(.callout)
            } else {
                Label("Speak, then translate", systemImage: "mic.fill").font(.headline)
                Text("Hover over the microphone to reveal its controls. The wand enables speech translation. Flags choose the source and target languages; ↔ swaps them. Audio stays local; only the transcript is sent to AI for translation.")
                    .font(.callout)
                Text("Drag the handle to move the microphone. The controls retract 2 seconds after you move away.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Skip") { onDone() }.buttonStyle(.borderless)
                Spacer()
                if step > 0 { Button("Back") { step -= 1 } }
                Button(step == 2 ? "Got it" : "Next") {
                    if step == 2 { onDone() } else { step += 1 }
                }.buttonStyle(.borderedProminent)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
