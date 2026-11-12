import AppKit
import Foundation
import SwiftUI

/// The physical key state is separate from a requested recording. In toggle mode
/// releasing the shortcut cannot cancel an asynchronous permission or audio start.
struct DictationRecordingSession {
    enum Phase: Equatable { case idle, preparing(UUID), recording(UUID), processing(UUID) }
    enum ShortcutAction: Equatable { case none, start, stop }
    private(set) var phase: Phase = .idle
    private(set) var options: DictationSessionOptions?
    private var shortcutMode: DictationShortcutMode?
    private var shortcutIsDown = false
    var isRequested: Bool {
        switch phase { case .preparing, .recording: return true; default: return false }
    }

    mutating func shortcut(_ event: TextoraHotKeyPhase, mode: DictationShortcutMode) -> ShortcutAction {
        switch event {
        case .pressed:
            guard !shortcutIsDown else { return .none }
            shortcutIsDown = true
            if isRequested { return shortcutMode == .hold ? .none : .stop }
            guard phase == .idle else { return .none }
            return .start
        case .released:
            guard shortcutIsDown else { return .none }
            shortcutIsDown = false
            return isRequested && shortcutMode == .hold ? .stop : .none
        }
    }
    mutating func begin(id: UUID, shortcutMode: DictationShortcutMode?) {
        phase = .preparing(id); self.shortcutMode = shortcutMode; options = nil
    }
    mutating func didStart(id: UUID) -> Bool {
        guard phase == .preparing(id) else { return false }
        phase = .recording(id)
        return true
    }
    mutating func stop(options: DictationSessionOptions) -> DictationSessionOptions? {
        guard case .recording(let id) = phase else {
            if case .preparing = phase { cancel() }
            return nil
        }
        self.options = options; phase = .processing(id)
        return options
    }
    mutating func cancel(resetShortcut: Bool = false) {
        phase = .idle; options = nil; shortcutMode = nil
        if resetShortcut { shortcutIsDown = false }
    }
}

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
    private let messagePreview = MessagePreviewController()
    private var sessionStyle: StyleProfile?
    private var sessionOutput = DictationOutputMode.text
    private var historyToken: Int?
    private var messageGeneration = 0
    private var messageClarification = ""

    private var target: TextAccessService.DictationTarget?
    private var origin: TextAccessService.DictationOrigin?
    private var resultAnchor: CGRect? { target?.anchor ?? origin?.anchor }
    private var language: SpeechLanguage = .english
    private var recordingStartedAt: Date?
    private var timer: Timer?
    private var localEscapeMonitor: Any?
    private var globalEscapeMonitor: Any?
    private var recordingSession = DictationRecordingSession()
    private var isPressed: Bool { recordingSession.isRequested }
    private var pendingTranscript: String?
    private var transcriptionTask: Task<Void, Never>?
    private var temporaryMessageID = UUID()
    private var triggerSource: TriggerSource = .hotKey
    private var sessionID = UUID()
    private var translationSettings = DictationTranslationSettings.load()
    private var rawTranscript: String?
    private var untranslatedText: String?
    private var needsTranslationRetry = false
    private(set) var isBusy = false

    var onNeedsAccessibility: (() -> Void)?
    var onNeedsModelSettings: (() -> Void)?
    var onConsentRequired: ((CGRect, String) -> Void)?
    var onActivityChanged: ((Bool, TriggerSource) -> Void)?
    var onMiniMicrophoneStateChanged: ((DictationMicActivityState) -> Void)?
    var onMiniMicrophoneLevelChanged: ((Float) -> Void)?
    var onMiniMicrophoneElapsedChanged: ((TimeInterval) -> Void)?
    var onDestinationChanged: ((Bool) -> Void)?

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
        messagePreview.model.onClose = { [weak self] in self?.closeAndClear() }
        messagePreview.model.onRegenerate = { [weak self] clarification in
            guard let self, let transcript = self.rawTranscript ?? self.untranslatedText else { return }
            if !clarification.isEmpty { self.messageClarification += "\n" + clarification }
            self.transcriptionTask?.cancel()
            let id = self.sessionID
            self.transcriptionTask = Task { await self.prepareMessage(transcript, session: id, useAI: true) }
        }
        messagePreview.model.onCopy = { [weak self] text in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            if !self.messagePreview.model.draft.isEmpty { self.pendingTranscript = self.messagePreview.model.draft }
            self.remember(self.messagePreview.model.draft.isEmpty ? text : self.messagePreview.model.draft, kind: .message, status: "Copied")
            self.messagePreview.model.notice = "Copied - press ⌘V"
        }
        messagePreview.model.onInsert = { [weak self] text in
            guard let self, let target = self.target else { return }
            self.pendingTranscript = text
            self.remember(text, kind: .message, status: "Insertion requested")
            let id = self.sessionID
            self.transcriptionTask = Task {
                self.messagePreview.model.busy = true
                let inserted = await SelectionTextWorker.shared.insertDictation(text, into: target, reactivate: self.canReactivateOriginalApp)
                guard self.sessionID == id, !Task.isCancelled else { return }
                self.messagePreview.model.busy = false
                if inserted {
                    self.remember(text, kind: .message, status: "Inserted")
                    self.closeAndClear()
                } else { self.messagePreview.model.notice = "Could not insert into the original field. Copy the draft and press ⌘V in your chosen field." }
            }
        }
    }

    func handle(_ phase: TextoraHotKeyPhase) {
        switch recordingSession.shortcut(phase, mode: OfflineDictationSettings.shortcutMode) {
        case .start: begin(source: .hotKey)
        case .stop: finishRecording()
        case .none: break
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
        recordingSession.cancel()
        recorder.cancel()
        messagePreview.model.invalidate()
        messagePreview.hide()
        stopTimerAndMonitors()
        target = nil
        origin = nil
        onDestinationChanged?(false)
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
        recordingSession.cancel(resetShortcut: true)
        transcriber.unload()
    }

    private func begin(source: TriggerSource) {
        guard OfflineDictationSettings.isEnabled, !isPressed, !isBusy else { return }
        sessionID = UUID()
        target = nil; origin = nil
        panel.updateLevel(0); panel.updateElapsed(0)
        panel.setCopyOnly(false); onDestinationChanged?(false)
        messagePreview.model.draft = ""
        messagePreview.model.draftUsesAI = false
        messagePreview.model.aiWasRequested = false
        messagePreview.model.questions = []
        messagePreview.model.clarification = ""
        historyToken = RecentResults.shared.consentToken
        messageClarification = ""
        translationSettings = .load()
        rawTranscript = nil
        untranslatedText = nil
        needsTranslationRetry = false
        triggerSource = source
        recordingSession.begin(id: sessionID, shortcutMode: source == .hotKey ? OfflineDictationSettings.shortcutMode : nil)
        if source == .miniMicrophone {
            onMiniMicrophoneStateChanged?(.preparing)
        } else {
            panel.show(state: .preparing, language: language, anchor: nil)
        }
        setBusy(true)
        guard textAccess.hasAccessibilityPermission() else {
            recordingSession.cancel()
            setBusy(false)
            onNeedsAccessibility?()
            return
        }
        installEscapeMonitors()
        let session = sessionID
        transcriptionTask = Task { await prepareRecording(source: source, session: session) }
    }

    private func prepareRecording(source: TriggerSource, session: UUID) async {
        let captured = await SelectionTextWorker.shared.dictationTarget()
        guard sessionID == session, isPressed, !Task.isCancelled else { return }
        switch captured {
        case .permissionRequired(let bundleID, let anchor):
            recordingSession.cancel()
            setBusy(false)
            onConsentRequired?(anchor, bundleID)
            return
        case .secureField:
            recordingSession.cancel()
            setBusy(false)
            showTemporaryMessage("Dictation is unavailable in secure fields.", isError: true)
            return
        case .permissionDenied:
            recordingSession.cancel()
            setBusy(false)
            showTemporaryMessage("Textora access is disabled for this app. Enable it in Settings.", isError: true)
            return
        case .unavailable:
            recordingSession.cancel()
            setBusy(false)
            showTemporaryMessage("Place the cursor in an editable text field.", isError: true)
            return
        case .success(let target):
            self.target = target
            origin = TextAccessService.DictationOrigin(appPID: target.appPID, bundleID: target.bundleID, anchor: target.anchor)
        case .copyOnly(let origin):
            self.origin = origin
            target = nil
            panel.setCopyOnly(true)
            onDestinationChanged?(true)
        }
        guard case .ready = modelManager.state else {
            recordingSession.cancel()
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
        let anchor = resultAnchor
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
                self.recordingSession.cancel()
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
            guard isPressed, sessionID == session, !Task.isCancelled, recordingSession.didStart(id: session) else {
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
            recordingSession.cancel()
            setBusy(false)
            showTemporaryMessage(error.localizedDescription, isError: true)
        }
    }

    private func finishRecording() {
        guard isPressed else { return }
        guard let options = recordingSession.stop(options: .load()) else {
            transcriptionTask?.cancel()
            recorder.cancel()
            target = nil
            origin = nil
            onDestinationChanged?(false)
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
        invalidateTemporaryMessages()
        sessionOutput = options.outputMode
        translationSettings = options.translation
        sessionStyle = PersonalStyleStore.shared.profile(for: origin?.bundleID)
        let target = target
        if triggerSource == .miniMicrophone {
            onMiniMicrophoneStateChanged?(.transcribing)
        } else {
            panel.show(state: .transcribing, language: language, anchor: resultAnchor)
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
                guard self.sessionID == id, !Task.isCancelled, OfflineDictationSettings.isEnabled else { return }
                self.rawTranscript = text
                self.untranslatedText = GeneratedTextStyle.shortDashes(text)
                if self.sessionOutput == .message {
                    await self.prepareMessage(text, session: id, useAI: self.translationSettings.enabled)
                    return
                }
                self.needsTranslationRetry = self.translationSettings.enabled
                let output = GeneratedTextStyle.shortDashes(try await self.translateIfNeeded(text))
                guard self.sessionID == id, !Task.isCancelled else { return }
                self.needsTranslationRetry = false
                self.pendingTranscript = output
                self.remember(output, kind: .dictation)
                guard let target else {
                    self.showCopyOnlyResult(output)
                    return
                }
                self.showProgress("Inserting…")
                if await SelectionTextWorker.shared.insertDictation(output, into: target, reactivate: self.canReactivateOriginalApp) {
                    guard self.sessionID == id, !Task.isCancelled else { return }
                    self.remember(output, kind: .dictation, status: "Inserted")
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
                    self.remember(original, kind: .dictation, status: "Translation failed")
                    self.onMiniMicrophoneStateChanged?(.hidden)
                    self.panel.show(state: .result(original), language: self.language, anchor: self.resultAnchor)
                    self.panel.setResultMessage("Translation failed: \(error.localizedDescription). Copy the original or retry translation.", retryTitle: "Retry Translation", canRetry: true)
                    return
                }
                self.target = nil
                self.setBusy(false)
                self.showTemporaryMessage(error.localizedDescription, isError: true, duration: 3)
            }
        }
    }

    private func remember(_ output: String, kind: OperationResult.Kind, status: String = "Ready") {
        let appliedStyle = kind == .message ? messagePreview.model.draftUsesAI : translationSettings.enabled
        RecentResults.shared.record(OperationResult(id: sessionID, kind: kind, source: rawTranscript ?? untranslatedText ?? output,
            result: output, application: OriginApplication.name(origin?.bundleID),
            language: translationSettings.enabled ? translationSettings.target.displayName : nil,
            style: appliedStyle ? sessionStyle?.name : nil, status: status), token: historyToken)
    }

    private func prepareMessage(_ transcript: String, session: UUID, useAI: Bool) async {
        guard sessionID == session, !Task.isCancelled else { return }
        messageGeneration += 1
        let generation = messageGeneration
        panel.hide()
        onMiniMicrophoneStateChanged?(.hidden)
        messagePreview.model.canInsert = target != nil
        messagePreview.show(transcript: transcript, style: sessionStyle?.name,
                            language: translationSettings.enabled ? translationSettings.target.displayName : nil)
        let response = await messagePreview.model.prepare(transcript: transcript, useAI: useAI) {
            try await AIClient().composeMessage(transcript: transcript, style: sessionStyle,
                targetLanguage: translationSettings.enabled ? translationSettings.target.displayName : nil,
                clarification: messageClarification)
        }
        guard sessionID == session, generation == messageGeneration, !Task.isCancelled else { return }
        if let response {
            if !response.draft.isEmpty {
                pendingTranscript = response.draft
                remember(response.draft, kind: .message, status: useAI ? "AI draft" : "Local draft")
            } else { remember(transcript, kind: .message, status: "Meaning clarification needed") }
        } else { remember(transcript, kind: .message, status: "Message preparation failed") }
    }

    private func translateIfNeeded(_ text: String) async throws -> String {
        guard translationSettings.enabled else { return text }
        showProgress("Translating…")
        guard let config = SelectionAssistantViewModel.providerConfiguration() else {
            throw NSError(domain: "Textora", code: 43, userInfo: [NSLocalizedDescriptionKey: "Add an AI key in Settings."])
        }
        let result = try await AIClient().translateText(provider: config.provider, model: config.model, apiKey: config.key,
            text: text, targetLanguage: translationSettings.target.displayName, sourceLanguage: translationSettings.sourceLanguageName, style: sessionStyle)
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "Textora", code: 44, userInfo: [NSLocalizedDescriptionKey: "Empty translation."])
        }
        return result
    }

    private func showProgress(_ title: String) {
        if triggerSource == .miniMicrophone { onMiniMicrophoneStateChanged?(.message(title, isError: false)) }
        else { panel.show(state: .message(title, isError: false), language: language, anchor: resultAnchor) }
    }

    private func showCopyOnlyResult(_ text: String) {
        pendingTranscript = text
        onMiniMicrophoneStateChanged?(.hidden)
        panel.setCopyOnly(true)
        panel.show(state: .result(text), language: language, anchor: resultAnchor)
        panel.setResultMessage("Ready to copy. Place the cursor in your chosen field and paste with ⌘V.", retryTitle: "Retry Insert", canRetry: false)
    }

    private func retryResult() {
        transcriptionTask?.cancel()
        let id = sessionID
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            if self.needsTranslationRetry, let original = self.untranslatedText {
                do {
                    let result = GeneratedTextStyle.shortDashes(try await self.translateIfNeeded(original))
                    guard self.sessionID == id, !Task.isCancelled else { return }
                    self.pendingTranscript = result
                    self.needsTranslationRetry = false
                    self.remember(result, kind: .dictation)
                    if self.target == nil { self.showCopyOnlyResult(result); return }
                    self.panel.show(state: .result(result), language: self.language, anchor: self.resultAnchor)
                } catch {
                    guard self.sessionID == id, !Task.isCancelled else { return }
                    self.panel.show(state: .result(original), language: self.language, anchor: self.resultAnchor)
                    self.panel.setResultMessage(error.localizedDescription, retryTitle: "Retry Translation", canRetry: true)
                    return
                }
            }
            await self.retryInsert()
        }
    }

    private func retryInsert() async {
        guard let text = pendingTranscript, let target else { return }
        let id = sessionID
        if await SelectionTextWorker.shared.insertDictation(text, into: target, reactivate: canReactivateOriginalApp) {
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
        let draft = messagePreview.model.draft
        if sessionOutput == .message, !messagePreview.model.busy, !draft.isEmpty, draft != pendingTranscript {
            remember(draft, kind: .message, status: "Draft saved")
        }
        messagePreview.model.invalidate()
        messagePreview.hide()
        sessionID = UUID()
        transcriptionTask?.cancel()
        pendingTranscript = nil
        target = nil
        origin = nil
        onDestinationChanged?(false)
        panel.hide()
        if triggerSource == .miniMicrophone {
            onMiniMicrophoneStateChanged?(.idle)
        }
        setBusy(false)
    }

    private func setBusy(_ value: Bool) {
        if !value {
            recordingSession.cancel()
            stopTimerAndMonitors()
        }
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
        installEscapeMonitors()
    }

    private func installEscapeMonitors() {
        guard localEscapeMonitor == nil, globalEscapeMonitor == nil else { return }
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { Task { @MainActor in self?.cancel() }; return nil }
            return event
        }
        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { Task { @MainActor in self?.cancel() } }
        }
    }

    private var canReactivateOriginalApp: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
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
