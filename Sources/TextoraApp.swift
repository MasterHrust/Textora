import SwiftUI

@main
struct TextoraApp: App {
    @NSApplicationDelegateAdaptor(TextoraAppDelegate.self) private var appDelegate
    @StateObject private var coordinator = AppCoordinator.shared
    private let donateURL = "https://github.com/sponsors/MasterHrust"

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
            Text("Desktop helper is active")
            Text("Focus text field to see floating button")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Status: \(coordinator.helperStatus)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("Show test bubble at mouse") {
                coordinator.showDebugBubbleAtMouse()
            }
            Divider()
            Button("Open Quick Setup") {
                coordinator.showQuickSetupWindow()
            }
            Button("Open Settings") {
                coordinator.showSettingsWindow()
            }
            Button("Support project") {
                guard let url = URL(string: donateURL) else { return }
                NSWorkspace.shared.open(url)
            }
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
