import AppKit
import SwiftUI

@MainActor
final class DictationOverlayModel: ObservableObject {
    enum State: Equatable {
        case preparing
        case recording
        case transcribing
        case success
        case message(String, isError: Bool)
        case result(String)

        var hasRecordingControls: Bool {
            switch self { case .preparing, .recording: return true; default: return false }
        }
    }

    @Published var state: State = .recording
    let meter = RecordingMeterModel()
    let recordingControls = RecordingControlsModel()
    var level: Float { get { meter.level } set { meter.level = newValue } }
    var elapsed: TimeInterval { get { meter.elapsed } set { meter.elapsed = newValue } }
    @Published var language: SpeechLanguage = .english
    @Published var isCopyOnly = false
    @Published var canRetry = true
    @Published var resultMessage = "Textora could not insert it into the original field."
    @Published var retryTitle = "Retry Insert"
    @Published var canSelectTarget = false
    @Published var needsTargetSelection = false
    @Published var directionLabel = ""
    @Published var targetLanguage: TranslationLanguage?
    var onSelectTarget: ((TranslationLanguage) -> Void)?
    var onRetry: (() -> Void)?
    var onCopy: (() -> Void)?
    var onClose: (() -> Void)?
    var onStop: (() -> Void)?
}

private final class DictationRecordingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class DictationPanelController: NSObject, NSWindowDelegate {
    private let model = DictationOverlayModel()
    private var panel: NSPanel?

    override init() {
        super.init()
        model.recordingControls.onExpandedChanged = { [weak self] _ in self?.resizeRecordingOptions() }
    }

    func show(state: DictationOverlayModel.State, language: SpeechLanguage, anchor: CGRect?) {
        let previousState = model.state
        let wasVisible = panel?.isVisible == true
        if previousState.hasRecordingControls && !state.hasRecordingControls {
            panel?.makeFirstResponder(nil)
            if panel?.isKeyWindow == true { panel?.resignKey() }
        }
        model.resultMessage = model.isCopyOnly ? "Ready to copy. Paste with ⌘V wherever you choose." : "Textora could not insert it into the original field."
        model.retryTitle = "Retry Insert"
        model.canRetry = !model.isCopyOnly
        if model.state != state { model.state = state }
        if model.language != language { model.language = language }
        if !state.hasRecordingControls || !previousState.hasRecordingControls || panel == nil { model.recordingControls.isExpanded = false }
        let size = desiredSize

        if panel == nil {
            let panel = DictationRecordingPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .statusBar
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            panel.isMovableByWindowBackground = true
            panel.delegate = self
            panel.identifier = NSUserInterfaceItemIdentifier("Textora.DictationRecording")
            let host = NSHostingView(rootView: DictationOverlayView(model: model))
            host.sizingOptions = []
            host.frame = CGRect(origin: .zero, size: size)
            host.autoresizingMask = [.width, .height]
            host.focusRingType = .none
            host.wantsLayer = true
            host.layer?.backgroundColor = NSColor.clear.cgColor
            host.layer?.isOpaque = false
            panel.contentView = host
            self.panel = panel
        }
        if panel?.frame.size != size { panel?.setContentSize(size) }
        if !wasVisible { positionPanel(size: size, anchor: anchor) }
        if panel?.isVisible != true { panel?.orderFrontRegardless() }
    }

    func hide(clearResult: Bool = true) {
        panel?.makeFirstResponder(nil)
        if panel?.isKeyWindow == true { panel?.resignKey() }
        panel?.orderOut(nil)
        if clearResult {
            model.state = .message("", isError: false)
            model.recordingControls.isExpanded = false
            model.isCopyOnly = false
        }
    }

    func updateLevel(_ value: Float) { model.level = value }
    func setCopyOnly(_ value: Bool) {
        if model.isCopyOnly != value { model.isCopyOnly = value }
        model.canRetry = !value
    }
    func setResultMessage(_ message: String, retryTitle: String, canRetry: Bool = true) {
        model.resultMessage = message
        model.retryTitle = retryTitle
        model.canRetry = canRetry
    }
    func setTranslationState(enabled: Bool, direction: LanguageDirection? = nil, needsTarget: Bool = false) {
        model.canSelectTarget = enabled
        model.needsTargetSelection = needsTarget
        model.targetLanguage = direction?.target
        model.directionLabel = direction?.label ?? ""
        if needsTarget { model.canRetry = false }
    }
    func configureTargetSelection(_ action: @escaping (TranslationLanguage) -> Void) { model.onSelectTarget = action }
    func updateElapsed(_ value: TimeInterval) { model.elapsed = value }

    func configureActions(
        retry: @escaping () -> Void,
        copy: @escaping () -> Void,
        close: @escaping () -> Void,
        stop: @escaping () -> Void
    ) {
        model.onRetry = retry
        model.onCopy = copy
        model.onClose = close
        model.onStop = stop
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel else { return }
        OfflineDictationSettings.capsuleOrigin = panel.frame.origin
    }

    private var desiredSize: CGSize {
        switch model.state {
        case .preparing, .recording: return RecordingCapsuleLayout.size(expanded: model.recordingControls.isExpanded)
        case .result: return CGSize(width: 560, height: 360)
        default: return CGSize(width: 430, height: 88)
        }
    }

    private func resizeRecordingOptions() {
        guard model.state.hasRecordingControls, let panel, panel.isVisible else { return }
        let size = desiredSize
        guard panel.frame.size != size else { return }
        let previous = panel.frame
        var origin = CGPoint(x: previous.minX, y: previous.maxY - size.height)
        if let visible = (NSScreen.screens.first { $0.visibleFrame.intersects(previous) } ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    private func positionPanel(size: CGSize, anchor: CGRect?) {
        guard let panel else { return }
        if let saved = OfflineDictationSettings.capsuleOrigin,
           let frame = DictationMicLayout.clampedDockFrame(origin: saved, size: size,
                                                          visibleFrames: NSScreen.screens.map(\.visibleFrame)) {
            panel.setFrameOrigin(frame.origin)
            return
        }
        let screen = anchor.flatMap { rect in
            NSScreen.screens.first(where: { $0.visibleFrame.intersects(rect) })
        } ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let origin = CGPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 34
        )
        let frame = DictationMicLayout.clampedDockFrame(origin: origin, size: size, visibleFrames: [visible])
        panel.setFrameOrigin(frame?.origin ?? origin)
    }
}

struct DictationOverlayView: View {
    @ObservedObject var model: DictationOverlayModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if model.state.hasRecordingControls { recordingView }
            else {
                switch model.state {
                case .recording, .preparing: EmptyView()
                case .transcribing: statusView(title: "Transcribing", systemImage: "waveform", color: .blue, spins: true)
                case .success: statusView(title: "Inserted", systemImage: "checkmark.circle.fill", color: .green, spins: false)
                case .message(let text, let isError):
                    statusView(title: text, systemImage: isError ? "exclamationmark.circle.fill" : "info.circle.fill", color: isError ? .red : .blue, spins: false)
                case .result(let text): resultView(text: text)
                }
            }
        }
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var recordingView: some View {
        RecordingCapsuleView(meter: model.meter, options: model.recordingControls,
                             onStop: { model.onStop?() }, isCopyOnly: model.isCopyOnly,
                             isPreparing: model.state == .preparing)
    }

    private func statusView(title: String, systemImage: String, color: Color, spins: Bool) -> some View {
        HStack(spacing: 13) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(color)
                .symbolEffect(.variableColor.iterative, options: spins ? .repeating : .nonRepeating)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 22)
        .frame(width: 430, height: 88)
    }

    private func resultView(text: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image("AppLogo").resizable().scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dictation ready").font(.system(size: 18, weight: .bold))
                    Text(model.resultMessage)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.onClose?() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
            if model.canSelectTarget {
                HStack {
                    Text(model.needsTargetSelection ? "Choose a target to continue" : model.directionLabel).font(.caption)
                    Spacer()
                    TemporaryTargetPicker(selection: model.targetLanguage) { model.onSelectTarget?($0) }
                }
            }
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .frame(maxHeight: model.canSelectTarget ? 155 : 210)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Close") { model.onClose?() }
                Spacer()
                Button { model.onCopy?() } label: { Label("Copy", systemImage: "doc.on.doc") }
                if model.canRetry {
                    Button { model.onRetry?() } label: { Label(model.retryTitle, systemImage: "arrow.clockwise") }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(22)
        .frame(width: 560, height: 360)
    }

    private var durationText: String {
        let value = Int(model.elapsed)
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color(nsColor: .windowBackgroundColor).opacity(colorScheme == .dark ? 0.96 : 0.98))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}
