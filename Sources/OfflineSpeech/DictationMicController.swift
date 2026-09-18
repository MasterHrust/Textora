import AppKit
import QuartzCore
import SwiftUI

enum DictationMicVisibilityPolicy {
    static func shouldRun(isEnabled: Bool, accessibilityGranted: Bool, hotKeysOnly: Bool) -> Bool {
        isEnabled && accessibilityGranted && !hotKeysOnly
    }
}

enum DictationMicActivityState: Equatable {
    case idle
    case preparing
    case recording(language: SpeechLanguage)
    case transcribing
    case success
    case message(String, isError: Bool)
    case hidden

    var isExpanded: Bool {
        switch self {
        case .idle, .hidden: return false
        default: return true
        }
    }
}

@MainActor
final class DictationMicViewModel: ObservableObject {
    @Published var state: DictationMicActivityState = .idle
    @Published var level: Float = 0
    @Published var elapsed: TimeInterval = 0
    @Published var showsDragHandle = false
    @Published var isTranslationSettingsPresented = false
    @Published var microphoneTip: MicrophoneTip?
    @Published var showsTranslationControls = false
}

@MainActor
final class DictationMicController {
    enum InterfaceMode {
        case toolbox
    }

    private var collapsedSize: CGSize {
        CGSize(width: 84, height: 52)
    }

    private var expandedSize: CGSize {
        CGSize(width: mode == .toolbox ? 332 : 300, height: 66)
    }
    private let textAccess: TextAccessService
    private let onStart: () -> Void
    private let onStop: () -> Void
    private let viewModel = DictationMicViewModel()
    private var panel: DraggableFloatingPanel?
    private var timer: Timer?
    private var refreshInFlight = false
    private var hideTranslationControlsTask: Task<Void, Never>?
    private var workspaceObserver: NSObjectProtocol?
    private var mode: InterfaceMode = .toolbox
    private var isRunning = false
    private var isExternallySuppressed = false
    private var lastCollapsedFrame: CGRect?
    private var frameAnimationUntil: Date?
    private var lastPlacementAppPID: pid_t?
    private var lastValidPlacementAt = Date.distantPast
    private var pendingPlacementFrame: CGRect?
    private var pendingPlacementCount = 0
    /// A toolbox drag is an explicit user choice. Keep it as runtime state instead of
    /// recalculating the position from the focused field on every refresh tick.
    private var manuallyDockedCollapsedFrame: CGRect?

    init(
        textAccess: TextAccessService,
        onStart: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        self.textAccess = textAccess
        self.onStart = onStart
        self.onStop = onStop
    }

    deinit {
        timer?.invalidate()
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
    }

    func start(mode: InterfaceMode) {
        self.mode = mode
        viewModel.showsDragHandle = mode == .toolbox
        if mode == .toolbox, manuallyDockedCollapsedFrame == nil {
            manuallyDockedCollapsedFrame = restoredToolboxDockFrame()
        }
        isRunning = true
        if panel == nil { createPanel() }
        panel?.allowsDragging = mode == .toolbox
        // Native NSWindow dragging can move only a WindowServer snapshot for a
        // nonactivating panel and leave the real frame unchanged at mouse-up.
        panel?.usesNativeWindowDragging = false
        installWorkspaceObserverIfNeeded()
        startTimerIfNeeded()
        Task { await refresh() }
    }

    func stop() {
        viewModel.microphoneTip = nil
        hideTranslationControlsTask?.cancel()
        viewModel.showsTranslationControls = false
        viewModel.isTranslationSettingsPresented = false
        isRunning = false
        timer?.invalidate()
        timer = nil
        viewModel.state = .idle
        resetPlacementStability()
        panel?.orderOut(nil)
    }

    func setExternallySuppressed(_ suppressed: Bool) {
        guard isExternallySuppressed != suppressed else { return }
        isExternallySuppressed = suppressed
        if suppressed {
            viewModel.microphoneTip = nil
            hideTranslationControlsTask?.cancel()
            viewModel.showsTranslationControls = false
            viewModel.isTranslationSettingsPresented = false
            panel?.orderOut(nil)
        } else {
            Task { await refresh() }
        }
    }

    func setActivityState(_ state: DictationMicActivityState) {
        if state.isExpanded || state == .hidden {
            viewModel.microphoneTip = nil
            hideTranslationControlsTask?.cancel()
            viewModel.showsTranslationControls = false
        }
        if state.isExpanded || state == .hidden { viewModel.isTranslationSettingsPresented = false }
        viewModel.state = state
        panel?.allowsDragging = mode == .toolbox
        panel?.usesNativeWindowDragging = false
        if case .recording = state {
            viewModel.elapsed = 0
            viewModel.level = 0
        }
        guard isRunning, let panel else { return }
        if state == .hidden {
            panel.orderOut(nil)
            return
        }
        guard let collapsedFrame = lastCollapsedFrame else {
            Task { await refresh() }
            return
        }
        applyFrame(frame(for: state, collapsedFrame: collapsedFrame), animated: panel.isVisible)
        panel.orderFrontRegardless()
    }

    func updateLevel(_ level: Float) {
        viewModel.level = min(max(level, 0), 1)
    }

    func updateElapsed(_ elapsed: TimeInterval) {
        viewModel.elapsed = max(0, elapsed)
    }

    private func createPanel() {
        let panel = DraggableFloatingPanel(
            contentRect: NSRect(origin: .zero, size: collapsedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Movement is handled by DraggableFloatingPanel using absolute pointer
        // coordinates so the stored frame is always the frame visible to the user.
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.ignoresMouseEvents = false
        panel.allowsDragging = mode == .toolbox
        panel.usesNativeWindowDragging = false
        panel.dragRegionContains = { [weak self] point, bounds in
            guard let self, self.mode == .toolbox else { return false }
            // The idle microphone itself is a drag target too. The panel's distance
            // threshold distinguishes a click to record from a drag to reposition.
            if !self.viewModel.state.isExpanded {
                return point.x >= bounds.maxX - self.collapsedSize.width
            }
            let handleHitWidth: CGFloat = self.viewModel.state.isExpanded ? 43 : 32
            return point.x >= bounds.maxX - handleHitWidth
        }
        let hostingView = NSHostingView(rootView: DictationMicView(model: viewModel,
            onHoverChanged: { [weak self] inside in self?.translationHoverChanged(inside) }))
        // The controller owns the window size; SwiftUI's ideal size must not resize
        // the panel independently when the mode or activity state changes.
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: collapsedSize)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false
        panel.contentView = hostingView
        panel.onClicked = { [weak self] in
            guard let self, self.isRunning, !self.isExternallySuppressed else { return }
            switch self.viewModel.state {
            case .preparing, .recording:
                self.onStop()
            case .idle, .success, .message:
                self.onStart()
            case .transcribing, .hidden:
                break
            }
        }
        panel.constrainDragFrame = { frame in
            guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main else {
                return frame
            }
            let visible = screen.visibleFrame
            var next = frame
            next.origin.x = min(max(next.origin.x, visible.minX), visible.maxX - next.width)
            next.origin.y = min(max(next.origin.y, visible.minY), visible.maxY - next.height)
            return next
        }
        panel.onDragEnded = { [weak self] frame in
            guard let self, self.mode == .toolbox else { return }
            let collapsedFrame: CGRect
            if self.viewModel.state.isExpanded || self.viewModel.showsTranslationControls {
                let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main
                guard let visibleFrame = screen?.visibleFrame else { return }
                collapsedFrame = DictationMicLayout.collapsedFrame(
                    afterDraggingExpandedFrame: frame,
                    collapsedSize: self.collapsedSize,
                    visibleFrame: visibleFrame
                )
            } else {
                collapsedFrame = CGRect(origin: frame.origin, size: self.collapsedSize).integral
            }
            self.frameAnimationUntil = nil
            self.manuallyDockedCollapsedFrame = collapsedFrame
            OfflineDictationSettings.microphoneDockOrigin = collapsedFrame.origin
            self.lastCollapsedFrame = collapsedFrame
            self.pendingPlacementFrame = nil
            self.pendingPlacementCount = 0

            // Reconcile the live panel with the committed dock immediately. AppKit's native
            // window-drag loop may finish its own frame bookkeeping after our drag callback,
            // so assert the committed frame once more on the following run-loop turn.
            let committedFrame = self.frame(for: self.viewModel.state, collapsedFrame: collapsedFrame)
            self.applyFrame(committedFrame, animated: false)
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.isRunning,
                      self.mode == .toolbox,
                      self.manuallyDockedCollapsedFrame == collapsedFrame,
                      self.panel?.isPointerTrackingInPanel != true else { return }
                self.applyFrame(
                    self.frame(for: self.viewModel.state, collapsedFrame: collapsedFrame),
                    animated: false
                )
            }
        }
        panel.orderOut(nil)
        self.panel = panel
    }

    private func installWorkspaceObserverIfNeeded() {
        guard workspaceObserver == nil else { return }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // The popover may activate Textora while the source editor loses
                // AX focus. This is interaction with our UI, not a new target app.
                if (self.viewModel.isTranslationSettingsPresented || self.viewModel.microphoneTip != nil),
                   NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                    return
                }
                self.viewModel.isTranslationSettingsPresented = false
                self.viewModel.microphoneTip = nil
                self.hideTranslationControlsTask?.cancel()
                self.viewModel.showsTranslationControls = false
                if self.viewModel.state.isExpanded {
                    self.onStop()
                }
                self.panel?.orderOut(nil)
                Task { await self.refresh() }
            }
        }
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.16, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refresh() async {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        defer { refreshInFlight = false }
        // Check before permission/focus calls: even these can block the drag's main run loop.
        guard !DraggableFloatingPanel.isAnyPanelTrackingPointer else { return }
        guard isRunning,
              !isExternallySuppressed,
              viewModel.state != .hidden,
              OfflineDictationSettings.isEnabled,
              textAccess.hasAccessibilityPermission(),
              let panel else {
            panel?.orderOut(nil)
            return
        }
        if panel.isPointerTrackingInPanel || viewModel.isTranslationSettingsPresented || viewModel.showsTranslationControls { return }

        // AX geometry calls can block while Electron/browser hosts are busy. Once recording
        // starts, keep the captured position instead of polling AX on the animation thread.
        if viewModel.state.isExpanded, let collapsedFrame = lastCollapsedFrame {
            let desiredFrame = frame(for: viewModel.state, collapsedFrame: collapsedFrame)
            if frameAnimationUntil == nil, panel.frame != desiredFrame {
                applyFrame(desiredFrame, animated: false)
            }
            if !panel.isVisible { panel.orderFrontRegardless() }
            return
        }

        let placement = await SelectionTextWorker.shared.microphonePlacement()
        guard isRunning, !isExternallySuppressed, !viewModel.state.isExpanded,
              !viewModel.isTranslationSettingsPresented,
              !viewModel.showsTranslationControls,
              !panel.isPointerTrackingInPanel else { return }
        guard let placement else {
            if Date().timeIntervalSince(lastValidPlacementAt) > 0.55 {
                resetPlacementStability()
                panel.orderOut(nil)
            }
            return
        }

        let candidateFrame = collapsedPanelFrame(for: placement)
        guard !candidateFrame.isEmpty else {
            panel.orderOut(nil)
            return
        }
        lastValidPlacementAt = Date()
        if mode == .toolbox, let manuallyDockedCollapsedFrame {
            lastCollapsedFrame = manuallyDockedCollapsedFrame
            let desiredFrame = frame(for: viewModel.state, collapsedFrame: manuallyDockedCollapsedFrame)
            if panel.frame != desiredFrame {
                applyFrame(desiredFrame, animated: false)
            }
            if !panel.isVisible { panel.orderFrontRegardless() }
            return
        }
        guard let collapsedFrame = stabilizedFrame(candidateFrame, appPID: placement.appPID) else {
            panel.orderOut(nil)
            return
        }
        lastCollapsedFrame = collapsedFrame
        let desiredFrame = frame(for: viewModel.state, collapsedFrame: collapsedFrame)
        if let frameAnimationUntil, frameAnimationUntil > Date() {
            if !panel.isVisible { panel.orderFrontRegardless() }
            return
        }
        frameAnimationUntil = nil
        if panel.frame != desiredFrame {
            applyFrame(desiredFrame, animated: false)
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func stabilizedFrame(_ candidate: CGRect, appPID: pid_t) -> CGRect? {
        guard lastPlacementAppPID == appPID, let current = lastCollapsedFrame else {
            lastPlacementAppPID = appPID
            pendingPlacementFrame = nil
            pendingPlacementCount = 0
            return candidate
        }

        let distance = hypot(candidate.midX - current.midX, candidate.midY - current.midY)
        if distance <= 8 {
            pendingPlacementFrame = nil
            pendingPlacementCount = 0
            return distance <= 2 ? current : candidate
        }

        if let pendingPlacementFrame,
           hypot(candidate.midX - pendingPlacementFrame.midX, candidate.midY - pendingPlacementFrame.midY) <= 6 {
            pendingPlacementCount += 1
        } else {
            pendingPlacementFrame = candidate
            pendingPlacementCount = 1
        }
        guard pendingPlacementCount >= 3 else { return current }
        self.pendingPlacementFrame = nil
        pendingPlacementCount = 0
        return candidate
    }

    private func resetPlacementStability() {
        lastCollapsedFrame = nil
        lastPlacementAppPID = nil
        lastValidPlacementAt = .distantPast
        pendingPlacementFrame = nil
        pendingPlacementCount = 0
    }

    private func collapsedPanelFrame(for placement: TextAccessService.DictationMicPlacement) -> CGRect {
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(placement.fieldFrame) })
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return .zero }
        switch mode {
        case .toolbox:
            if let manuallyDockedCollapsedFrame {
                return manuallyDockedCollapsedFrame
            }
            if let restored = restoredToolboxDockFrame() {
                manuallyDockedCollapsedFrame = restored
                return restored
            }
            return CGRect(
                x: visible.maxX - collapsedSize.width - 24,
                y: visible.minY + 28,
                width: collapsedSize.width,
                height: collapsedSize.height
            ).integral
        }
    }

    private func restoredToolboxDockFrame() -> CGRect? {
        guard let saved = OfflineDictationSettings.microphoneDockOrigin else { return nil }
        return DictationMicLayout.clampedDockFrame(
            origin: saved,
            size: collapsedSize,
            visibleFrames: NSScreen.screens.map(\.visibleFrame)
        )
    }

    private func frame(for state: DictationMicActivityState, collapsedFrame: CGRect) -> CGRect {
        guard state.isExpanded || viewModel.showsTranslationControls else { return collapsedFrame }
        let size = state.isExpanded ? expandedSize : CGSize(width: 250, height: 52)
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(collapsedFrame) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            return CGRect(x: collapsedFrame.maxX - size.width, y: collapsedFrame.midY - size.height / 2, width: size.width, height: size.height)
        }
        var origin = CGPoint(
            x: collapsedFrame.maxX - size.width,
            y: collapsedFrame.midY - size.height / 2
        )
        if origin.x < visible.minX {
            origin.x = collapsedFrame.minX
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return CGRect(origin: origin, size: size).integral
    }

    private func applyFrame(_ frame: CGRect, animated: Bool) {
        guard let panel else { return }
        guard animated else {
            frameAnimationUntil = nil
            panel.setFrame(frame, display: panel.isVisible)
            return
        }
        frameAnimationUntil = Date().addingTimeInterval(0.24)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func translationHoverChanged(_ inside: Bool) {
        hideTranslationControlsTask?.cancel()
        guard isRunning, !viewModel.state.isExpanded else { return }
        if inside {
            setTranslationControlsVisible(true)
        } else {
            hideTranslationControlsTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, !self.viewModel.isTranslationSettingsPresented,
                      self.viewModel.microphoneTip == nil,
                      self.panel?.isPointerTrackingInPanel != true,
                      self.panel?.frame.contains(NSEvent.mouseLocation) != true else { return }
                self.setTranslationControlsVisible(false)
            }
        }
    }

    private func setTranslationControlsVisible(_ visible: Bool) {
        guard viewModel.showsTranslationControls != visible else { return }
        viewModel.showsTranslationControls = visible
        if let collapsedFrame = lastCollapsedFrame {
            applyFrame(frame(for: viewModel.state, collapsedFrame: collapsedFrame), animated: true)
        }
    }
}

enum DictationMicLayout {
    static func clampedDockFrame(
        origin: CGPoint,
        size: CGSize,
        visibleFrames: [CGRect]
    ) -> CGRect? {
        guard size.width > 0, size.height > 0, !visibleFrames.isEmpty else { return nil }
        let proposed = CGRect(origin: origin, size: size).integral
        let target = visibleFrames.max { lhs, rhs in
            intersectionArea(of: proposed, with: lhs) < intersectionArea(of: proposed, with: rhs)
        } ?? visibleFrames[0]
        guard target.width >= size.width, target.height >= size.height else { return nil }
        let clampedOrigin = CGPoint(
            x: min(max(proposed.minX, target.minX), target.maxX - size.width),
            y: min(max(proposed.minY, target.minY), target.maxY - size.height)
        )
        return CGRect(origin: clampedOrigin, size: size).integral
    }

    private static func intersectionArea(of frame: CGRect, with visibleFrame: CGRect) -> CGFloat {
        let intersection = frame.intersection(visibleFrame)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
    }

    static func collapsedFrame(
        afterDraggingExpandedFrame expandedFrame: CGRect,
        collapsedSize: CGSize,
        visibleFrame: CGRect
    ) -> CGRect {
        let usesLeftAnchor = expandedFrame.minX <= visibleFrame.minX + 1
        var origin = CGPoint(
            x: usesLeftAnchor ? expandedFrame.minX : expandedFrame.maxX - collapsedSize.width,
            y: expandedFrame.midY - collapsedSize.height / 2
        )
        origin.x = min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - collapsedSize.width)
        origin.y = min(max(origin.y, visibleFrame.minY), visibleFrame.maxY - collapsedSize.height)
        return CGRect(origin: origin, size: collapsedSize).integral
    }

    static func frame(
        anchor: CGRect,
        fieldFrame: CGRect,
        companionFrame: CGRect?,
        visibleFrame: CGRect,
        side: CGFloat = 44,
        gap: CGFloat = 8
    ) -> CGRect {
        var origin = CGPoint(x: anchor.maxX + gap, y: anchor.midY - side / 2)
        if origin.x + side > visibleFrame.maxX {
            origin.x = anchor.minX - gap - side
        }
        if origin.x < visibleFrame.minX {
            origin.x = min(max(visibleFrame.minX, fieldFrame.maxX - side), visibleFrame.maxX - side)
        }
        origin.y = min(max(origin.y, visibleFrame.minY), visibleFrame.maxY - side)

        if let companionFrame,
           CGRect(origin: origin, size: CGSize(width: side, height: side)).intersects(companionFrame) {
            let left = companionFrame.minX - gap - side
            let right = companionFrame.maxX + gap
            origin.x = left >= visibleFrame.minX ? left : min(right, visibleFrame.maxX - side)
        }
        return CGRect(origin: origin, size: CGSize(width: side, height: side)).integral
    }
}

struct DictationMicView: View {
    @ObservedObject var model: DictationMicViewModel
    let onHoverChanged: (Bool) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("microphone.introduction.v3.completed") private var introductionCompleted = false
    @State private var introductionStarted = false

    var body: some View {
        Group {
            switch model.state {
            case .idle, .hidden:
                microphoneButton
            case .preparing:
                expandedStatus("Preparing", systemImage: "mic.fill", color: .blue, spins: true)
            case .recording(let language):
                recordingView(language: language)
            case .transcribing:
                expandedStatus("Transcribing", systemImage: "waveform", color: .blue, spins: true)
            case .success:
                expandedStatus("Inserted", systemImage: "checkmark.circle.fill", color: .green, spins: false)
            case .message(let text, let isError):
                expandedStatus(
                    text,
                    systemImage: isError ? "exclamationmark.circle.fill" : "info.circle.fill",
                    color: isError ? .red : .blue,
                    spins: false
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .animation(.easeInOut(duration: 0.18), value: model.state)
        .onHover(perform: onHoverChanged)
        .onChange(of: model.isTranslationSettingsPresented) { _, presented in
            onHoverChanged(presented)
        }
        .onChange(of: model.microphoneTip) { _, tip in
            onHoverChanged(tip != nil)
        }
        .onChange(of: model.showsTranslationControls) { _, visible in
            if visible, !introductionCompleted, !introductionStarted {
                introductionStarted = true
                model.microphoneTip = .microphone
            }
        }
    }

    private var microphoneButton: some View {
        HStack(spacing: 0) {
            if model.showsTranslationControls {
                DictationTranslationControl(tip: $model.microphoneTip, isPresented: $model.isTranslationSettingsPresented)
                    .padding(.horizontal, 12)
                    .frame(width: 166, height: 44)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            ZStack {
                Circle()
                    .fill(surfaceColor)
                    .overlay(Circle().stroke(brandGradient, lineWidth: 1.5))
                Image(systemName: "mic.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(brandGradient)
            }
            .frame(width: 44, height: 44)
            .padding(4)
            .contentShape(Circle())
            .help("Start Offline Dictation")
            .accessibilityLabel("Start Offline Dictation")
            .modifier(MicrophoneTipAnchor(target: .microphone, active: $model.microphoneTip))

            if model.showsDragHandle {
                dragHandle
                    .padding(.trailing, 4)
                    .modifier(MicrophoneTipAnchor(target: .drag, active: $model.microphoneTip))
            }
        }
        .frame(width: collapsedWidth, height: 52, alignment: .trailing)
        .animation(.easeInOut(duration: 0.22), value: model.showsTranslationControls)
    }

    private func recordingView(language: SpeechLanguage) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.red)
                .frame(width: 9, height: 9)
                .shadow(color: .red.opacity(0.58), radius: 5)
            SmoothMicWaveform(level: model.level)
                .frame(width: 82, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Listening")
                    .font(.system(size: 13, weight: .semibold))
                Text(durationText)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            stopButton
            if model.showsDragHandle {
                dragHandle
            }
        }
        .padding(.leading, 15)
        .padding(.trailing, 7)
        .frame(width: expandedInnerWidth, height: 58)
        .background(expandedBackground)
        .padding(4)
        .frame(width: expandedWidth, height: 66)
        .contentShape(Capsule())
        .help("Click again to stop recording")
    }

    private var stopButton: some View {
        ZStack {
            Circle().fill(Color.red.opacity(0.16))
            Image(systemName: "stop.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.red)
        }
        .frame(width: 38, height: 38)
    }

    private func expandedStatus(_ title: String, systemImage: String, color: Color, spins: Bool) -> some View {
        HStack(spacing: 11) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(color)
                .symbolEffect(.variableColor.iterative, options: spins ? .repeating : .nonRepeating)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
            Spacer(minLength: 4)
            if model.state == .preparing {
                stopButton
            }
            if model.showsDragHandle {
                dragHandle
            }
        }
        .padding(.horizontal, 15)
        .frame(width: expandedInnerWidth, height: 58)
        .background(expandedBackground)
        .padding(4)
        .frame(width: expandedWidth, height: 66)
    }

    private var dragHandle: some View {
        ZStack {
            Capsule()
                // This panel floats over arbitrary app backgrounds. Keep the handle
                // opaque so a dark appearance cannot produce white-on-white controls.
                .fill(colorScheme == .dark
                    ? Color(red: 0.18, green: 0.19, blue: 0.20)
                    : Color(red: 0.94, green: 0.94, blue: 0.95))
                .overlay(Capsule().strokeBorder(
                    colorScheme == .dark ? Color.white.opacity(0.24) : Color.black.opacity(0.24),
                    lineWidth: 1
                ))
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
        }
        .frame(width: 28, height: 36)
        .contentShape(Capsule())
        .help("Drag microphone")
        .accessibilityLabel("Drag microphone")
    }

    private var expandedBackground: some View {
        Capsule()
            .fill(surfaceColor)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.42 : 0.18), radius: 12, y: 6)
    }

    private var surfaceColor: Color {
        Color(nsColor: .windowBackgroundColor).opacity(colorScheme == .dark ? 0.97 : 0.99)
    }

    private var brandGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.20, green: 0.67, blue: 1.0), Color(red: 0.88, green: 0.22, blue: 0.88)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var durationText: String {
        let value = Int(model.elapsed)
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    private var collapsedWidth: CGFloat { model.showsTranslationControls ? 250 : 84 }
    private var expandedWidth: CGFloat { model.showsDragHandle ? 332 : 300 }
    private var expandedInnerWidth: CGFloat { expandedWidth - 8 }
}

private struct SmoothMicWaveform: View {
    let level: Float
    @State private var displayedLevel: CGFloat = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
            HStack(spacing: 2.5) {
                ForEach(0..<15, id: \.self) { index in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    let wave = (sin(time * 8.5 + Double(index) * 0.68) + 1) / 2
                    let envelope = 0.45 + 0.55 * sin(Double(index + 1) / 16 * .pi)
                    let amplitude = max(0.08, Double(displayedLevel)) * envelope
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.blue, .purple, .pink],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: 2.5, height: 4 + CGFloat(amplitude * (10 + wave * 17)))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .onAppear { displayedLevel = CGFloat(level) }
        .onChange(of: level) { _, value in
            withAnimation(.easeOut(duration: 0.14)) {
                displayedLevel = CGFloat(value)
            }
        }
    }
}
