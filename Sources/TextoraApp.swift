import SwiftUI

@main
struct TextoraApp: App {
    @NSApplicationDelegateAdaptor(TextoraAppDelegate.self) private var appDelegate
    @StateObject private var coordinator = AppCoordinator.shared
    @ObservedObject private var updates = AppUpdateManager.shared

    init() {
        UserDefaults.standard.register(defaults: [
            AppViewModel.SettingsKeys.smartAIEnabled: true
        ])
    }

    private var menuBarIcon: NSImage {
        // Status bar expects small template images; oversized color PNGs can render incorrectly.
        let base = NSImage(named: "helper-icon") ?? NSImage()
        let img = base.copy() as? NSImage ?? base
        img.size = NSSize(width: 22, height: 22)
        img.isTemplate = true
        return img
    }

    var body: some Scene {
        MenuBarExtra {
            Text("Textora is active")
            Text("Status: \(coordinator.helperStatus)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Divider()
            Button("Open Quick Setup") {
                coordinator.showQuickSetupWindow()
            }
            Button("Recent Results…") { FeatureWindows.shared.showHistory() }
            Button("Settings…") {
                coordinator.showSettingsWindow()
            }
            Link("Feature Request", destination: AppContact.featureRequestURL)
            Button("Check for Updates…") {
                updates.checkForUpdates()
            }
            .disabled(!updates.canCheckForUpdates)
            Divider()
            Text(AppContact.developerCredit).font(.caption)
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Image(nsImage: menuBarIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .fixedSize()
        }
        .menuBarExtraStyle(.menu)
    }
}
