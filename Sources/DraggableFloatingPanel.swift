import AppKit

/// NSPanel subclass with smooth dragging + hover tracking that works even when the app isn't active.
/// SwiftUI's `.onHover` uses `.activeInActiveApp` tracking — breaks after app switch on a
/// `nonactivatingPanel`. We use `.activeAlways` NSTrackingArea instead.
///
/// Drag uses `mouseDown` / `mouseDragged` / `mouseUp` plus a display-rate pointer sampler (not a
/// modal `nextEvent` loop) so movement stays smooth when inactive apps coalesce drag events. While
/// the left button is down we
/// ignore `mouseEntered`/`mouseExited` from the tracking area — otherwise moving the window makes the
/// cursor leave the view in window coordinates and the host would think hover ended (closing pop-up,
/// scheduling layout) during a drag.
final class DraggableFloatingPanel: NSPanel {
    var onDragBegan: (() -> Void)?
    var onDragMoved: ((CGRect) -> Void)?
    var onDragEnded: ((CGRect) -> Void)?
    var onClicked: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var constrainDragFrame: ((CGRect) -> CGRect)?
    var dragRegionContains: ((NSPoint, NSRect) -> Bool)?
    var allowsDragging = true
    /// Uses WindowServer's native drag loop. This is preferable for small utility panels whose
    /// SwiftUI content can otherwise coalesce mouse-drag events while the host app is inactive.
    var usesNativeWindowDragging = false
    /// Fires at `mouseDown` (before click vs drag is known) so the host can pause auto-layout timers.
    var onLeftMouseSessionBegan: (() -> Void)?
    /// Fires when the tracking loop ends (mouse up, lost events, etc.).
    var onLeftMouseSessionEnded: (() -> Void)?

    /// True while the left mouse button is down on this panel (read synchronously by the host).
    private(set) var isPointerTrackingInPanel = false

    /// AX queries on the main thread must yield while any floating panel owns the pointer.
    static var isAnyPanelTrackingPointer: Bool {
        NSApp.windows.contains { ($0 as? DraggableFloatingPanel)?.isPointerTrackingInPanel == true }
    }

    private let dragThreshold: CGFloat = 4
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    private var leftButtonSessionActive = false
    private var frameAtLeftPress: CGRect = .zero
    private var pressLocationOnScreen: NSPoint = .zero
    private var grabDeltaScreen: NSPoint = .zero
    private var dragCommitted: Bool = false
    private var currentSessionAllowsDragging = false
    private var dragUpdateTimer: Timer?

    override var canBecomeKey: Bool { false }

    deinit {
        dragUpdateTimer?.invalidate()
    }

    // MARK: - Tracking area (activeAlways → works after app switch)

    override var contentView: NSView? {
        didSet { setupTrackingArea() }
    }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        setupTrackingArea()
    }

    private func setupTrackingArea() {
        guard let contentView else { return }
        if let old = trackingArea {
            contentView.removeTrackingArea(old)
        }
        let area = NSTrackingArea(
            rect: contentView.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        contentView.addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard !leftButtonSessionActive else { return }
        guard !isHovered else { return }
        isHovered = true
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard !leftButtonSessionActive else { return }
        guard isHovered else { return }
        isHovered = false
        onHoverChanged?(false)
    }

    // MARK: - Drag + click

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0 else {
            super.mouseDown(with: event)
            return
        }

        let isInDragRegion = dragRegionContains?(event.locationInWindow, contentView?.bounds ?? .zero) ?? true
        currentSessionAllowsDragging = allowsDragging && isInDragRegion
        if currentSessionAllowsDragging, usesNativeWindowDragging {
            performNativeWindowDrag(with: event)
            return
        }

        if leftButtonSessionActive {
            stopDragUpdateTimer()
            if dragCommitted {
                onDragEnded?(frame)
            } else if frame != frameAtLeftPress {
                setFrame(frameAtLeftPress, display: true)
                displayIfNeeded()
            }
            leftButtonSessionActive = false
            isPointerTrackingInPanel = false
            onLeftMouseSessionEnded?()
            dragCommitted = false
        }

        leftButtonSessionActive = true
        isPointerTrackingInPanel = true
        frameAtLeftPress = frame
        pressLocationOnScreen = convertPoint(toScreen: event.locationInWindow)
        grabDeltaScreen = NSPoint(
            x: pressLocationOnScreen.x - frame.origin.x,
            y: pressLocationOnScreen.y - frame.origin.y
        )
        dragCommitted = false

        onLeftMouseSessionBegan?()
        if currentSessionAllowsDragging {
            startDragUpdateTimer()
        }
    }

    private func performNativeWindowDrag(with event: NSEvent) {
        leftButtonSessionActive = true
        isPointerTrackingInPanel = true
        frameAtLeftPress = frame
        let pointerAtPress = NSEvent.mouseLocation
        onLeftMouseSessionBegan?()

        performDrag(with: event)

        var finalFrame = frame
        if let constrainDragFrame {
            finalFrame = constrainDragFrame(finalFrame)
            if finalFrame.origin != frame.origin {
                setFrameOrigin(finalFrame.origin)
            }
        }

        let frameDistance = hypot(
            finalFrame.origin.x - frameAtLeftPress.origin.x,
            finalFrame.origin.y - frameAtLeftPress.origin.y
        )
        let pointerAtRelease = NSEvent.mouseLocation
        let pointerDistance = hypot(
            pointerAtRelease.x - pointerAtPress.x,
            pointerAtRelease.y - pointerAtPress.y
        )
        if max(frameDistance, pointerDistance) >= dragThreshold {
            dragCommitted = true
            onDragBegan?()
            onDragMoved?(finalFrame)
            onDragEnded?(finalFrame)
        }

        leftButtonSessionActive = false
        isPointerTrackingInPanel = false
        onLeftMouseSessionEnded?()
        dragCommitted = false
        currentSessionAllowsDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 0, leftButtonSessionActive else {
            super.mouseDragged(with: event)
            return
        }
        guard currentSessionAllowsDragging else { return }

        updateCustomDragFrame()
    }

    /// `mouseDragged` delivery becomes visibly bursty for a nonactivating panel over apps such as
    /// Chrome. Sampling the global pointer in the common run-loop modes decouples window movement
    /// from that event cadence while preserving the normal mouse-up/click behavior.
    private func startDragUpdateTimer() {
        stopDragUpdateTimer()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            self?.updateCustomDragFrame()
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        dragUpdateTimer = timer
    }

    private func stopDragUpdateTimer() {
        dragUpdateTimer?.invalidate()
        dragUpdateTimer = nil
    }

    private func updateCustomDragFrame() {
        guard leftButtonSessionActive,
              currentSessionAllowsDragging,
              !usesNativeWindowDragging else { return }

        let pointer = NSEvent.mouseLocation
        let moved = hypot(pointer.x - pressLocationOnScreen.x, pointer.y - pressLocationOnScreen.y)

        guard dragCommitted || moved >= dragThreshold else { return }

        if !dragCommitted {
            dragCommitted = true
            onDragBegan?()
        }

        let newOrigin = NSPoint(x: pointer.x - grabDeltaScreen.x, y: pointer.y - grabDeltaScreen.y)
        var r = frame
        r.origin = newOrigin
        if let constrainDragFrame {
            r = constrainDragFrame(r)
        }
        if hypot(r.origin.x - frame.origin.x, r.origin.y - frame.origin.y) >= 0.25 {
            setFrameOrigin(r.origin)
            onDragMoved?(frame)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard event.buttonNumber == 0 else {
            super.mouseUp(with: event)
            return
        }
        guard leftButtonSessionActive else {
            super.mouseUp(with: event)
            return
        }

        updateCustomDragFrame()
        stopDragUpdateTimer()

        let pointer = NSEvent.mouseLocation
        let moved = hypot(pointer.x - pressLocationOnScreen.x, pointer.y - pressLocationOnScreen.y)

        if dragCommitted || moved >= dragThreshold {
            if currentSessionAllowsDragging {
                if !dragCommitted {
                    onDragBegan?()
                }
                onDragEnded?(frame)
            }
        } else {
            if frame != frameAtLeftPress {
                setFrame(frameAtLeftPress, display: true)
                displayIfNeeded()
            }
            onClicked?()
        }

        leftButtonSessionActive = false
        isPointerTrackingInPanel = false
        onLeftMouseSessionEnded?()
        dragCommitted = false
        currentSessionAllowsDragging = false
        super.mouseUp(with: event)
    }
}
