import AppKit
import Combine
import Sparkle

/// The same bundled Markdown can be used for GitHub and Sparkle release notes.
/// A version mismatch must never show an older feature tour after a later update.
struct ReleaseNotes: Equatable {
    enum Action: String, Equatable {
        case myStyle, dictation, history
    }
    struct Section: Identifiable, Equatable {
        let title: String
        var paragraphs: [String] = []
        var bullets: [String] = []
        var action: Action? {
            switch title {
            case "My Style": return .myStyle
            case "Message": return .dictation
            case "Recent Results": return .history
            default: return nil
            }
        }
        var id: String { title }
    }
    let version: String
    let title: String
    let summary: String
    let sections: [Section]

    static func currentVersion(bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    static func current(bundle: Bundle = .main) -> Self? {
        guard let url = bundle.url(forResource: "ReleaseNotes", withExtension: "md"),
              let markdown = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(markdown, for: currentVersion(bundle: bundle))
    }

    static func parse(_ markdown: String, for version: String) -> Self? {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        guard !version.isEmpty, lines.first == "# Textora \(version)" else { return nil }
        var summary: [String] = []
        var sections: [Section] = []
        for raw in lines.dropFirst() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("## ") {
                let heading = String(line.dropFirst(3))
                guard !heading.isEmpty, !sections.contains(where: { $0.title == heading }) else { return nil }
                sections.append(Section(title: heading))
            } else if sections.isEmpty {
                summary.append(line)
            } else if line.hasPrefix("- ") {
                let bullet = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !bullet.isEmpty { sections[sections.count - 1].bullets.append(bullet) }
            } else {
                sections[sections.count - 1].paragraphs.append(line)
            }
        }
        guard !sections.isEmpty, sections.allSatisfy({ !$0.paragraphs.isEmpty || !$0.bullets.isEmpty }) else { return nil }
        return Self(version: version, title: "What’s new in Textora", summary: summary.joined(separator: " "), sections: sections)
    }
}

enum ReleaseNotesPresentation {
    static let seenVersionKey = "releaseNotes.lastSeenVersion.v1"

    static func shouldPresent(notes: ReleaseNotes?, currentVersion: String, onboardingComplete: Bool,
                              defaults: UserDefaults = .standard) -> Bool {
        guard onboardingComplete, let notes, notes.version == currentVersion else { return false }
        guard let previous = defaults.string(forKey: seenVersionKey) else { return true }
        return currentVersion.compare(previous, options: .numeric) == .orderedDescending
    }

    static func markSeen(version: String, defaults: UserDefaults = .standard) {
        guard !version.isEmpty else { return }
        // Running an older test build must not cause the newer release to be announced again.
        if let previous = defaults.string(forKey: seenVersionKey),
           version.compare(previous, options: .numeric) == .orderedAscending { return }
        defaults.set(version, forKey: seenVersionKey)
    }
}

/// One updater for both Settings and the menu bar, retained for the app's lifetime.
@MainActor
final class AppUpdateManager: ObservableObject {
    static let shared = AppUpdateManager()
    static let automaticCheckInterval: TimeInterval = 5 * 60 * 60

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
        return "\(info["CFBundleShortVersionString"] as? String ?? "-") (\(info["CFBundleVersion"] as? String ?? "-"))"
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
            // Apply the current schedule even if an earlier release persisted
            // its interval in Sparkle's preferences. The opt-in flag is separate.
            controller.updater.updateCheckInterval = Self.automaticCheckInterval
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
