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
    private var stableSelectionKey: String?
    private var stableSelectionAnchor: CGRect?
    private var lastSelectionGestureAnchor: CGRect?
    private var lockedPanelPlacementSide: PanelPlacementSide?
    private var suppressConsentPromptUntil: Date?
    private var selectionDebounceTask: DispatchWorkItem?
    private var fallbackResolveTask: DispatchWorkItem?
    private var lastFallbackProbeAt = Date.distantPast
    private var fallbackProbeAllowedUntil = Date.distantPast
    private var suppressSelectionUntil = Date.distantPast
    private var ignoreCommandCUntil = Date.distantPast
    private var mouseDownPoint: CGPoint?
    private var didDragSinceMouseDown = false
    private var selectionGestureID = 0
    private var lastTraceSignature: String?
    private var eventMonitorTokens: [Any] = []
    private var commandAEventTap: CFMachPort?
    private var commandAEventTapSource: CFRunLoopSource?

    var onConsentRequired: ((CGRect, String) -> Void)?

    private static let panelWidth: CGFloat = 680
    private static let panelTopReserve: CGFloat = SelectionToolbarView.tooltipTopReserve
    private static let maxPanelContentHeight: CGFloat = 170

    private enum PanelPlacementSide {
        case above
        case below
    }

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
        stableSelectionKey = nil
        stableSelectionAnchor = nil
        lastSelectionGestureAnchor = nil
        lockedPanelPlacementSide = nil
        fallbackProbeAllowedUntil = .distantPast
        suppressSelectionUntil = .distantPast
        ignoreCommandCUntil = .distantPast
        mouseDownPoint = nil
        didDragSinceMouseDown = false
        selectionGestureID += 1
        lastTraceSignature = nil
        viewModel.clear()
        panel?.orderOut(nil)
    }

    func refreshAfterConsentChange() {
        pendingConsentKey = nil
        pendingSelectionKey = nil
        lockedAnchorKey = nil
        lockedAnchor = nil
        stableSelectionKey = nil
        stableSelectionAnchor = nil
        lastSelectionGestureAnchor = nil
        lockedPanelPlacementSide = nil
        selectionGestureID += 1
        lastTraceSignature = nil
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
            if let signal = textService.selectedTextSignalAnyFocus(), signal.hasSelection {
                trace("tick browser signal", signal: signal, key: selectionKey(for: signal))
                handleSelectionSignal(signal)
                return
            }
            guard canUseFallbackSelectionProbe else {
                if panel?.isVisible == true, pendingSelectionKey != nil {
                    return
                }
                hideForNoSelection()
                return
            }
            trace("tick browser fallback")
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
        handleSelectionSignal(signal)
    }

    private func handleSelectionSignal(_ signal: TextAccessService.SelectedTextSignal) {
        fallbackResolveTask?.cancel()
        fallbackResolveTask = nil

        let key = selectionKey(for: signal)
        let anchor = anchorForCurrentSelection(
            key: key,
            preferred: preferredAnchor(for: signal),
            allowStableAnchor: true
        )
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

        if panel?.isVisible == true, pendingSelectionKey == key {
            trace("signal same move", signal: signal, key: key)
            showOrMovePanel(near: anchor)
        }

        guard key != pendingSelectionKey else {
            trace("signal ignored same", signal: signal, key: key)
            return
        }
        trace(
            "signal new",
            signal: signal,
            key: key,
            extra: "pending=\(pendingSelectionKey ?? "nil")"
        )
        pendingSelectionKey = key
        viewModel.prepareForSelectionMove()
        scheduleSelectionResolve(expectedKey: key, keepPendingKey: true)
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
        stableSelectionKey = nil
        stableSelectionAnchor = nil
        lastSelectionGestureAnchor = nil
        lockedPanelPlacementSide = nil
        fallbackProbeAllowedUntil = .distantPast
        suppressSelectionUntil = .distantPast
        viewModel.clear()
        panel?.orderOut(nil)
        trace("hide no selection")
    }

    private func hideForConsentRequired(signal: TextAccessService.SelectedTextSignal, anchor: CGRect) {
        selectionDebounceTask?.cancel()
        selectionDebounceTask = nil
        fallbackResolveTask?.cancel()
        fallbackResolveTask = nil
        pendingSelectionKey = nil
        lockedAnchorKey = nil
        lockedAnchor = nil
        stableSelectionKey = nil
        stableSelectionAnchor = nil
        lastSelectionGestureAnchor = nil
        lockedPanelPlacementSide = nil
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

    private func scheduleSelectionResolve(expectedKey: String, keepPendingKey: Bool = false) {
        selectionDebounceTask?.cancel()
        trace("resolve scheduled", key: expectedKey, extra: "keepPending=\(keepPendingKey)")
        let task = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.pendingSelectionKey == expectedKey else {
                    self.trace(
                        "resolve skipped stale",
                        key: expectedKey,
                        extra: "pending=\(self.pendingSelectionKey ?? "nil")"
                    )
                    return
                }
                guard Date() >= self.suppressSelectionUntil else {
                    self.trace("resolve skipped suppressed", key: expectedKey)
                    return
                }
                let context = self.readSelectedTextContextForToolbar()
                guard let context else {
                    self.trace("resolve no context", key: expectedKey)
                    self.viewModel.clear()
                    return
                }
                let anchor = self.anchorForCurrentSelection(
                    key: expectedKey,
                    preferred: self.preferredAnchor(for: context),
                    allowStableAnchor: true
                )
                self.rememberAnchor(anchor, for: expectedKey)
                self.showOrMovePanel(near: anchor)
                if !keepPendingKey {
                    self.pendingSelectionKey = self.selectionKey(for: context)
                }
                self.trace(
                    "resolve context",
                    context: context,
                    key: expectedKey,
                    extra: "keepPending=\(keepPendingKey)"
                )
                self.viewModel.setSelectionContext(context)
            }
        }
        selectionDebounceTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
    }

    private func readSelectedTextContextForToolbar() -> TextAccessService.FocusedTextContext? {
        ignoreCommandCUntil = Date().addingTimeInterval(1.25)
        let context = textService.selectedTextContextAnyFocus(
                    minLength: 1,
                    maxLength: 6000,
                    allowClipboardFallback: true,
                    allowBrowserClipboardSelection: true
        )
        ignoreCommandCUntil = Date().addingTimeInterval(0.45)
        return context
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
                guard Date() >= self.suppressSelectionUntil else {
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
                guard let context = self.readSelectedTextContextForToolbar() else {
                    self.trace("fallback no context")
                    self.hideForNoSelection()
                    return
                }
                self.fallbackProbeAllowedUntil = .distantPast
                let key = self.selectionKey(for: context)
                let anchor = self.anchorForCurrentSelection(
                    key: key,
                    preferred: self.preferredAnchor(for: context),
                    allowStableAnchor: true
                )
                self.rememberAnchor(anchor, for: key)
                self.showOrMovePanel(near: anchor)
                guard key != self.pendingSelectionKey else {
                    self.trace("fallback same context", context: context, key: key)
                    self.viewModel.setSelectionContext(context)
                    return
                }
                self.trace(
                    "fallback new context",
                    context: context,
                    key: key,
                    extra: "pending=\(self.pendingSelectionKey ?? "nil")"
                )
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

    private var isMouseSelectionDragActive: Bool {
        mouseDownPoint != nil && didDragSinceMouseDown
    }

    private func installInputMonitorsIfNeeded() {
        guard eventMonitorTokens.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .keyDown]
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
        installCommandAEventTapIfNeeded()
    }

    private func removeInputMonitors() {
        for token in eventMonitorTokens {
            NSEvent.removeMonitor(token)
        }
        eventMonitorTokens.removeAll()
        if let commandAEventTap {
            CGEvent.tapEnable(tap: commandAEventTap, enable: false)
        }
        if let commandAEventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), commandAEventTapSource, .commonModes)
        }
        commandAEventTap = nil
        commandAEventTapSource = nil
    }

    private func installCommandAEventTapIfNeeded() {
        guard commandAEventTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard type == .keyDown, let refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags
                guard flags.contains(.maskCommand) else {
                    return Unmanaged.passUnretained(event)
                }
                if keyCode == 0 || keyCode == 8 {
                    let controller = Unmanaged<SelectionAssistantController>
                        .fromOpaque(refcon)
                        .takeUnretainedValue()
                    Task { @MainActor in
                        if keyCode == 0 {
                            controller.resetResolvedSelectionState()
                            controller.beginNewSelectionGesture("cmdA")
                            controller.allowFallbackProbeBriefly()
                        } else {
                            controller.handleCommandCEvent()
                        }
                    }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            return
        }
        commandAEventTap = tap
        commandAEventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
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
            lastSelectionGestureAnchor = nil
            mouseDownPoint = event.locationInWindow
            didDragSinceMouseDown = false
        case .rightMouseDown:
            suppressForContextMenu()
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
                lastSelectionGestureAnchor = mouseAnchor()
                beginNewSelectionGesture("mouseDrag")
                allowFallbackProbeBriefly()
            } else {
                suppressSelectionUntil = Date().addingTimeInterval(0.35)
            }
            mouseDownPoint = nil
            didDragSinceMouseDown = false
        case .keyDown:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isCommandA = flags.contains(.command)
                && (event.charactersIgnoringModifiers?.lowercased() == "a" || event.keyCode == 0)
            let isCommandC = flags.contains(.command)
                && (event.charactersIgnoringModifiers?.lowercased() == "c" || event.keyCode == 8)
            if isCommandA {
                resetResolvedSelectionState()
                beginNewSelectionGesture("cmdA")
                allowFallbackProbeBriefly()
            } else if isCommandC {
                handleCommandCEvent()
            }
        default:
            break
        }
    }

    private func handleCommandCEvent() {
        guard Date() >= ignoreCommandCUntil else {
            trace("ignore internal copy")
            return
        }
        suppressForUserCopy()
    }

    private func suppressForUserCopy() {
        suppressSelectionUntil = Date().addingTimeInterval(1.25)
        selectionDebounceTask?.cancel()
        selectionDebounceTask = nil
        fallbackResolveTask?.cancel()
        fallbackResolveTask = nil
        pendingSelectionKey = nil
        pendingConsentKey = nil
        lockedPanelPlacementSide = nil
        viewModel.clear()
        panel?.orderOut(nil)
        trace("suppress copy")
    }

    private func suppressForContextMenu() {
        suppressSelectionUntil = Date().addingTimeInterval(0.9)
        selectionDebounceTask?.cancel()
        selectionDebounceTask = nil
        fallbackResolveTask?.cancel()
        fallbackResolveTask = nil
        pendingSelectionKey = nil
        pendingConsentKey = nil
        lockedPanelPlacementSide = nil
        viewModel.clear()
        panel?.orderOut(nil)
        trace("suppress context menu")
    }

    private func allowFallbackProbeBriefly() {
        fallbackProbeAllowedUntil = Date().addingTimeInterval(1.0)
    }

    private func beginNewSelectionGesture(_ reason: String) {
        selectionGestureID += 1
        lastTraceSignature = nil
        trace("gesture new", extra: "reason=\(reason) id=\(selectionGestureID)")
    }

    private func resetResolvedSelectionState() {
        pendingSelectionKey = nil
        pendingConsentKey = nil
        lockedAnchorKey = nil
        lockedAnchor = nil
        stableSelectionKey = nil
        stableSelectionAnchor = nil
        lockedPanelPlacementSide = nil
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
        let frame = panelFrame(near: anchor, size: size, lockPlacement: !isMouseSelectionDragActive)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
        if !panel.isVisible {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
    }

    private var currentPanelSize: CGSize {
        let contentHeight: CGFloat
        if viewModel.isLanguagePickerExpanded {
            contentHeight = 170
        } else {
            contentHeight = viewModel.showsTranslationPanel ? 164 : 50
        }
        return CGSize(width: Self.panelWidth, height: contentHeight + Self.panelTopReserve)
    }

    private var isMouseInsidePanel: Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.frame.insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation)
    }

    private func panelFrame(near anchor: CGRect, size: CGSize, lockPlacement: Bool) -> CGRect {
        let gap: CGFloat = viewModel.hasRewritePreview || viewModel.hasTranslationContent ? 34 : 18
        let contentSize = CGSize(width: size.width, height: max(1, size.height - Self.panelTopReserve))
        let placementContentHeight = max(contentSize.height, Self.maxPanelContentHeight)
        let contentX = anchor.midX - contentSize.width / 2
        var contentFrame = CGRect(
            x: contentX,
            y: anchor.maxY + gap,
            width: contentSize.width,
            height: contentSize.height
        )
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(anchor) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            return CGRect(origin: contentFrame.origin, size: size)
        }
        let pad: CGFloat = 8
        let aboveFrame = CGRect(
            x: anchor.midX - contentSize.width / 2,
            y: anchor.maxY + gap,
            width: contentSize.width,
            height: contentSize.height
        )
        let belowFrame = CGRect(
            x: anchor.midX - contentSize.width / 2,
            y: anchor.minY - gap - size.height,
            width: contentSize.width,
            height: contentSize.height
        )
        let aboveFits = anchor.maxY + gap + placementContentHeight + Self.panelTopReserve <= visible.maxY - pad
            && aboveFrame.minY >= visible.minY + pad
        let belowFits = anchor.minY - gap - placementContentHeight >= visible.minY + pad
            && belowFrame.maxY <= visible.maxY - pad

        let side: PanelPlacementSide
        if lockPlacement,
           let lockedPanelPlacementSide,
           (lockedPanelPlacementSide == .above ? aboveFits : belowFits) {
            side = lockedPanelPlacementSide
        } else if aboveFits {
            side = .above
        } else if belowFits {
            side = .below
        } else {
            let spaceAbove = visible.maxY - anchor.maxY - gap - Self.panelTopReserve
            let spaceBelow = anchor.minY - visible.minY - gap
            side = spaceAbove >= spaceBelow ? .above : .below
        }
        if lockPlacement {
            lockedPanelPlacementSide = side
        }
        contentFrame = side == .above ? aboveFrame : belowFrame
        contentFrame.origin.x = min(max(contentFrame.origin.x, visible.minX + pad), visible.maxX - contentFrame.width - pad)
        if side == .above {
            contentFrame.origin.y = min(contentFrame.origin.y, visible.maxY - contentFrame.height - Self.panelTopReserve - pad)
            contentFrame.origin.y = max(contentFrame.origin.y, anchor.maxY + gap)
        } else {
            contentFrame.origin.y = max(contentFrame.origin.y, visible.minY + pad)
            contentFrame.origin.y = min(contentFrame.origin.y, anchor.minY - gap - size.height)
        }
        return CGRect(
            x: contentFrame.minX,
            y: contentFrame.minY,
            width: size.width,
            height: size.height
        )
    }

    private func preferredAnchor(for signal: TextAccessService.SelectedTextSignal) -> CGRect {
        if shouldPreferMouseAnchor(bundleID: signal.targetBundleID, candidate: signal.bounds) {
            return fallbackInteractionAnchor()
        }
        if let bounds = signal.bounds, isUsableAnchor(bounds) {
            return bounds
        }
        return fallbackInteractionAnchor()
    }

    private func preferredAnchor(for context: TextAccessService.FocusedTextContext) -> CGRect {
        let anchor = context.anchor.rect
        if shouldPreferMouseAnchor(bundleID: context.targetBundleID, candidate: anchor) {
            return fallbackInteractionAnchor()
        }
        if isUsableAnchor(anchor), context.anchor.confidence != .weak {
            return anchor
        }
        if isUsableAnchor(context.frame) {
            return context.frame
        }
        return fallbackInteractionAnchor()
    }

    private func shouldPreferMouseAnchor(bundleID: String, candidate: CGRect?) -> Bool {
        guard usesWeakSelectionGeometry(bundleID: bundleID) else { return false }
        guard let candidate, isUsableAnchor(candidate) else { return true }
        if candidate.height > 90 || candidate.width > 1_800 {
            if !isMouseSelectionDragActive, candidate.height <= 320, candidate.width <= 1_600 {
                return false
            }
            return true
        }
        return false
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

    private func fallbackInteractionAnchor() -> CGRect {
        if isMouseSelectionDragActive {
            return mouseAnchor()
        }
        if let lastSelectionGestureAnchor {
            return lastSelectionGestureAnchor
        }
        return mouseAnchor()
    }

    private func anchorForCurrentSelection(
        key: String,
        preferred: CGRect,
        allowStableAnchor: Bool
    ) -> CGRect {
        if stableSelectionKey != nil, stableSelectionKey != key {
            stableSelectionKey = nil
            stableSelectionAnchor = nil
            lockedPanelPlacementSide = nil
        }
        if allowStableAnchor, stableSelectionKey == key, let stableSelectionAnchor {
            return stableSelectionAnchor
        }
        if isMouseSelectionDragActive {
            return preferred
        }
        if let locked = anchoredSelectionRect(for: key) {
            stableSelectionKey = key
            stableSelectionAnchor = locked
            return locked
        }
        stableSelectionKey = key
        stableSelectionAnchor = preferred
        return preferred
    }

    private func anchoredSelectionRect(for key: String) -> CGRect? {
        lockedAnchorKey == key ? lockedAnchor : nil
    }

    private func rememberAnchor(_ anchor: CGRect, for key: String) {
        guard !isMouseSelectionDragActive else { return }
        lockedAnchorKey = key
        lockedAnchor = anchor
    }

    private func selectionKey(for signal: TextAccessService.SelectedTextSignal) -> String {
        let range: String
        if usesWeakSelectionGeometry(bundleID: signal.targetBundleID) {
            range = "weak-selection-signal-\(selectionGestureID)"
        } else {
            range = signal.selectedRange.map { "\($0.location):\($0.length)" } ?? "nil"
        }
        return [
            signal.targetBundleID,
            String(signal.targetAppPID),
            range
        ].joined(separator: "|")
    }

    private func selectionKey(for context: TextAccessService.FocusedTextContext) -> String {
        let range: String
        if context.usesSelection,
           (usesWeakSelectionGeometry(bundleID: context.targetBundleID)
            || context.anchor.source == .clipboardFallback) {
            range = "text-selection"
        } else {
            range = context.selectedRange.map { "\($0.location):\($0.length)" } ?? "nil"
        }
        return [
            context.targetBundleID,
            String(context.targetAppPID),
            range,
            normalizedSelectionText(context.text)
        ].joined(separator: "|")
    }

    private func normalizedSelectionText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func consentKey(for signal: TextAccessService.SelectedTextSignal) -> String {
        let range = signal.selectedRange.map { "\($0.location):\($0.length)" } ?? "nil"
        return [
            signal.targetBundleID,
            String(signal.targetAppPID),
            range
        ].joined(separator: "|")
    }

    private func trace(
        _ event: String,
        signal: TextAccessService.SelectedTextSignal? = nil,
        context: TextAccessService.FocusedTextContext? = nil,
        key: String? = nil,
        extra: String = ""
    ) {
        guard SelectionAssistantSettings.diagnosticsEnabled() else { return }
        let textPart: String = {
            guard let context else { return "" }
            return " textLen=\((context.text as NSString).length) text=\(textoraDiagPreview(context.text, limit: 80))"
        }()
        let signalPart: String = {
            guard let signal else { return "" }
            return " bundle=\(signal.targetBundleID) pid=\(signal.targetAppPID) range=\(signal.selectedRange.map { "\($0.location):\($0.length)" } ?? "nil") bounds=\(textoraDiagRect(signal.bounds))"
        }()
        let contextPart: String = {
            guard let context else { return "" }
            return " bundle=\(context.targetBundleID) pid=\(context.targetAppPID) selectedRange=\(context.selectedRange.map { "\($0.location):\($0.length)" } ?? "nil") source=\(context.anchor.source.rawValue) confidence=\(context.anchor.confidence.rawValue)"
        }()
        let message = "\(event) id=\(selectionGestureID) key=\(key ?? "nil") pending=\(pendingSelectionKey ?? "nil") panel=\(panel?.isVisible == true)\(signalPart)\(contextPart)\(textPart)\(extra.isEmpty ? "" : " \(extra)")"
        let signature = "\(event)|\(key ?? "nil")|\(pendingSelectionKey ?? "nil")|\(signal?.selectedRange.map { "\($0.location):\($0.length)" } ?? "nil")|\(context.map { "\(($0.text as NSString).length):\($0.anchor.source.rawValue)" } ?? "nil")|\(extra)"
        guard signature != lastTraceSignature else { return }
        lastTraceSignature = signature
        textoraDiagLog("selectionAssistant", message)
    }
}
