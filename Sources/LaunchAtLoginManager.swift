import ServiceManagement

enum LaunchAtLoginState: Equatable {
    case disabled
    case enabled
    case requiresApproval

    var isRegistered: Bool {
        self == .enabled || self == .requiresApproval
    }
}

enum LaunchAtLoginManager {
    static var state: LaunchAtLoginState {
        state(for: SMAppService.mainApp.status)
    }

    static func state(for status: SMAppService.Status) -> LaunchAtLoginState {
        switch status {
        case .notRegistered:
            return .disabled
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            // ServiceManagement also reports `notFound` before the main app
            // has ever been registered. Treat it as the initial off state so
            // the user can make the first call to `register()`.
            return .disabled
        @unknown default:
            return .disabled
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard state != .enabled, state != .requiresApproval else { return }
            try SMAppService.mainApp.register()
        } else {
            guard state != .disabled else { return }
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
