import AppKit
import SwiftUI

@MainActor
final class SelectionAssistantController {
    private let textService = TextAccessService()
    private let viewModel = SelectionAssistantViewModel()
    private var panel: NSPanel?
    private var timer: Timer?
    private var pendingSelectionKey: String?
    private var pendingConsentKey: String?
    private var lockedAnchorKey: String?
    private var lockedAnchor: CGRect?
    private var suppressConsentPromptUntil: Date?
    private var selectionDebounceTask: DispatchWorkItem?
    private var fallbackResolveTask: DispatchWorkItem?
    private var lastFallbackProbeAt = Date.distantPast
    private var fallbackProbeAllowedUntil = Date.distantPast
    private var suppressSelectionUntil = Date.distantPast
    private var mouseDownPoint: CGPoint?
    private var didDragSinceMouseDown = false
    private var eventMonitorTokens: [Any] = []

    var onConsentRequired: ((CGRect, String) -> Void)?

    private static let panelWidth: CGFloat = 660

    func start() {
        SelectionAssistantSettings.registerDefaults()
        createPanelIfNeeded()
        installInputMonitorsIfNeeded()
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        selectionDebounceTask?.cancel()
        selectionDebounceTask = nil
        fallbackResolveTask?.cancel()
        fallbackResolveTask = nil
        removeInputMonitors()
        pendingSelectionKey = nil
        pendingConsentKey = nil
        lockedAnchorKey = nil
        lockedAnchor = nil
        fallbackProbeAllowedUntil = .distantPast
        suppressSelectionUntil = .distantPast
        mouseDownPoint = nil
        didDragSinceMouseDown = false
        viewModel.clear()
        panel?.orderOut(nil)
    }

    func refreshAfterConsentChange() {
        pendingConsentKey = nil
        pendingSelectionKey = nil
        lockedAnchorKey = nil
        lockedAnchor = nil
        tick()
    }

    func suppressConsentPromptBriefly() {
        suppressConsentPromptUntil = Date().addingTimeInterval(2.0)
        pendingConsentKey = nil
        pendingSelectionKey = nil
        panel?.orderOut(nil)
    }

    private func tick() {
        guard UserDefaults.standard.bool(forKey: SelectionAssistantSettings.Keys.enabled) else {
            stop()
            return
        }
        if Date() < suppressSelectionUntil {
            if !isMouseInsidePanel {
                let until = suppressSelectionUntil
                hideForNoSelection()
                suppressSelectionUntil = until
            }
            return
        }
        if isFrontmostBrowserLikeApp {
            if isMouseInsidePanel {
                return
            }
            guard canUseFallbackSelectionProbe else {
                if panel?.isVisible == true, pendingSelectionKey != nil {
                    return
                }
                hideForNoSelection()
                return
            }
            scheduleFallbackSelectionResolve()
            return
        }
        guard let signal = textService.selectedTextSignalAnyFocus(), signal.hasSelection else {
            if isMouseInsidePanel {
                return
            }
            guard canUseFallbackSelectionProbe else {
                hideForNoSelection()
                return
            }
            scheduleFallbackSelectionResolve()
            return
        }
        fallbackResolveTask?.cancel()
        fallbackResolveTask = nil

        let key = selectionKey(for: signal)
        let anchor = anchoredSelectionRect(for: key) ?? preferredAnchor(for: signal)
        rememberAnchor(anchor, for: key)

        switch textService.appConsentStatus(for: signal.targetBundleID) {
        case .allowed:
            pendingConsentKey = nil
        case .denied:
            hideForNoSelection()
            return
        case .unknown:
            hideForConsentRequired(signal: signal, anchor: anchor)
            return
        }

        showOrMovePanel(near: anchor)

        guard key != pendingSelectionKey else { return }
        pendingSelectionKey = key
        viewModel.prepareForSelectionMove()
        scheduleSelectionResolve(expectedKey: key)
    }

    private func hideForNoSelection() {
        selectionDebounceTask?.cancel()
        selectionDebounceTask = nil
        fallbackResolveTask?.cancel()
        fallbackResolveTask = nil
        pendingSelectionKey = nil
        pendingConsentKey = nil
        lockedAnchorKey = nil
        lockedAnchor = nil
        fallbackProbeAllowedUntil = .distantPast
        suppressSelectionUntil = .distantPast
        viewModel.clear()
        panel?.orderOut(nil)
    }

    private func hideForConsentRequired(signal: TextAccessService.SelectedTextSignal, anchor: CGRect) {
        selectionDebounceTask?.cancel()
        selectionDebounceTask = nil
        fallbackResolveTask?.cancel()
        fallbackResolveTask = nil
        pendingSelectionKey = nil
        viewModel.clear()
        panel?.orderOut(nil)

        if let suppressConsentPromptUntil, suppressConsentPromptUntil > Date() {
            return
        }
        let key = consentKey(for: signal)
        guard key != pendingConsentKey else { return }
        pendingConsentKey = key
        onConsentRequired?(anchor, signal.targetBundleID)
    }

    private func scheduleSelectionResolve(expectedKey: String) {
        selectionDebounceTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.pendingSelectionKey == expectedKey else { return }
                guard let context = self.textService.selectedTextContextAnyFocus(
                    minLength: 1,
                    maxLength: 6000,
                    allowClipboardFallback: true,
                    allowBrowserClipboardSelection: true
                ) else {
                    self.viewModel.clear()
                    return
                }
                let anchor = self.anchoredSelectionRect(for: expectedKey) ?? self.preferredAnchor(for: context)
                self.rememberAnchor(anchor, for: expectedKey)
                self.showOrMovePanel(near: anchor)
                self.viewModel.setSelectionContext(context)
            }
        }
        selectionDebounceTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
    }

    private func scheduleFallbackSelectionResolve() {
        guard canUseFallbackSelectionProbe else { return }
        guard fallbackResolveTask == nil else { return }
        guard Date().timeIntervalSince(lastFallbackProbeAt) > 0.45 else { return }
        let task = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.fallbackResolveTask = nil
                self.lastFallbackProbeAt = Date()
                guard UserDefaults.standard.bool(forKey: SelectionAssistantSettings.Keys.enabled) else {
                    self.stop()
                    return
                }
                guard self.canUseFallbackSelectionProbe else {
                    self.hideForNoSelection()
                    return
                }
                if let app = self.textService.frontmostAppInfo() {
                    switch self.textService.appConsentStatus(for: app.bundleID) {
                    case .allowed:
                        break
                    case .denied:
                        self.hideForNoSelection()
                        return
                    case .unknown:
                        self.fallbackProbeAllowedUntil = .distantPast
                        self.onConsentRequired?(self.mouseAnchor(), app.bundleID)
                        return
                    }
                }
                guard let context = self.textService.selectedTextContextAnyFocus(
                    minLength: 1,
                    maxLength: 6000,
                    allowClipboardFallback: true,
                    allowBrowserClipboardSelection: true
                ) else {
                    self.hideForNoSelection()
                    return
                }
                self.fallbackProbeAllowedUntil = .distantPast
                let key = self.selectionKey(for: context)
                let anchor = self.anchoredSelectionRect(for: key) ?? self.preferredAnchor(for: context)
                self.rememberAnchor(anchor, for: key)
                self.showOrMovePanel(near: anchor)
                guard key != self.pendingSelectionKey else {
                    self.viewModel.setSelectionContext(context)
                    return
                }
                self.pendingSelectionKey = key
                self.viewModel.prepareForSelectionMove()
                self.viewModel.setSelectionContext(context)
            }
        }
        fallbackResolveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: task)
    }

    private var canUseFallbackSelectionProbe: Bool {
        Date() <= fallbackProbeAllowedUntil
    }

    private func installInputMonitorsIfNeeded() {
        guard eventMonitorTokens.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleSelectionGestureEvent(event)
            }
        }
        if let global {
            eventMonitorTokens.append(global)
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleSelectionGestureEvent(event)
            }
            return event
        }
        if let local {
            eventMonitorTokens.append(local)
        }
    }

    private func removeInputMonitors() {
        for token in eventMonitorTokens {
            NSEvent.removeMonitor(token)
        }
        eventMonitorTokens.removeAll()
    }

    private func handleSelectionGestureEvent(_ event: NSEvent) {
        guard UserDefaults.standard.bool(forKey: SelectionAssistantSettings.Keys.enabled) else { return }
        switch event.type {
        case .leftMouseDown:
            let clickedInsidePanel = isMouseInsidePanel
            if panel?.isVisible == true, !clickedInsidePanel {
                hideForNoSelection()
            }
            if !clickedInsidePanel {
                suppressSelectionUntil = Date().addingTimeInterval(0.35)
            }
            mouseDownPoint = event.locationInWindow
            didDragSinceMouseDown = false
        case .leftMouseDragged:
            if let mouseDownPoint {
                let dx = event.locationInWindow.x - mouseDownPoint.x
                let dy = event.locationInWindow.y - mouseDownPoint.y
                didDragSinceMouseDown = sqrt(dx * dx + dy * dy) > 4
            } else {
                didDragSinceMouseDown = true
            }
            if didDragSinceMouseDown {
                suppressSelectionUntil = .distantPast
            }
        case .leftMouseUp:
            if didDragSinceMouseDown {
                allowFallbackProbeBriefly()
            } else {
                suppressSelectionUntil = Date().addingTimeInterval(0.35)
            }
            mouseDownPoint = nil
            didDragSinceMouseDown = false
        case .keyDown:
            let isCommandA = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
                && event.charactersIgnoringModifiers?.lowercased() == "a"
            if isCommandA {
                allowFallbackProbeBriefly()
            }
        default:
            break
        }
    }

    private func allowFallbackProbeBriefly() {
        fallbackProbeAllowedUntil = Date().addingTimeInterval(1.0)
    }

    private var isFrontmostBrowserLikeApp: Bool {
        guard let bundleID = textService.frontmostAppInfo()?.bundleID.lowercased() else { return false }
        return bundleID == "com.google.chrome"
            || bundleID == "com.apple.safari"
            || bundleID.contains("chrome")
            || bundleID.contains("firefox")
            || bundleID.contains("brave")
            || bundleID.contains("opera")
            || bundleID.contains("arc")
            || bundleID == "company.thebrowser.browser"
    }

    private func createPanelIfNeeded() {
        guard panel == nil else { return }
        let root = SelectionToolbarView(viewModel: viewModel) { [weak self] in
            guard let self else { return }
            self.viewModel.apply { [weak self] in
                self?.panel?.orderOut(nil)
            }
        }
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: currentPanelSize)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: currentPanelSize),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.panel = panel
    }

    private func showOrMovePanel(near anchor: CGRect) {
        createPanelIfNeeded()
        guard let panel else { return }
        let size = currentPanelSize
        panel.contentView?.frame = NSRect(origin: .zero, size: size)
        let frame = panelFrame(near: anchor, size: size)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
        if !panel.isVisible {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
    }

    private var currentPanelSize: CGSize {
        if viewModel.isLanguagePickerExpanded {
            return CGSize(width: Self.panelWidth, height: 132)
        }
        return CGSize(width: Self.panelWidth, height: viewModel.showsTranslationPanel ? 164 : 50)
    }

    private var isMouseInsidePanel: Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.frame.insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation)
    }

    private func panelFrame(near anchor: CGRect, size: CGSize) -> CGRect {
        let gap: CGFloat = 8
        var frame = CGRect(
            x: anchor.midX - size.width / 2,
            y: anchor.maxY + gap,
            width: size.width,
            height: size.height
        )
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(anchor) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return frame }
        let pad: CGFloat = 8
        if frame.maxY > visible.maxY - pad {
            frame.origin.y = anchor.minY - gap - frame.height
        }
        frame.origin.x = min(max(frame.origin.x, visible.minX + pad), visible.maxX - frame.width - pad)
        frame.origin.y = min(max(frame.origin.y, visible.minY + pad), visible.maxY - frame.height - pad)
        return frame
    }

    private func preferredAnchor(for signal: TextAccessService.SelectedTextSignal) -> CGRect {
        if shouldPreferMouseAnchor(bundleID: signal.targetBundleID, candidate: signal.bounds) {
            return mouseAnchor()
        }
        if let bounds = signal.bounds, isUsableAnchor(bounds) {
            return bounds
        }
        return mouseAnchor()
    }

    private func preferredAnchor(for context: TextAccessService.FocusedTextContext) -> CGRect {
        let anchor = context.anchor.rect
        if shouldPreferMouseAnchor(bundleID: context.targetBundleID, candidate: anchor) {
            return mouseAnchor()
        }
        if isUsableAnchor(anchor), context.anchor.confidence != .weak {
            return anchor
        }
        if isUsableAnchor(context.frame) {
            return context.frame
        }
        return mouseAnchor()
    }

    private func shouldPreferMouseAnchor(bundleID: String, candidate: CGRect?) -> Bool {
        guard usesWeakSelectionGeometry(bundleID: bundleID) else { return false }
        guard let candidate, isUsableAnchor(candidate) else { return true }
        if candidate.height > 90 || candidate.width > 1_800 {
            return true
        }
        let mouse = NSEvent.mouseLocation
        return !candidate.insetBy(dx: -160, dy: -140).contains(mouse)
    }

    private func usesWeakSelectionGeometry(bundleID: String) -> Bool {
        bundleID == "com.tinyspeck.slackmacgap"
            || bundleID == "com.google.Chrome"
            || bundleID == "com.google.Chrome.beta"
            || bundleID == "com.google.Chrome.canary"
            || bundleID == "com.apple.Safari"
            || bundleID == "com.microsoft.edgemac"
            || bundleID == "com.brave.Browser"
            || bundleID == "company.thebrowser.Browser"
            || bundleID.lowercased().contains("firefox")
            || bundleID.lowercased().contains("opera")
            || bundleID.lowercased().contains("arc")
    }

    private func isUsableAnchor(_ rect: CGRect) -> Bool {
        !rect.isNull
            && !rect.isInfinite
            && rect.width > 0
            && rect.height > 0
            && rect.minX.isFinite
            && rect.minY.isFinite
    }

    private func mouseAnchor() -> CGRect {
        CGRect(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y, width: 1, height: 1)
    }

    private func anchoredSelectionRect(for key: String) -> CGRect? {
        lockedAnchorKey == key ? lockedAnchor : nil
    }

    private func rememberAnchor(_ anchor: CGRect, for key: String) {
        lockedAnchorKey = key
        lockedAnchor = anchor
    }

    private func selectionKey(for signal: TextAccessService.SelectedTextSignal) -> String {
        let range = signal.selectedRange.map { "\($0.location):\($0.length)" } ?? "nil"
        return [
            signal.targetBundleID,
            String(signal.targetAppPID),
            range
        ].joined(separator: "|")
    }

    private func selectionKey(for context: TextAccessService.FocusedTextContext) -> String {
        let range = context.selectedRange.map { "\($0.location):\($0.length)" } ?? "nil"
        return [
            context.targetBundleID,
            String(context.targetAppPID),
            range,
            context.text
        ].joined(separator: "|")
    }

    private func consentKey(for signal: TextAccessService.SelectedTextSignal) -> String {
        let range = signal.selectedRange.map { "\($0.location):\($0.length)" } ?? "nil"
        return [
            signal.targetBundleID,
            String(signal.targetAppPID),
            range
        ].joined(separator: "|")
    }
}
