import AppKit

/// Serializes clipboard-based probes and replacements away from the animation
/// thread. AppKit-only operations inside TextAccessService marshal to main.
actor SelectionTextWorker {
    static let shared = SelectionTextWorker()
    private let service = TextAccessService()

    func signal() -> (selection: TextAccessService.SelectedTextSignal?, blocked: Bool) {
        service.withCoalescedFocusQueries {
            (service.selectedTextSignalAnyFocus(), service.shouldIgnoreCurrentFocusedInput())
        }
    }

    func microphonePlacement() -> TextAccessService.DictationMicPlacement? {
        service.dictationMicPlacement()
    }

    func dictationTarget() -> TextAccessService.DictationTargetResult { service.captureDictationTarget() }

    func insertDictation(_ text: String, into target: TextAccessService.DictationTarget, reactivate: Bool = false) async -> Bool {
        await service.insertDictatedText(text, into: target, reactivateTarget: reactivate)
    }

    func selection() -> TextAccessService.FocusedTextContext? {
        let start = ProcessInfo.processInfo.systemUptime
        defer { InteractionTiming.record("selection-resolve", since: start) }
        guard !Task.isCancelled else { return nil }
        return service.selectedTextContextAnyFocus(minLength: 1, maxLength: 6000,
            allowClipboardFallback: true, allowBrowserClipboardSelection: true)
    }

    func apply(_ text: String, captured: TextAccessService.FocusedTextContext) -> TextAccessService.ApplyResult {
        let start = ProcessInfo.processInfo.systemUptime
        defer { InteractionTiming.record("selection-apply", since: start) }
        guard !Task.isCancelled, let fresh = selection(),
              CFEqual(captured.targetElement, fresh.targetElement),
              captured.selectedRange?.location == fresh.selectedRange?.location,
              captured.selectedRange?.length == fresh.selectedRange?.length,
              SelectionAssistantViewModel.fingerprint(for: captured) == SelectionAssistantViewModel.fingerprint(for: fresh),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == captured.targetAppPID,
              !Task.isCancelled else { return .unsupportedTarget }
        return service.applyRewrittenText(text, basedOn: fresh)
    }
}
