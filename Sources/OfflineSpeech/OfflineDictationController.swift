import AppKit
import Foundation
import SwiftUI

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
    private var sessionID = UUID()
    private var translationSettings = DictationTranslationSettings.load()
    private var untranslatedText: String?
    private var needsTranslationRetry = false
    private var setupWindow: NSWindow?
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
            retry: { [weak self] in self?.retryResult() },
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
        sessionID = UUID()
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
        guard OfflineDictationSettings.isEnabled, !isPressed, !isBusy else { return }
        if source == .hotKey, !UserDefaults.standard.bool(forKey: "dictation.translation.configured") {
            showFirstRunSetup()
            return
        }
        sessionID = UUID()
        translationSettings = .load()
        untranslatedText = nil
        needsTranslationRetry = false
        triggerSource = source
        isPressed = true
        if source == .miniMicrophone {
            onMiniMicrophoneStateChanged?(.preparing)
        } else {
            panel.show(state: .message("Preparing…", isError: false), language: language, anchor: nil)
        }
        setBusy(true)
        guard textAccess.hasAccessibilityPermission() else {
            isPressed = false
            setBusy(false)
            onNeedsAccessibility?()
            return
        }
        let session = sessionID
        transcriptionTask = Task { await prepareRecording(source: source, session: session) }
    }

    private func prepareRecording(source: TriggerSource, session: UUID) async {
        let captured = await SelectionTextWorker.shared.dictationTarget()
        guard sessionID == session, isPressed, !Task.isCancelled else { return }
        switch captured {
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
        let anchor = target?.anchor
        if SpeechAudioRecorder.authorizationStatus == .authorized {
            let id = sessionID
            transcriptionTask = Task { await startRecorder(source: source, anchor: anchor, session: id) }
            return
        }
        let id = sessionID
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            guard await SpeechAudioRecorder.requestPermission() else {
                guard self.sessionID == id, !Task.isCancelled else { return }
                self.isPressed = false
                self.setBusy(false)
                self.showTemporaryMessage("Allow microphone access in System Settings.", isError: true)
                self.target = nil
                return
            }
            guard self.sessionID == id, !Task.isCancelled else { return }
            await self.startRecorder(source: source, anchor: anchor, session: id)
        }
    }

    private func startRecorder(source: TriggerSource, anchor: CGRect?, session: UUID) async {
        guard isPressed, sessionID == session else { return }
        do {
            try await recorder.start(microphoneUID: OfflineDictationSettings.microphoneUID)
            guard isPressed, sessionID == session, !Task.isCancelled else {
                if sessionID == session { recorder.cancel() }
                return
            }
            recordingStartedAt = Date()
            invalidateTemporaryMessages()
            if source == .miniMicrophone {
                onMiniMicrophoneStateChanged?(.recording(language: language))
            } else {
                panel.show(state: .recording, language: language, anchor: anchor)
            }
            startTimerAndMonitors()
        } catch {
            guard sessionID == session, !Task.isCancelled else { return }
            isPressed = false
            setBusy(false)
            showTemporaryMessage(error.localizedDescription, isError: true)
        }
    }

    private func finishRecording() {
        guard isPressed else { return }
        isPressed = false
        guard recordingStartedAt != nil else {
            transcriptionTask?.cancel()
            recorder.cancel()
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
        stopTimerAndMonitors()
        guard let target else {
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
        let id = sessionID
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let samples = await self.recorder.stop()
                guard self.sessionID == id, !Task.isCancelled else { return }
                guard samples.count >= 1_600 else { throw OfflineTranscriptionError.noSpeech }
                let text = try await self.transcriber.transcribe(
                    samples: samples,
                    modelURL: self.modelManager.modelURL
                )
                guard !Task.isCancelled, OfflineDictationSettings.isEnabled else { return }
                self.untranslatedText = text
                self.needsTranslationRetry = self.translationSettings.enabled
                let output = try await self.translateIfNeeded(text)
                self.needsTranslationRetry = false
                guard self.sessionID == id, !Task.isCancelled else { return }
                self.pendingTranscript = output
                self.showProgress("Inserting…")
                if await SelectionTextWorker.shared.insertDictation(output, into: target) {
                    guard !Task.isCancelled else { return }
                    self.target = nil
                    if self.triggerSource == .miniMicrophone {
                        self.onMiniMicrophoneStateChanged?(.success)
                    } else {
                        self.panel.show(state: .success, language: self.language, anchor: target.anchor)
                    }
                    try? await Task.sleep(for: .milliseconds(700))
                    guard self.sessionID == id, !Task.isCancelled else { return }
                    if self.triggerSource == .miniMicrophone {
                        self.onMiniMicrophoneStateChanged?(.idle)
                    } else {
                        self.panel.hide()
                    }
                    self.setBusy(false)
                } else {
                    guard self.sessionID == id, !Task.isCancelled else { return }
                    self.pendingTranscript = output
                    if self.triggerSource == .miniMicrophone {
                        self.onMiniMicrophoneStateChanged?(.hidden)
                    }
                    self.panel.show(state: .result(output), language: self.language, anchor: target.anchor)
                }
            } catch {
                guard self.sessionID == id, !Task.isCancelled else { return }
                if let original = self.untranslatedText {
                    self.pendingTranscript = original
                    self.onMiniMicrophoneStateChanged?(.hidden)
                    self.panel.show(state: .result(original), language: self.language, anchor: target.anchor)
                    self.panel.setResultMessage("Translation failed: \(error.localizedDescription). Copy the original or retry translation.", retryTitle: "Retry Translation")
                    return
                }
                self.target = nil
                self.setBusy(false)
                self.showTemporaryMessage(error.localizedDescription, isError: true, duration: 3)
            }
        }
    }

    private func translateIfNeeded(_ text: String) async throws -> String {
        guard translationSettings.enabled else { return text }
        showProgress("Translating…")
        guard let config = SelectionAssistantViewModel.providerConfiguration() else {
            throw NSError(domain: "Textora", code: 43, userInfo: [NSLocalizedDescriptionKey: "Add an AI key in Settings."])
        }
        let result = try await AIClient().translateText(provider: config.provider, model: config.model, apiKey: config.key,
            text: text, targetLanguage: translationSettings.target.displayName, sourceLanguage: translationSettings.source.displayName)
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "Textora", code: 44, userInfo: [NSLocalizedDescriptionKey: "Empty translation."])
        }
        return result
    }

    private func showProgress(_ title: String) {
        if triggerSource == .miniMicrophone { onMiniMicrophoneStateChanged?(.message(title, isError: false)) }
        else { panel.show(state: .message(title, isError: false), language: language, anchor: target?.anchor) }
    }

    private func retryResult() {
        transcriptionTask?.cancel()
        let id = sessionID
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            if self.needsTranslationRetry, let original = self.untranslatedText {
                do {
                    let result = try await self.translateIfNeeded(original)
                    guard self.sessionID == id, !Task.isCancelled else { return }
                    self.pendingTranscript = result
                    self.needsTranslationRetry = false
                    self.panel.show(state: .result(result), language: self.language, anchor: self.target?.anchor)
                } catch {
                    guard !Task.isCancelled else { return }
                    self.panel.show(state: .result(original), language: self.language, anchor: self.target?.anchor)
                    self.panel.setResultMessage(error.localizedDescription, retryTitle: "Retry Translation")
                    return
                }
            }
            await self.retryInsert()
        }
    }

    private func showFirstRunSetup() {
        if let setupWindow { setupWindow.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 340),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Set up dictation"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 14) {
            Text("Hold \(SelectionAssistantSettings.hotKey(for: .dictate).displayName) to dictate.").font(.headline)
            DictationTranslationSettingsView()
            Text("You can change translation and languages in Settings at any time. After saving, press the shortcut again to record.").font(.caption)
            Button("Done") {
                UserDefaults.standard.set(true, forKey: "dictation.translation.configured")
                window.close()
            }
        }.padding(20).frame(width: 380))
        setupWindow = window
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func retryInsert() async {
        guard let text = pendingTranscript, let target else { return }
        let id = sessionID
        if await SelectionTextWorker.shared.insertDictation(text, into: target, reactivate: true) {
            guard sessionID == id, !Task.isCancelled else { return }
            pendingTranscript = nil
            self.target = nil
            if triggerSource == .miniMicrophone {
                onMiniMicrophoneStateChanged?(.success)
            } else {
                panel.show(state: .success, language: language, anchor: target.anchor)
            }
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                guard let self, self.sessionID == id else { return }
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
        sessionID = UUID()
        transcriptionTask?.cancel()
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
