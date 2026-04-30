import AppKit
import SwiftUI

@MainActor
final class InlineRewritePanelController {
    private var panel: NSPanel?
    private let viewModel = InlineRewriteViewModel()
    var onHoverChanged: ((Bool) -> Void)?
    var onActionInvoked: (() -> Void)?
    private var isProgrammaticPositioning = false
    private var userPinnedOpen = false
    private var didAttachMoveObserver = false

    /// Borderless + clear — avoids the “window inside a window” look from a hidden title bar.
    private static func configureRewriteSurface(_ panel: NSPanel) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    private static let rewritePanelWidth: CGFloat = 360
    private static let rewritePanelHeight: CGFloat = 420

    /// Places the panel above the floating helper bubble without covering it.
    private func frameAnchoredToFloatingBubble(anchor: CGRect) -> CGRect {
        let w = Self.rewritePanelWidth
        let h = Self.rewritePanelHeight
        let gap: CGFloat = 5
        let iconSafeRect = anchor.insetBy(dx: -6, dy: -6)

        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(anchor) }) ?? NSScreen.main else {
            return CGRect(x: anchor.midX - w / 2, y: anchor.maxY + gap, width: w, height: h)
        }
        let vf = screen.visibleFrame
        let pad: CGFloat = 8

        func clampX(_ rect: CGRect) -> CGRect {
            var r = rect
            r.origin.x = min(max(r.origin.x, vf.minX + pad), vf.maxX - r.width - pad)
            return r
        }

        /// Clamp X to the visible frame, but never by sliding *into* the icon safe rect.
        /// If clamping would cause an overlap, try shifting to the nearest non-overlapping side.
        func clampXAvoidingIcon(_ rect: CGRect) -> CGRect {
            var r = clampX(rect)
            guard r.intersects(iconSafeRect) else { return r }

            // Try to move to the right of the icon.
            let rightX = iconSafeRect.maxX + gap
            if rightX + r.width <= vf.maxX - pad {
                r.origin.x = rightX
                if !r.intersects(iconSafeRect) { return r }
            }

            // Try to move to the left of the icon.
            let leftX = iconSafeRect.minX - gap - r.width
            if leftX >= vf.minX + pad {
                r.origin.x = leftX
                if !r.intersects(iconSafeRect) { return r }
            }

            // If we can't avoid overlap horizontally, keep the clamped rect (caller will decide fallback).
            return r
        }

        func fitsVerticallyWithoutPushingDown(_ rect: CGRect) -> Bool {
            rect.minY >= vf.minY + pad && rect.maxY <= vf.maxY - pad
        }

        // Primary rule: popup bottom edge is 5px above icon top edge.
        let yAbove = anchor.maxY + gap

        // Try above placements first (never push down via Y-clamp, otherwise we can cover the icon).
        let aboveCandidates: [CGRect] = [
            CGRect(x: anchor.midX - w / 2, y: yAbove, width: w, height: h),
            // If icon is near a corner/edge, move sideways at the same gap.
            CGRect(x: anchor.maxX + gap, y: yAbove, width: w, height: h),
            CGRect(x: anchor.minX - gap - w, y: yAbove, width: w, height: h)
        ]
        for c in aboveCandidates {
            let xClamped = clampXAvoidingIcon(c)
            if fitsVerticallyWithoutPushingDown(xClamped), !xClamped.intersects(iconSafeRect) {
                return xClamped
            }
        }

        // If there's not enough vertical space above, keep the icon uncovered by moving the popup to the side.
        // (This keeps the icon draggable and avoids overlap.)
        let sideY = min(max(anchor.midY - h / 2, vf.minY + pad), vf.maxY - h - pad)
        let sideCandidates: [CGRect] = [
            CGRect(x: anchor.maxX + gap, y: sideY, width: w, height: h),
            CGRect(x: anchor.minX - gap - w, y: sideY, width: w, height: h)
        ]
        for c in sideCandidates {
            let xClamped = clampXAvoidingIcon(c)
            if !xClamped.intersects(iconSafeRect) {
                return xClamped
            }
        }

        // Last resort: clamp normally (may overlap in extreme cases).
        // Prefer keeping the icon clear; do not push the popup down on top of it.
        let last = clampedToVisibleScreens(CGRect(x: anchor.midX - w / 2, y: yAbove, width: w, height: h))
        if !last.intersects(iconSafeRect) {
            return last
        }
        // If even clamped placement overlaps, try a purely horizontal escape hatch at the clamped Y.
        let escapeRight = CGRect(x: iconSafeRect.maxX + gap, y: last.minY, width: w, height: h)
        let escapeLeft = CGRect(x: iconSafeRect.minX - gap - w, y: last.minY, width: w, height: h)
        let er = clampedToVisibleScreens(escapeRight)
        if !er.intersects(iconSafeRect) { return er }
        let el = clampedToVisibleScreens(escapeLeft)
        if !el.intersects(iconSafeRect) { return el }
        return last
    }

    private func clampedToVisibleScreens(_ rect: CGRect) -> CGRect {
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(rect) }) ?? NSScreen.main else {
            return rect
        }
        let vf = screen.visibleFrame
        let pad: CGFloat = 8
        var r = rect
        r.origin.x = min(max(r.origin.x, vf.minX + pad), vf.maxX - r.width - pad)
        r.origin.y = min(max(r.origin.y, vf.minY + pad), vf.maxY - r.height - pad)
        return r
    }

    /// `anchorRect` should be the floating helper’s `NSPanel.frame` so the pop-up reads as coming from the icon.
    func show(near anchorRect: CGRect, triggerRewrite: Bool = true) {
        // New showing session: not pinned unless user drags the popup itself.
        userPinnedOpen = false
        _ = viewModel.loadFromBestAvailable(minLength: 1)

        if panel == nil {
            let rootView = InlineRewriteView(
                viewModel: viewModel,
                onClose: { [weak self] in self?.hide() },
                onHoverChanged: { [weak self] hovering in self?.onHoverChanged?(hovering) },
                onActionInvoked: { [weak self] in self?.onActionInvoked?() }
            )
            let host = NSHostingView(rootView: rootView)
            host.wantsLayer = true
            host.layer?.backgroundColor = NSColor.clear.cgColor
            host.frame = NSRect(x: 0, y: 0, width: Self.rewritePanelWidth, height: Self.rewritePanelHeight)
            host.autoresizingMask = [.width, .height]
            let panel = NSPanel(
                contentRect: NSRect(
                    x: 0,
                    y: 0,
                    width: Self.rewritePanelWidth,
                    height: Self.rewritePanelHeight
                ),
                styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            Self.configureRewriteSurface(panel)
            // Drag is enabled; actual draggable area is provided by a view that returns
            // `mouseDownCanMoveWindow = true` (see `PopupWindowDragHandle`).
            panel.isMovableByWindowBackground = true
            panel.contentView = host
            self.panel = panel
            attachMoveObserverIfNeeded()
        }

        let frame = frameAnchoredToFloatingBubble(anchor: anchorRect)
        isProgrammaticPositioning = true
        panel?.setFrame(frame, display: true)
        isProgrammaticPositioning = false
        panel?.contentView?.layoutSubtreeIfNeeded()
        panel?.alphaValue = 1
        panel?.orderFrontRegardless()
        if triggerRewrite {
            viewModel.triggerRewrite(.popupOpened)
        }
    }

    func showWithSuggestion(
        near anchorRect: CGRect,
        context: TextAccessService.FocusedTextContext,
        suggestion: String,
        operation: RewriteOperation
    ) {
        userPinnedOpen = false
        viewModel.setPrefilled(context: context, suggestion: suggestion, operation: operation)
        if panel == nil {
            let rootView = InlineRewriteView(
                viewModel: viewModel,
                onClose: { [weak self] in self?.hide() },
                onHoverChanged: { [weak self] hovering in self?.onHoverChanged?(hovering) },
                onActionInvoked: { [weak self] in self?.onActionInvoked?() }
            )
            let host = NSHostingView(rootView: rootView)
            host.wantsLayer = true
            host.layer?.backgroundColor = NSColor.clear.cgColor
            host.frame = NSRect(x: 0, y: 0, width: Self.rewritePanelWidth, height: Self.rewritePanelHeight)
            host.autoresizingMask = [.width, .height]
            let panel = NSPanel(
                contentRect: NSRect(
                    x: 0,
                    y: 0,
                    width: Self.rewritePanelWidth,
                    height: Self.rewritePanelHeight
                ),
                styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            Self.configureRewriteSurface(panel)
            panel.isMovableByWindowBackground = true
            panel.contentView = host
            self.panel = panel
            attachMoveObserverIfNeeded()
        }

        let frame = frameAnchoredToFloatingBubble(anchor: anchorRect)
        isProgrammaticPositioning = true
        panel?.setFrame(frame, display: true)
        isProgrammaticPositioning = false
        panel?.contentView?.layoutSubtreeIfNeeded()
        panel?.alphaValue = 1
        panel?.orderFrontRegardless()
    }

    func hide() {
        let hoverChanged = onHoverChanged
        guard let panel, panel.isVisible else {
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 0
        } completionHandler: {
            // Completion handler can be treated as `@Sendable`; hop to MainActor.
            Task { @MainActor in
                panel.orderOut(nil)
                panel.alphaValue = 1
                self.userPinnedOpen = false
                hoverChanged?(false)
            }
        }
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    var currentFrame: CGRect? {
        panel?.frame
    }

    var window: NSWindow? {
        panel
    }

    var isPinnedOpen: Bool {
        userPinnedOpen
    }

    private func attachMoveObserverIfNeeded() {
        guard !didAttachMoveObserver else { return }
        didAttachMoveObserver = true
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            // The observer closure is `@Sendable`; hop to MainActor before touching isolated state.
            Task { @MainActor in
                guard let self else { return }
                guard self.panel?.isVisible == true else { return }
                guard !self.isProgrammaticPositioning else { return }
                self.userPinnedOpen = true
            }
        }
    }
}
