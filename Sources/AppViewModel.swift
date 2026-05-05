import AppKit
import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    enum SettingsKeys {
        static let detailedCorrectionsEnabled = "overlay.detailedCorrections.enabled"
        static let smartAIEnabled = "overlay.smartAI.enabled"
    }

    private enum OnboardingDefaults {
        static let completedKey = "onboarding.byok.completed"
        static let skippedKey = "onboarding.byok.skipped"
    }

    struct AppConsentRow: Identifiable {
        let id: String
        let bundleID: String
        var status: TextAccessService.AppConsentStatus
    }

    @Published var originalText = ""
    @Published var rewrittenText = ""
    @Published var operation: RewriteOperation = .fixGrammar
    @Published var isLoading = false
    @Published var errorText = ""

    @Published var provider: AIProvider = .openai {
        didSet {
            guard !isReloadingFromDefaults else { return }
            model = defaultModel(for: provider)
        }
    }
    @Published var model: String = AIClient.Defaults.openAIModel
    @Published var openAIKey: String = ""
    @Published var geminiKey: String = ""
    @Published var claudeKey: String = ""
    @Published var customToken: String = ""
    /// OpenAI-compatible Chat Completions base URL (e.g. `https://api.example.com` or `https://host/v1`).
    @Published var customOpenAIBaseURL: String = ""
    @Published var appConsentRows: [AppConsentRow] = []
    @Published var hasAccessibilityPermission: Bool = false
    @Published var detailedCorrectionsEnabled: Bool = false
    @Published var onboardingStep: Int = 1
    @Published var onboardingErrorText: String = ""
    @Published var isOnboardingBusy: Bool = false
    @Published var isOnboardingComplete: Bool = false

    private let textService = TextAccessService()
    private let aiClient = AIClient()
    private var isReloadingFromDefaults = false
    private var autoSaveTask: DispatchWorkItem?

    init() {
        reloadFromUserDefaults()
        isOnboardingComplete = UserDefaults.standard.bool(forKey: OnboardingDefaults.completedKey)
    }

    /// Sync fields when reopening Settings so keys/model match disk (avoids stale SwiftUI state).
    func reloadFromUserDefaults() {
        isReloadingFromDefaults = true
        defer { isReloadingFromDefaults = false }
        provider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "provider") ?? "openai") ?? .openai
        model = UserDefaults.standard.string(forKey: "model") ?? defaultModel(for: provider)
        openAIKey = KeychainHelper.read(key: KeychainHelper.openAIKeyAccount) ?? ""
        geminiKey = KeychainHelper.read(key: KeychainHelper.geminiKeyAccount) ?? ""
        claudeKey = KeychainHelper.read(key: KeychainHelper.claudeKeyAccount) ?? ""
        customToken = KeychainHelper.read(key: KeychainHelper.customTokenAccount) ?? ""
        customOpenAIBaseURL = UserDefaults.standard.string(forKey: AIClient.openAICompatibleBaseURLUserDefaultsKey) ?? ""
        detailedCorrectionsEnabled = UserDefaults.standard.bool(forKey: SettingsKeys.detailedCorrectionsEnabled)
        hasAccessibilityPermission = textService.hasAccessibilityPermission()
        refreshAppConsents()
    }

    func refreshSelection() {
        originalText = textService.getSelectedText()
        rewrittenText = ""
        errorText = ""
    }

    func rewrite() async {
        guard !originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorText = "No selected text found"
            return
        }
        let key: String
        switch provider {
        case .openai:
            key = openAIKey
        case .gemini:
            key = geminiKey
        case .claude:
            key = claudeKey
        case .other:
            key = customToken
        }
        guard !key.isEmpty else {
            errorText = "API key is missing for selected provider"
            return
        }
        if provider == .other {
            let base = customOpenAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !base.isEmpty else {
                errorText = "API base URL is missing for Other AI"
                return
            }
        }
        isLoading = true
        errorText = ""
        do {
            rewrittenText = try await aiClient.rewriteText(
                provider: provider,
                model: model,
                apiKey: key,
                text: originalText,
                operation: operation
            )
        } catch {
            errorText = error.localizedDescription
        }
        isLoading = false
    }

    func copyResult() {
        guard !rewrittenText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rewrittenText, forType: .string)
    }

    func replaceOrCopy() {
        guard !rewrittenText.isEmpty else { return }
        let replaced = textService.replaceSelectedText(with: rewrittenText)
        if !replaced {
            copyResult()
        }
    }

    func saveSettings() {
        UserDefaults.standard.set(provider.rawValue, forKey: "provider")
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmedModel.isEmpty ? defaultModel(for: provider) : trimmedModel, forKey: "model")
        UserDefaults.standard.set(
            customOpenAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: AIClient.openAICompatibleBaseURLUserDefaultsKey
        )
        UserDefaults.standard.set(detailedCorrectionsEnabled, forKey: SettingsKeys.detailedCorrectionsEnabled)
        KeychainHelper.saveAll(
            openAI: openAIKey,
            gemini: geminiKey,
            claude: claudeKey,
            custom: customToken
        )
    }

    var shouldShowOnboarding: Bool {
        !isOnboardingComplete && !UserDefaults.standard.bool(forKey: OnboardingDefaults.skippedKey)
    }

    func skipOnboardingForNow() {
        UserDefaults.standard.set(true, forKey: OnboardingDefaults.skippedKey)
    }

    func moveOnboardingBack() {
        onboardingErrorText = ""
        onboardingStep = max(1, onboardingStep - 1)
    }

    func moveOnboardingNext() {
        onboardingErrorText = ""
        onboardingStep = min(4, onboardingStep + 1)
    }

    func completeOnboarding() {
        isOnboardingComplete = true
        onboardingErrorText = ""
        UserDefaults.standard.set(true, forKey: OnboardingDefaults.completedKey)
        UserDefaults.standard.removeObject(forKey: OnboardingDefaults.skippedKey)
    }

    func prepareOnboardingSession() {
        onboardingStep = 1
        onboardingErrorText = ""
        isOnboardingBusy = false
        reloadFromUserDefaults()
    }

    func validateCurrentProviderSetup() async -> Bool {
        onboardingErrorText = ""
        let key: String
        let validationModel: String
        switch provider {
        case .openai:
            key = openAIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            validationModel = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AIClient.Defaults.openAIModel : model
        case .gemini:
            key = geminiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            validationModel = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AIClient.Defaults.geminiModel : model
        case .claude:
            key = claudeKey.trimmingCharacters(in: .whitespacesAndNewlines)
            validationModel = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AIClient.Defaults.claudeModel : model
        case .other:
            key = customToken.trimmingCharacters(in: .whitespacesAndNewlines)
            validationModel = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AIClient.Defaults.customModel : model
            let base = customOpenAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if base.isEmpty {
                onboardingErrorText = "Set API URL for Other AI."
                return false
            }
        }
        guard !key.isEmpty else {
            onboardingErrorText = "Add an API key for the selected provider."
            return false
        }
        isOnboardingBusy = true
        defer { isOnboardingBusy = false }
        saveSettings()
        do {
            _ = try await aiClient.rewriteText(
                provider: provider,
                model: validationModel,
                apiKey: key,
                text: "hello",
                operation: .fixGrammar
            )
            return true
        } catch {
            onboardingErrorText = friendlyValidationError(error.localizedDescription)
            return false
        }
    }

    private func friendlyValidationError(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("401") || lower.contains("unauthorized") || lower.contains("invalid api key") {
            return "The key was not accepted. Make sure it is copied fully and has no extra spaces."
        }
        if lower.contains("429") || lower.contains("quota") || lower.contains("rate limit") {
            return "Provider limit reached. Check balance and quotas in your AI account."
        }
        if lower.contains("base url") || lower.contains("invalid api base url") {
            return "API URL looks invalid. Verify the address and format."
        }
        if lower.contains("network") || lower.contains("timed out") || lower.contains("offline") {
            return "Could not connect to the provider. Check your internet connection and try again."
        }
        return "Validation failed: \(raw)"
    }

    /// Debounced auto-save: persists settings 0.5s after the last change.
    func debouncedSave() {
        guard !isReloadingFromDefaults else { return }
        autoSaveTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.saveSettings()
        }
        autoSaveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
    }

    private func defaultModel(for provider: AIProvider) -> String {
        switch provider {
        case .openai:
            return AIClient.Defaults.openAIModel
        case .gemini:
            return AIClient.Defaults.geminiModel
        case .claude:
            return AIClient.Defaults.claudeModel
        case .other:
            return AIClient.Defaults.customModel
        }
    }

    func refreshAppConsents() {
        appConsentRows = textService.allAppConsents().map {
            AppConsentRow(id: $0.bundleID, bundleID: $0.bundleID, status: $0.status)
        }
    }

    func requestAccessibilityPermission() {
        textService.requestAccessibilityPermissionIfNeeded()
        // Permission is granted outside the app; re-check after a short delay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshAccessibilityPermissionStatus()
        }
    }

    func refreshAccessibilityPermissionStatus() {
        hasAccessibilityPermission = textService.hasAccessibilityPermission()
    }

    func setConsentStatus(for bundleID: String, status: TextAccessService.AppConsentStatus) {
        textService.setAppConsentStatus(status, for: bundleID)
        refreshAppConsents()
    }

    func removeConsent(for bundleID: String) {
        textService.removeAppConsent(for: bundleID)
        refreshAppConsents()
    }
}
