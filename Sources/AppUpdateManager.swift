import AppKit
import Combine
import Sparkle

/// One updater for both Settings and the menu bar, retained for the app's lifetime.
@MainActor
final class AppUpdateManager: ObservableObject {
    static let shared = AppUpdateManager()

    @Published private(set) var canCheckForUpdates = true
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var isReady = false
    @Published private(set) var unavailableMessage: String?

    private let controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
    )
    private var didStart = false

    var versionDescription: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "—") (\(info["CFBundleVersion"] as? String ?? "—"))"
    }

    private init() {}

    func start() {
        guard !didStart else { return }
        didStart = true
        // Do not start background checks in a build without a release signing key.
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else {
            unavailableMessage = "In-app updates are not configured in this build."
            return
        }
        do {
            try controller.updater.start()
            controller.updater.publisher(for: \.canCheckForUpdates)
                .assign(to: &$canCheckForUpdates)
            controller.updater.publisher(for: \.automaticallyChecksForUpdates)
                .assign(to: &$automaticallyChecksForUpdates)
            isReady = true
        } catch {
            unavailableMessage = "The update service could not start: \(error.localizedDescription)"
        }
    }

    func checkForUpdates() {
        start()
        NSApp.activate(ignoringOtherApps: true)
        guard isReady else {
            let alert = NSAlert()
            alert.messageText = "Updates unavailable"
            alert.informativeText = unavailableMessage ?? "Please try again after restarting Textora."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        guard canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard isReady else { return }
        controller.updater.automaticallyChecksForUpdates = enabled
    }
}
