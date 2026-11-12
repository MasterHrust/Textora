import AppKit

/// Avoid synchronous AX requests to a host while it is processing typing.
final class BackgroundTextPollingGate: @unchecked Sendable {
    static let shared = BackgroundTextPollingGate()
    private let lock = NSLock()
    private var pausedUntil: TimeInterval = 0

    func pauseForTyping(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        pausedUntil = now + 0.8
        lock.unlock()
    }

    func resumeForSelection() {
        lock.lock()
        pausedUntil = 0
        lock.unlock()
    }

    func allowsPolling(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return now >= pausedUntil
    }

    static func isTypingKey(keyCode: UInt16, command: Bool, shift: Bool) -> Bool {
        // Select-all and selection extension must remain responsive.
        if command && keyCode == 0 { return false }
        if shift && [UInt16(115), 119, 123, 124, 125, 126].contains(keyCode) { return false }
        return keyCode != 53
    }
}

/// Serializes clipboard-based probes and replacements away from the animation
/// thread. AppKit-only operations inside TextAccessService marshal to main.
actor SelectionTextWorker {
    enum ReadIntent {
        case automatic
        case userInvoked
    }

    static let shared = SelectionTextWorker()
    private let service = TextAccessService()
    private let selectionReader: ((Bool) -> TextAccessService.FocusedTextContext?)?
    private let applicationWriter: ((String, TextAccessService.FocusedTextContext) -> TextAccessService.ApplyResult)?
    private let frontmostPID: () -> pid_t?

    init(selectionReader: ((Bool) -> TextAccessService.FocusedTextContext?)? = nil,
         applicationWriter: ((String, TextAccessService.FocusedTextContext) -> TextAccessService.ApplyResult)? = nil,
         frontmostPID: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }) {
        self.selectionReader = selectionReader
        self.applicationWriter = applicationWriter
        self.frontmostPID = frontmostPID
    }

    func signal() -> (selection: TextAccessService.SelectedTextSignal?, blocked: Bool) {
        guard BackgroundTextPollingGate.shared.allowsPolling() else { return (nil, false) }
        return service.withCoalescedFocusQueries {
            (service.selectedTextSignalAnyFocus(), service.shouldIgnoreCurrentFocusedInput())
        }
    }

    func microphonePlacement() -> TextAccessService.DictationMicPlacement? {
        guard BackgroundTextPollingGate.shared.allowsPolling() else { return nil }
        return service.withCoalescedFocusQueries { service.dictationMicPlacement() }
    }

    func dictationTarget() async -> TextAccessService.DictationTargetResult {
        guard let pid = frontmostPID(), let origin = service.frontmostAppInfo() else { return .unavailable }
        let result = await Self.resolveDictationTarget(
            read: { self.service.captureDictationTarget() },
            prepareAccessibility: { self.service.prepareDictationAccessibility(expectedPID: pid) },
            isOriginalAppActive: { self.frontmostPID() == pid },
            waitForAccessibility: { try? await Task.sleep(for: .milliseconds(150)) }
        )
        guard case .unavailable = result, !Task.isCancelled, frontmostPID() == pid else { return result }
        return service.captureCopyOnlyDictationOrigin(expectedPID: pid, expectedBundleID: origin.bundleID)
    }

    static func resolveDictationTarget(
        read: () -> TextAccessService.DictationTargetResult,
        prepareAccessibility: () -> Bool,
        isOriginalAppActive: () -> Bool,
        waitForAccessibility: () async -> Void
    ) async -> TextAccessService.DictationTargetResult {
        guard !Task.isCancelled, isOriginalAppActive() else { return .unavailable }
        let initial = read()
        guard case .unavailable = initial else { return initial }
        guard !Task.isCancelled, isOriginalAppActive(), prepareAccessibility() else { return .unavailable }
        // Electron creates its AX tree asynchronously. Retry reads only, with
        // a bounded wait and the original application pinned for this attempt.
        for _ in 0..<3 {
            await waitForAccessibility()
            guard !Task.isCancelled, isOriginalAppActive() else { return .unavailable }
            let result = read()
            if case .unavailable = result { continue }
            return result
        }
        return .unavailable
    }

    func insertDictation(_ text: String, into target: TextAccessService.DictationTarget, reactivate: Bool = false) async -> Bool {
        await service.insertDictatedText(text, into: target, reactivateTarget: reactivate)
    }

    func selection(intent: ReadIntent = .automatic) -> TextAccessService.FocusedTextContext? {
        let start = ProcessInfo.processInfo.systemUptime
        defer { InteractionTiming.record("selection-resolve", since: start) }
        guard !Task.isCancelled else { return nil }
        // Automatic detection must never borrow the user's clipboard or send
        // keyboard shortcuts: even a snapshot/restore races with ordinary paste.
        let allowClipboard = intent == .userInvoked
        if let selectionReader { return selectionReader(allowClipboard) }
        return service.selectedTextContextAnyFocus(minLength: 1, maxLength: 6000,
            allowClipboardFallback: allowClipboard, allowBrowserClipboardSelection: allowClipboard)
            .map { service.capturingInsertionIdentity($0) }
    }

    func apply(_ text: String, captured: TextAccessService.FocusedTextContext) -> TextAccessService.ApplyResult {
        let start = ProcessInfo.processInfo.systemUptime
        defer { InteractionTiming.record("selection-apply", since: start) }
        guard !Task.isCancelled, frontmostPID() == captured.targetAppPID else { return .rejected(.targetChanged) }
        // Prefer the same passive representation used by automatic previews.
        // A clipboard read can omit AX ranges and serialize emoji differently.
        // Only fall back when AX cannot read a selection, never when AX proves
        // that the selected text or field has changed.
        guard let fresh = selection() ?? selection(intent: .userInvoked) else { return .rejected(.selectionUnavailable) }
        guard !Task.isCancelled, frontmostPID() == captured.targetAppPID else { return .rejected(.targetChanged) }
        if let failure = Self.applicationContextFailure(captured: captured, fresh: fresh) { return .rejected(failure) }
        if let applicationWriter { return applicationWriter(text, fresh) }
        return service.applyRewrittenText(text, basedOn: fresh)
    }

    static func applicationContextFailure(captured: TextAccessService.FocusedTextContext,
                                          fresh: TextAccessService.FocusedTextContext) -> TextAccessService.ApplyFailureReason? {
        guard captured.targetAppPID == fresh.targetAppPID,
              captured.targetBundleID == fresh.targetBundleID,
              TextAccessService.sameInsertionTarget(captured, fresh) else { return .targetChanged }
        guard captured.usesSelection == fresh.usesSelection,
              !fresh.text.isEmpty,
              TextAccessService.canonicalApplyText(captured.text) == TextAccessService.canonicalApplyText(fresh.text) else { return .selectionChanged }
        if let before = captured.selectedRange, let after = fresh.selectedRange {
            guard before.location == after.location, before.length == after.length else { return .selectionChanged }
        } else if !captured.usesSelection,
                  (captured.selectedRange == nil) != (fresh.selectedRange == nil) {
            return .selectionChanged
        }
        // A missing AX range is not a changed selection. The insertion service
        // still verifies a fresh Cmd+C against this text before sending Cmd+V.
        return nil
    }
}
