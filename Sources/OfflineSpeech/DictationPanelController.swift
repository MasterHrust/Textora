import AppKit
import SwiftUI

@MainActor
final class DictationOverlayModel: ObservableObject {
    enum State: Equatable {
        case recording
        case transcribing
        case success
        case message(String, isError: Bool)
        case result(String)
    }

    @Published var state: State = .recording
    @Published var level: Float = 0
    @Published var elapsed: TimeInterval = 0
    @Published var language: SpeechLanguage = .english
    @Published var resultMessage = "Textora could not insert it into the original field."
    @Published var retryTitle = "Retry Insert"
    var onRetry: (() -> Void)?
    var onCopy: (() -> Void)?
    var onClose: (() -> Void)?
    var onStop: (() -> Void)?
}

@MainActor
final class DictationPanelController: NSObject, NSWindowDelegate {
    private let model = DictationOverlayModel()
    private var panel: NSPanel?

    func show(state: DictationOverlayModel.State, language: SpeechLanguage, anchor: CGRect?) {
        model.resultMessage = "Textora could not insert it into the original field."
        model.retryTitle = "Retry Insert"
        model.state = state
        model.language = language
        let isResult: Bool
        if case .result = state { isResult = true } else { isResult = false }
        let size = isResult ? CGSize(width: 560, height: 360) : CGSize(width: 430, height: 88)

        if panel == nil {
            let panel = NSPanel(
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
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            panel.isMovableByWindowBackground = true
            panel.delegate = self
            self.panel = panel
        }
        panel?.setContentSize(size)
        if !(panel?.contentView is NSHostingView<DictationOverlayView>) {
        let host = NSHostingView(rootView: DictationOverlayView(model: model))
        host.focusRingType = .none
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.layer?.isOpaque = false
        panel?.contentView = host
        }
        positionPanel(size: size, anchor: anchor)
        panel?.orderFrontRegardless()
    }

    func hide(clearResult: Bool = true) {
        panel?.orderOut(nil)
        if clearResult { model.state = .message("", isError: false) }
    }

    func updateLevel(_ value: Float) { model.level = value }
    func setResultMessage(_ message: String, retryTitle: String) {
        model.resultMessage = message
        model.retryTitle = retryTitle
    }
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

    private func positionPanel(size: CGSize, anchor: CGRect?) {
        guard let panel else { return }
        if let saved = OfflineDictationSettings.capsuleOrigin,
           NSScreen.screens.contains(where: { $0.visibleFrame.contains(saved) }) {
            panel.setFrameOrigin(saved)
            return
        }
        let screen = anchor.flatMap { rect in
            NSScreen.screens.first(where: { $0.visibleFrame.intersects(rect) })
        } ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrameOrigin(CGPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 34
        ))
    }
}

private struct DictationOverlayView: View {
    @ObservedObject var model: DictationOverlayModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            switch model.state {
            case .recording: recordingView
            case .transcribing: statusView(title: "Transcribing", systemImage: "waveform", color: .blue, spins: true)
            case .success: statusView(title: "Inserted", systemImage: "checkmark.circle.fill", color: .green, spins: false)
            case .message(let text, let isError):
                statusView(title: text, systemImage: isError ? "exclamationmark.circle.fill" : "info.circle.fill", color: isError ? .red : .blue, spins: false)
            case .result(let text): resultView(text: text)
            }
        }
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var recordingView: some View {
        HStack(spacing: 14) {
            Circle().fill(.red).frame(width: 10, height: 10)
                .shadow(color: .red.opacity(0.55), radius: 6)
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                HStack(spacing: 3) {
                    ForEach(0..<13, id: \.self) { index in
                        let phase = timeline.date.timeIntervalSinceReferenceDate * 7 + Double(index) * 0.55
                        let motion = CGFloat((sin(phase) + 1) / 2)
                        Capsule()
                            .fill(LinearGradient(colors: [.blue, .purple, .pink], startPoint: .bottom, endPoint: .top))
                            .frame(width: 3, height: 6 + max(CGFloat(model.level) * 30, motion * 7))
                    }
                }
                .frame(width: 78, height: 42)
                .animation(.easeOut(duration: 0.14), value: model.level)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Listening")
                    .font(.system(size: 15, weight: .semibold))
                Text(durationText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.onStop?()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .background(Color.red.opacity(0.16), in: Capsule())
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Stop recording")
        }
        .padding(.horizontal, 20)
        .frame(width: 430, height: 88)
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
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .frame(maxHeight: 210)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Close") { model.onClose?() }
                Spacer()
                Button { model.onCopy?() } label: { Label("Copy", systemImage: "doc.on.doc") }
                Button { model.onRetry?() } label: { Label(model.retryTitle, systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderedProminent)
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
