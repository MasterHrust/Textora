import AppKit

/// LSUIElement + MenuBarExtra: windows are not reliable from `App.init()`, wait for `didFinishLaunching`.
@MainActor
final class TextoraAppDelegate: NSObject, NSApplicationDelegate {
    private var runningTests: Bool {
        NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !runningTests else { return }
        AppCoordinator.shared.startAfterApplicationReady()
        AppUpdateManager.shared.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !runningTests else { return }
        AccessibilityPermissionMonitor.shared.refreshNow()
        AppCoordinator.shared.warmPrimaryInteractionsIfPossible()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !runningTests else { return }
        AppCoordinator.shared.prepareForTermination()
    }

    /// Menu bar (LSUIElement) apps otherwise quit when Settings is closed — no dock icon to "reopen".
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
