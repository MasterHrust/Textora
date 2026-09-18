import AppKit
import Combine
import SwiftUI

@MainActor
final class AppCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = AppCoordinator()
    private static let onboardingCompletedKey = "onboarding.byok.completed.v2"
    private static let onboardingSkippedKey = "onboarding.byok.skipped"

    private let selectionAssistant = SelectionAssistantController()
    private var settingsWindow: NSWindow?
    private var settingsViewModel: AppViewModel?
    private var onboardingWindow: NSWindow?
    private var onboardingViewModel: AppViewModel?
    private var accessibilityWizardWindow: NSWindow?
    private let consentPrompt = AppConsentPromptController()
    private let textAccess = TextAccessService()
    private lazy var dictationController = OfflineDictationController(textAccess: textAccess)
    private lazy var dictationMicController = DictationMicController(
        textAccess: textAccess,
        onStart: { [weak self] in self?.dictationController.startFromUI() },
        onStop: { [weak self] in self?.dictationController.stopFromUI() }
    )
    private var selectionAssistantSettingsObserver: NSObjectProtocol?
    private var offlineDictationSettingsObserver: NSObjectProtocol?
    private var accessibilityPermissionObserver: NSObjectProtocol?
    private var primaryInteractionRetryTask: DispatchWorkItem?
    private var primaryInteractionRetryCount = 0
    private var launchWarmupTask: DispatchWorkItem?
    private var launchWarmupCount = 0
    private var pendingDictationConsentBundleID: String?
    private var isDictationInteractionActive = false
    @Published private(set) var helperStatus: String = "Initializing"
    private var didRunLaunchFlow = false
    private var shouldOpenAccessibilityAfterOnboarding = false

    override private init() {
        super.init()
    }

    deinit {
        if let selectionAssistantSettingsObserver {
            NotificationCenter.default.removeObserver(selectionAssistantSettingsObserver)
        }
        if let accessibilityPermissionObserver {
            NotificationCenter.default.removeObserver(accessibilityPermissionObserver)
        }
        if let offlineDictationSettingsObserver {
            NotificationCenter.default.removeObserver(offlineDictationSettingsObserver)
        }
        primaryInteractionRetryTask?.cancel()
        launchWarmupTask?.cancel()
    }

    /// Call only from `NSApplicationDelegate.applicationDidFinishLaunching`.
    func startAfterApplicationReady() {
        guard !didRunLaunchFlow else { return }
        didRunLaunchFlow = true
        start()
    }

    func start() {
        removeObsoleteTextoraDiagnostics()
        AccessibilityPermissionMonitor.shared.start()
        installAccessibilityPermissionObserverIfNeeded()
        installSelectionAssistantSettingsObserverIfNeeded()
        installOfflineDictationSettingsObserverIfNeeded()
        consentPrompt.onAllow = { [weak self] in
            self?.handleConsentAllow()
        }
        consentPrompt.onDeny = { [weak self] in
            self?.handleConsentDeny()
        }
        consentPrompt.onLater = { [weak self] in
            self?.handleConsentLater()
        }
        selectionAssistant.onConsentRequired = { [weak self] anchor, bundleID in
            self?.pendingDictationConsentBundleID = nil
            self?.handleSelectionAssistantConsentRequired(anchor: anchor, bundleID: bundleID)
        }
        dictationController.onNeedsAccessibility = { [weak self] in self?.showAccessibilityWizardDeferred() }
        dictationController.onNeedsModelSettings = { [weak self] in self?.showSettingsWindow() }
        dictationController.onConsentRequired = { [weak self] anchor, bundleID in
            self?.handleDictationConsentRequired(anchor: anchor, bundleID: bundleID)
        }
        dictationController.onActivityChanged = { [weak self] isActive, source in
            self?.handleDictationActivityChanged(isActive: isActive, source: source)
        }
        dictationController.onMiniMicrophoneStateChanged = { [weak self] state in
            self?.dictationMicController.setActivityState(state)
        }
        dictationController.onMiniMicrophoneLevelChanged = { [weak self] level in
            self?.dictationMicController.updateLevel(level)
        }
        dictationController.onMiniMicrophoneElapsedChanged = { [weak self] elapsed in
            self?.dictationMicController.updateElapsed(elapsed)
        }
        GlobalHotKeyManager.shared.onEvent = { [weak self] event in
            self?.handleGlobalHotKey(event)
        }
        GlobalHotKeyManager.shared.reload()
        KeychainHelper.migrateIfNeeded()
        KeychainHelper.warmUpCache()
        scheduleLaunchWarmupRetry(reason: "launch")
        if !UserDefaults.standard.bool(forKey: Self.onboardingCompletedKey) {
            shouldOpenAccessibilityAfterOnboarding = true
            configurePrimaryInteractionMode()
            showOnboardingWindow()
            return
        }
        if (hasAnyConfiguredKey() || OfflineDictationSettings.isEnabled), !textAccess.hasAccessibilityPermission() {
            configurePrimaryInteractionMode()
            schedulePrimaryInteractionRetry(reason: "accessibilityUnavailable")
            showAccessibilityWizardDeferred()
            return
        }
        configurePrimaryInteractionMode()
        schedulePrimaryInteractionRetry(reason: "launchWarmup")
        showOnboardingIfNeededOnLaunch()
    }

    private func installOfflineDictationSettingsObserverIfNeeded() {
        guard offlineDictationSettingsObserver == nil else { return }
        offlineDictationSettingsObserver = NotificationCenter.default.addObserver(
            forName: OfflineDictationSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.configurePrimaryInteractionMode() }
        }
    }

    private func installSelectionAssistantSettingsObserverIfNeeded() {
        guard selectionAssistantSettingsObserver == nil else { return }
        selectionAssistantSettingsObserver = NotificationCenter.default.addObserver(
            forName: SelectionAssistantSettings.settingsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.configurePrimaryInteractionMode()
            }
        }
    }

    private func installAccessibilityPermissionObserverIfNeeded() {
        guard accessibilityPermissionObserver == nil else { return }
        accessibilityPermissionObserver = NotificationCenter.default.addObserver(
            forName: .textoraAccessibilityPermissionDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let isTrusted = (notification.userInfo?["isTrusted"] as? Bool) ?? self.textAccess.hasAccessibilityPermission()
                self.handleAccessibilityPermissionChanged(isTrusted: isTrusted)
            }
        }
    }

    private func handleAccessibilityPermissionChanged(isTrusted: Bool) {
        logSelectionAssistantDiagnostic("accessibility changed trusted=\(isTrusted)")
        if isTrusted {
            dismissAccessibilityWizardIfVisibleWithoutRestartingOnboarding()
            KeychainHelper.migrateIfNeeded()
            KeychainHelper.warmUpCache()
            cancelPrimaryInteractionRetry()
            configurePrimaryInteractionMode()
            scheduleLaunchWarmupRetry(reason: "accessibilityGranted")
            showOnboardingIfNeededOnLaunch(afterAccessibility: true)
        } else {
            selectionAssistant.stop()
            dictationMicController.stop()
            consentPrompt.hide()
            helperStatus = "Accessibility disabled"
            schedulePrimaryInteractionRetry(reason: "accessibilityRevoked")
        }
        settingsViewModel?.refreshAccessibilityPermissionStatus()
        onboardingViewModel?.refreshAccessibilityPermissionStatus()
    }

    private func dismissAccessibilityWizardIfVisibleWithoutRestartingOnboarding() {
        guard let accessibilityWizardWindow else { return }
        accessibilityWizardWindow.delegate = nil
        accessibilityWizardWindow.close()
        self.accessibilityWizardWindow = nil
    }

    private var isToolboxEnabled: Bool {
        SelectionAssistantSettings.registerDefaults()
        return UserDefaults.standard.bool(forKey: SelectionAssistantSettings.Keys.toolboxEnabled)
    }

    private var isHotKeysEnabled: Bool {
        SelectionAssistantSettings.hotKeysModeEnabled()
    }

    private func configurePrimaryInteractionMode() {
        if !OfflineDictationSettings.isEnabled {
            dictationController.disableAndUnload()
        }
        consentPrompt.hide()

        GlobalHotKeyManager.shared.reload()
        configureDictationMic()
        if isDictationInteractionActive {
            selectionAssistant.stop()
            helperStatus = "Offline dictation active"
            return
        }
        guard hasAnyConfiguredKey() else {
            helperStatus = OfflineDictationSettings.isEnabled ? "Offline dictation active" : "API key required"
            selectionAssistant.stop()
            return
        }
        guard textAccess.hasAccessibilityPermission() else {
            helperStatus = "Waiting for Accessibility permission"
            selectionAssistant.stop()
            return
        }
        cancelPrimaryInteractionRetry()

        let hasEnabledHotKey = isHotKeysEnabled && (SelectionAssistantSettings.hotKey(for: .rewrite).isEnabled
            || SelectionAssistantSettings.hotKey(for: .translate).isEnabled
        )
        if isToolboxEnabled || hasEnabledHotKey {
            selectionAssistant.start(automaticDetectionEnabled: isToolboxEnabled)
        } else {
            selectionAssistant.stop()
        }

        helperStatus = isToolboxEnabled ? "Toolbox active" : "Hotkeys active"
    }

    private func handleDictationActivityChanged(
        isActive: Bool,
        source: OfflineDictationController.TriggerSource
    ) {
        dictationMicController.setExternallySuppressed(isActive && source == .hotKey)
        guard isDictationInteractionActive != isActive else { return }
        isDictationInteractionActive = isActive
        if isActive {
            selectionAssistant.stop()
            helperStatus = "Offline dictation active"
        } else {
            configurePrimaryInteractionMode()
        }
    }

    private func configureDictationMic() {
        guard DictationMicVisibilityPolicy.shouldRun(
            isEnabled: OfflineDictationSettings.isEnabled,
            accessibilityGranted: textAccess.hasAccessibilityPermission(),
            hotKeysOnly: isHotKeysEnabled
        ) else {
            dictationMicController.stop()
            return
        }
        let mode: DictationMicController.InterfaceMode = .toolbox
        dictationMicController.start(mode: mode)
        dictationMicController.setExternallySuppressed(false)
    }

    private func handleGlobalHotKey(_ event: TextoraHotKeyEvent) {
        if event.action == .dictate {
            dictationController.handle(event.phase)
            return
        }
        guard event.phase == .pressed else { return }
        guard hasAnyConfiguredKey() else {
            showOnboardingWindow()
            return
        }
        guard textAccess.hasAccessibilityPermission() else {
            showAccessibilityWizardDeferred()
            return
        }
        selectionAssistant.performHotKeyAction(event.action)
    }

    func warmPrimaryInteractionsIfPossible() {
        configurePrimaryInteractionMode()
        schedulePrimaryInteractionRetry(reason: "activationWarmup")
        scheduleLaunchWarmupRetry(reason: "activationWarmup")
    }

    func prepareForTermination() {
        settingsViewModel?.flushPendingSave()
        onboardingViewModel?.flushPendingSave()
        dictationMicController.stop()
        dictationController.prepareForTermination()
        GlobalHotKeyManager.shared.stop()
    }

    private func scheduleLaunchWarmupRetry(reason: String) {
        guard hasAnyConfiguredKey() else { return }
        guard launchWarmupTask == nil else { return }
        guard launchWarmupCount < 24 else {
            logSelectionAssistantDiagnostic(
                "launch warmup abandoned attempts=\(launchWarmupCount) reason=\(reason)"
            )
            return
        }
        launchWarmupCount += 1
        let retryDelays: [TimeInterval] = [
            0.25, 0.50, 0.75, 1.0, 1.5, 2.0,
            3.0, 4.0, 5.0, 6.0, 8.0, 10.0
        ]
        let delay = retryDelays[min(launchWarmupCount - 1, retryDelays.count - 1)]
        let task = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.launchWarmupTask = nil
                self.configurePrimaryInteractionMode()
                if self.shouldContinueLaunchWarmup {
                    self.scheduleLaunchWarmupRetry(reason: reason)
                } else {
                    self.cancelLaunchWarmupRetry()
                }
            }
        }
        launchWarmupTask = task
        logSelectionAssistantDiagnostic(
            "launch warmup scheduled attempt=\(launchWarmupCount) delay=\(String(format: "%.2f", delay)) reason=\(reason)"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    private var shouldContinueLaunchWarmup: Bool {
        guard hasAnyConfiguredKey() else { return false }
        guard textAccess.hasAccessibilityPermission() else { return true }
        if isToolboxEnabled || isHotKeysEnabled {
            return false
        }
        return launchWarmupCount < 3
    }

    private func cancelLaunchWarmupRetry() {
        launchWarmupTask?.cancel()
        launchWarmupTask = nil
        launchWarmupCount = 0
    }

    private func schedulePrimaryInteractionRetry(reason: String) {
        guard hasAnyConfiguredKey() else { return }
        guard primaryInteractionRetryTask == nil else { return }
        guard primaryInteractionRetryCount < 12 else {
            logSelectionAssistantDiagnostic(
                "primary retry abandoned attempts=\(primaryInteractionRetryCount) reason=\(reason)"
            )
            return
        }
        primaryInteractionRetryCount += 1
        let retryDelays: [TimeInterval] = [0.10, 0.25, 0.50, 0.75, 1.0, 1.5, 2.0, 3.0, 5.0, 8.0, 10.0, 10.0]
        let delay = retryDelays[min(primaryInteractionRetryCount - 1, retryDelays.count - 1)]
        let task = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.primaryInteractionRetryTask = nil
                self.configurePrimaryInteractionMode()
                if !self.textAccess.hasAccessibilityPermission() {
                    self.schedulePrimaryInteractionRetry(reason: reason)
                }
            }
        }
        primaryInteractionRetryTask = task
        logSelectionAssistantDiagnostic(
            "primary retry scheduled attempt=\(primaryInteractionRetryCount) delay=\(String(format: "%.2f", delay)) reason=\(reason)"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    private func cancelPrimaryInteractionRetry() {
        primaryInteractionRetryTask?.cancel()
        primaryInteractionRetryTask = nil
        primaryInteractionRetryCount = 0
    }

    private func logSelectionAssistantDiagnostic(_ message: @autoclosure () -> String) {}

    /// One run-loop cycle + short delay so MenuBarExtra and LSUIElement finish activation.
    private func showAccessibilityWizardDeferred() {
        DispatchQueue.main.async { [weak self] in
            self?.showAccessibilityWizard()
        }
    }

    private func showAccessibilityWizard() {
        guard accessibilityWizardWindow == nil else { return }
        let content = AccessibilityWizardView(
            onOpenAccessibility: { [weak self] in
                self?.textAccess.openAccessibilitySettings()
            }
        )
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 390),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Textora"
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.contentView = hosting
        window.center()
        window.delegate = self
        accessibilityWizardWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === accessibilityWizardWindow {
            accessibilityWizardWindow = nil
            KeychainHelper.migrateIfNeeded()
            KeychainHelper.warmUpCache()
            configurePrimaryInteractionMode()
            showOnboardingIfNeededOnLaunch(afterAccessibility: true)
            return
        }
        if (notification.object as? NSWindow) === onboardingWindow {
            if onboardingViewModel?.isOnboardingComplete != true {
                onboardingViewModel?.skipOnboardingForNow()
            }
            onboardingWindow = nil
        }
    }

    private func handleConsentAllow() {
        guard let bundleID = consentPrompt.capturedConsentBundleID, !bundleID.isEmpty else {
            consentPrompt.hide()
            return
        }
        let wasDictationRequest = pendingDictationConsentBundleID == bundleID
        pendingDictationConsentBundleID = nil
        textAccess.setAppConsentStatus(.allowed, for: bundleID)
        consentPrompt.hide()
        selectionAssistant.resolvePendingHotKeyConsent(for: bundleID, allowed: true)
        if wasDictationRequest {
            dictationMicController.setExternallySuppressed(false)
            return
        }
    }

    private func handleConsentDeny() {
        guard let bundleID = consentPrompt.capturedConsentBundleID, !bundleID.isEmpty else {
            consentPrompt.hide()
            return
        }
        if pendingDictationConsentBundleID == bundleID {
            pendingDictationConsentBundleID = nil
        }
        textAccess.setAppConsentStatus(.denied, for: bundleID)
        consentPrompt.hide()
        selectionAssistant.resolvePendingHotKeyConsent(for: bundleID, allowed: false)
    }

    private func handleConsentLater() {
        if let bundleID = consentPrompt.capturedConsentBundleID {
            if pendingDictationConsentBundleID == bundleID {
                pendingDictationConsentBundleID = nil
            }
            selectionAssistant.resolvePendingHotKeyConsent(for: bundleID, allowed: false)
        }
        consentPrompt.hide()
        if isToolboxEnabled {
            selectionAssistant.suppressConsentPromptBriefly()
        }
    }

    private func handleSelectionAssistantConsentRequired(anchor: CGRect, bundleID: String) {
        guard isToolboxEnabled || isHotKeysEnabled || OfflineDictationSettings.isEnabled else { return }

        let frontmost = textAccess.frontmostAppInfo()
        let appName = frontmost?.bundleID == bundleID ? frontmost?.displayName ?? bundleID : bundleID
        consentPrompt.show(near: anchor, appName: appName, targetBundleID: bundleID)
    }

    private func handleDictationConsentRequired(anchor: CGRect, bundleID: String) {
        pendingDictationConsentBundleID = bundleID
        handleSelectionAssistantConsentRequired(anchor: anchor, bundleID: bundleID)
    }

    func showSettingsWindow() {
        if settingsWindow == nil {
            let vm = AppViewModel()
            settingsViewModel = vm
            let root = ContentView(viewModel: vm)
            let hosting = NSHostingView(rootView: root)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Textora Settings"
            // Default true would release the window when closed → dangling ref / crash on second open.
            window.isReleasedWhenClosed = false
            window.center()
            window.contentView = hosting
            settingsWindow = window
        } else {
            settingsViewModel?.reloadFromUserDefaults()
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func showQuickSetupWindow() {
        UserDefaults.standard.removeObject(forKey: Self.onboardingSkippedKey)
        showOnboardingWindow()
    }

    private func showOnboardingIfNeededOnLaunch(afterAccessibility: Bool = false) {
        let defaults = UserDefaults.standard
        let completed = defaults.bool(forKey: Self.onboardingCompletedKey)

        guard !completed else { return }
        if afterAccessibility {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.showOnboardingWindow()
        }
    }

    private func showOnboardingWindow() {
        if onboardingViewModel == nil {
            onboardingViewModel = AppViewModel()
        }
        onboardingViewModel?.prepareOnboardingSession()
        if onboardingWindow == nil {
            let root = OnboardingView(
                viewModel: onboardingViewModel!,
                onClose: { [weak self] in
                    self?.closeOnboardingWindow()
                },
                onOpenSettings: { [weak self] in
                    self?.showSettingsWindow()
                },
                onFinish: { [weak self] in
                    guard let self else { return }
                    guard self.onboardingViewModel?.completeOnboarding() == true else { return }
                    self.closeOnboardingWindow()
                    let needsAccessibility = self.hasAnyConfiguredKey() || OfflineDictationSettings.isEnabled
                    if needsAccessibility && (self.shouldOpenAccessibilityAfterOnboarding || !self.textAccess.hasAccessibilityPermission()) {
                        self.shouldOpenAccessibilityAfterOnboarding = false
                        self.showAccessibilityWizardDeferred()
                    } else {
                        self.configurePrimaryInteractionMode()
                    }
                }
            )
            let hosting = NSHostingView(rootView: root)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Welcome to Textora"
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isMovableByWindowBackground = true
            window.contentView = hosting
            window.center()
            window.delegate = self
            onboardingWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
        onboardingWindow?.orderFrontRegardless()
    }

    private func closeOnboardingWindow() {
        onboardingWindow?.orderOut(nil)
        onboardingWindow = nil
    }

    private func hasAnyConfiguredKey() -> Bool {
        (KeychainHelper.read(key: KeychainHelper.openAIKeyAccount)?.isEmpty == false) ||
        (KeychainHelper.read(key: KeychainHelper.geminiKeyAccount)?.isEmpty == false) ||
        (KeychainHelper.read(key: KeychainHelper.claudeKeyAccount)?.isEmpty == false) ||
        (KeychainHelper.read(key: KeychainHelper.customTokenAccount)?.isEmpty == false)
    }
}
