import AppKit
import Foundation

@MainActor
final class OfflineDictationController {
    enum TriggerSource: Equatable {
        case hotKey
        case miniMicrophone
    }

    private let textAccess: TextAccessService
    private let recorder = SpeechAudioRecorder()
    private let modelManager = SpeechModelManager.shared
    private let transcriber = OfflineTranscriptionService.shared
    private let panel = DictationPanelController()
    private var target: TextAccessService.DictationTarget?
    private var language: SpeechLanguage = .english
    private var recordingStartedAt: Date?
    private var timer: Timer?
    private var localEscapeMonitor: Any?
    private var globalEscapeMonitor: Any?
    private var isPressed = false
    private var pendingTranscript: String?
    private var transcriptionTask: Task<Void, Never>?
    private var temporaryMessageID = UUID()
    private var triggerSource: TriggerSource = .hotKey
    private(set) var isBusy = false

    var onNeedsAccessibility: (() -> Void)?
    var onNeedsModelSettings: (() -> Void)?
    var onConsentRequired: ((CGRect, String) -> Void)?
    var onActivityChanged: ((Bool, TriggerSource) -> Void)?
    var onMiniMicrophoneStateChanged: ((DictationMicActivityState) -> Void)?
    var onMiniMicrophoneLevelChanged: ((Float) -> Void)?
    var onMiniMicrophoneElapsedChanged: ((TimeInterval) -> Void)?

    init(textAccess: TextAccessService) {
        self.textAccess = textAccess
        recorder.onLevel = { [weak self] level in
            guard let self else { return }
            if self.triggerSource == .miniMicrophone {
                self.onMiniMicrophoneLevelChanged?(level)
            } else {
                self.panel.updateLevel(level)
            }
        }
        recorder.onMaximumDuration = { [weak self] in self?.finishRecording() }
        panel.configureActions(
            retry: { [weak self] in self?.retryInsert() },
            copy: { [weak self] in self?.copyAndClose() },
            close: { [weak self] in self?.closeAndClear() },
            stop: { [weak self] in self?.stopFromUI() }
        )
    }

    func handle(_ phase: TextoraHotKeyPhase) {
        switch phase {
        case .pressed: begin(source: .hotKey)
        case .released: finishRecording()
        }
    }

    func startFromUI() {
        begin(source: .miniMicrophone)
    }

    func stopFromUI() {
        finishRecording()
    }

    func cancel() {
        invalidateTemporaryMessages()
        transcriptionTask?.cancel()
        transcriptionTask = nil
        isPressed = false
        recorder.cancel()
        stopTimerAndMonitors()
        target = nil
        pendingTranscript = nil
        panel.hide()
        if triggerSource == .miniMicrophone {
            onMiniMicrophoneStateChanged?(.idle)
        }
        setBusy(false)
    }

    func prepareForTermination() {
        cancel()
        transcriber.unload()
    }

    func disableAndUnload() {
        cancel()
        transcriber.unload()
    }

    private func begin(source: TriggerSource) {
        guard OfflineDictationSettings.isEnabled, !isPressed else { return }
        triggerSource = source
        isPressed = true
        if source == .miniMicrophone {
            onMiniMicrophoneStateChanged?(.preparing)
        }
        setBusy(true)
        guard textAccess.hasAccessibilityPermission() else {
            isPressed = false
            setBusy(false)
            onNeedsAccessibility?()
            return
        }
        switch textAccess.captureDictationTarget() {
        case .permissionRequired(let bundleID, let anchor):
            isPressed = false
            setBusy(false)
            onConsentRequired?(anchor, bundleID)
            return
        case .secureField:
            isPressed = false
            setBusy(false)
            showTemporaryMessage("Dictation is unavailable in secure fields.", isError: true)
            return
        case .unavailable:
            isPressed = false
            setBusy(false)
            showTemporaryMessage("Place the cursor in an editable text field.", isError: true)
            return
        case .success(let target):
            self.target = target
        }
        guard case .ready = modelManager.state else {
            isPressed = false
            setBusy(false)
            let message: String
            switch modelManager.state {
            case .downloading:
                message = "Downloading the offline speech model…"
            case .verifying:
                message = "Verifying the offline speech model…"
            case .notDownloaded, .paused, .failed:
                modelManager.download()
                message = "Downloading the offline speech model…"
            case .ready:
                return
            }
            showTemporaryMessage(message, isError: false, duration: 2.5)
            target = nil
            onNeedsModelSettings?()
            return
        }
        language = KeyboardInputSource.currentSpeechLanguage(fallback: OfflineDictationSettings.fallbackLanguage)
        let anchor = target?.anchor
        if SpeechAudioRecorder.authorizationStatus == .authorized {
            startRecorder(source: source, anchor: anchor)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            guard await SpeechAudioRecorder.requestPermission() else {
                self.isPressed = false
                self.setBusy(false)
                self.showTemporaryMessage("Allow microphone access in System Settings.", isError: true)
                self.target = nil
                return
            }
            self.startRecorder(source: source, anchor: anchor)
        }
    }

    private func startRecorder(source: TriggerSource, anchor: CGRect?) {
        guard isPressed else { return }
        do {
            try recorder.start(microphoneUID: OfflineDictationSettings.microphoneUID)
            recordingStartedAt = Date()
            invalidateTemporaryMessages()
            if source == .miniMicrophone {
                onMiniMicrophoneStateChanged?(.recording(language: language))
            } else {
                panel.show(state: .recording, language: language, anchor: anchor)
            }
            startTimerAndMonitors()
        } catch {
            isPressed = false
            setBusy(false)
            showTemporaryMessage(error.localizedDescription, isError: true)
        }
    }

    private func finishRecording() {
        guard isPressed else { return }
        isPressed = false
        guard recorder.isRecording else {
            target = nil
            stopTimerAndMonitors()
            if triggerSource == .miniMicrophone {
                onMiniMicrophoneStateChanged?(.idle)
            } else {
                panel.hide()
            }
            setBusy(false)
            return
        }
        let samples = recorder.stop()
        stopTimerAndMonitors()
        guard samples.count >= 1_600, let target else {
            self.target = nil
            setBusy(false)
            if triggerSource == .hotKey {
                panel.hide()
            } else {
                showTemporaryMessage("No speech detected.", isError: true)
            }
            return
        }
        invalidateTemporaryMessages()
        if triggerSource == .miniMicrophone {
            onMiniMicrophoneStateChanged?(.transcribing)
        } else {
            panel.show(state: .transcribing, language: language, anchor: target.anchor)
        }
        transcriptionTask?.cancel()
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await self.transcriber.transcribe(
                    samples: samples,
                    modelURL: self.modelManager.modelURL,
                    language: self.language
                )
                guard !Task.isCancelled, OfflineDictationSettings.isEnabled else { return }
                if self.textAccess.insertDictatedText(text, into: target) {
                    self.target = nil
                    if self.triggerSource == .miniMicrophone {
                        self.onMiniMicrophoneStateChanged?(.success)
                    } else {
                        self.panel.show(state: .success, language: self.language, anchor: target.anchor)
                    }
                    try? await Task.sleep(for: .milliseconds(700))
                    if self.triggerSource == .miniMicrophone {
                        self.onMiniMicrophoneStateChanged?(.idle)
                    } else {
                        self.panel.hide()
                    }
                    self.setBusy(false)
                } else {
                    self.pendingTranscript = text
                    if self.triggerSource == .miniMicrophone {
                        self.onMiniMicrophoneStateChanged?(.hidden)
                    }
                    self.panel.show(state: .result(text), language: self.language, anchor: target.anchor)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.target = nil
                self.setBusy(false)
                self.showTemporaryMessage(error.localizedDescription, isError: true, duration: 3)
            }
        }
    }

    private func retryInsert() {
        guard let text = pendingTranscript, let target else { return }
        if textAccess.insertDictatedText(text, into: target, reactivateTarget: true) {
            pendingTranscript = nil
            self.target = nil
            if triggerSource == .miniMicrophone {
                onMiniMicrophoneStateChanged?(.success)
            } else {
                panel.show(state: .success, language: language, anchor: target.anchor)
            }
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                guard let self else { return }
                if self.triggerSource == .miniMicrophone {
                    self.onMiniMicrophoneStateChanged?(.idle)
                } else {
                    self.panel.hide()
                }
                self.setBusy(false)
            }
        } else {
            NSSound.beep()
        }
    }

    private func copyAndClose() {
        guard let text = pendingTranscript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        closeAndClear()
    }

    private func closeAndClear() {
        pendingTranscript = nil
        target = nil
        panel.hide()
        if triggerSource == .miniMicrophone {
            onMiniMicrophoneStateChanged?(.idle)
        }
        setBusy(false)
    }

    private func setBusy(_ value: Bool) {
        guard isBusy != value else { return }
        isBusy = value
        onActivityChanged?(value, triggerSource)
    }

    private func startTimerAndMonitors() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let started = self.recordingStartedAt else { return }
                let elapsed = Date().timeIntervalSince(started)
                if self.triggerSource == .miniMicrophone {
                    self.onMiniMicrophoneElapsedChanged?(elapsed)
                } else {
                    self.panel.updateElapsed(elapsed)
                }
            }
        }
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { Task { @MainActor in self?.cancel() }; return nil }
            return event
        }
        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { Task { @MainActor in self?.cancel() } }
        }
    }

    private func stopTimerAndMonitors() {
        timer?.invalidate(); timer = nil
        recordingStartedAt = nil
        if let localEscapeMonitor { NSEvent.removeMonitor(localEscapeMonitor) }
        if let globalEscapeMonitor { NSEvent.removeMonitor(globalEscapeMonitor) }
        localEscapeMonitor = nil
        globalEscapeMonitor = nil
    }

    private func showTemporaryMessage(_ text: String, isError: Bool, duration: TimeInterval = 2) {
        let messageID = UUID()
        temporaryMessageID = messageID
        if triggerSource == .miniMicrophone {
            onMiniMicrophoneStateChanged?(.message(text, isError: isError))
        } else {
            panel.show(state: .message(text, isError: isError), language: language, anchor: target?.anchor)
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, self.temporaryMessageID == messageID else { return }
            if self.triggerSource == .miniMicrophone {
                self.onMiniMicrophoneStateChanged?(.idle)
            } else {
                self.panel.hide()
            }
        }
    }

    private func invalidateTemporaryMessages() {
        temporaryMessageID = UUID()
    }
}
