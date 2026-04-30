import AppKit

/// NSPanel subclass with smooth dragging + hover tracking that works even when the app isn't active.
/// SwiftUI's `.onHover` uses `.activeInActiveApp` tracking — breaks after app switch on a
/// `nonactivatingPanel`. We use `.activeAlways` NSTrackingArea instead.
///
/// Drag uses `mouseDown` / `mouseDragged` / `mouseUp` (not a modal `nextEvent` loop) so the run loop
/// keeps processing display and timers don't fight compositing. While the left button is down we
/// ignore `mouseEntered`/`mouseExited` from the tracking area — otherwise moving the window makes the
/// cursor leave the view in window coordinates and the host would think hover ended (closing pop-up,
/// scheduling layout) during a drag.
final class DraggableFloatingPanel: NSPanel {
    var onDragBegan: (() -> Void)?
    var onDragMoved: ((CGRect) -> Void)?
    var onDragEnded: ((CGRect) -> Void)?
    var onClicked: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    /// Fires at `mouseDown` (before click vs drag is known) so the host can pause auto-layout timers.
    var onLeftMouseSessionBegan: (() -> Void)?
    /// Fires when the tracking loop ends (mouse up, lost events, etc.).
    var onLeftMouseSessionEnded: (() -> Void)?

    /// True while the left mouse button is down on this panel (read synchronously by the host).
    private(set) var isPointerTrackingInPanel = false

    private let dragThreshold: CGFloat = 4
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    private var leftButtonSessionActive = false
    private var frameAtLeftPress: CGRect = .zero
    private var pressLocationInWindow: NSPoint = .zero
    private var grabDeltaScreen: NSPoint = .zero
    private var dragCommitted: Bool = false

    override var canBecomeKey: Bool { false }

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

        if leftButtonSessionActive {
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
        pressLocationInWindow = event.locationInWindow
        let pressScreen = convertPoint(toScreen: pressLocationInWindow)
        grabDeltaScreen = NSPoint(x: pressScreen.x - frame.origin.x, y: pressScreen.y - frame.origin.y)
        dragCommitted = false

        onLeftMouseSessionBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 0, leftButtonSessionActive else {
            super.mouseDragged(with: event)
            return
        }

        let currentInWindow = event.locationInWindow
        let moved = hypot(currentInWindow.x - pressLocationInWindow.x, currentInWindow.y - pressLocationInWindow.y)

        let m = convertPoint(toScreen: currentInWindow)
        let newOrigin = NSPoint(x: m.x - grabDeltaScreen.x, y: m.y - grabDeltaScreen.y)
        var r = frame
        r.origin = newOrigin
        setFrame(r, display: true)
        displayIfNeeded()

        if !dragCommitted && moved >= dragThreshold {
            dragCommitted = true
            onDragBegan?()
        }
        if dragCommitted {
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

        let currentInWindow = event.locationInWindow
        let moved = hypot(currentInWindow.x - pressLocationInWindow.x, currentInWindow.y - pressLocationInWindow.y)

        if dragCommitted || moved >= dragThreshold {
            if !dragCommitted {
                onDragBegan?()
            }
            onDragEnded?(frame)
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
        super.mouseUp(with: event)
    }
}
