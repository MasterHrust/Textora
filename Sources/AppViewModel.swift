import AppKit
import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    enum SettingsKeys {
        static let detailedCorrectionsEnabled = "overlay.detailedCorrections.enabled"
        static let smartAIEnabled = "overlay.smartAI.enabled"
        static let selectionAssistantBetaEnabled = SelectionAssistantSettings.Keys.enabled
        static let toolboxEnabled = SelectionAssistantSettings.Keys.toolboxEnabled
        static let floatingIconEnabled = SelectionAssistantSettings.Keys.floatingIconEnabled
        static let selectionAssistantDiagnosticsEnabled = SelectionAssistantSettings.Keys.diagnosticsEnabled
        static let easySwitchEnabled = EasySwitchSettings.Keys.enabled
        static let easySwitchAutoCorrectWrongLayout = EasySwitchSettings.Keys.autoCorrectWrongLayout
        static let easySwitchChangesKeyboardLayout = EasySwitchSettings.Keys.changesKeyboardLayout
        static let easySwitchMinimumWordLength = EasySwitchSettings.Keys.minimumWordLength
        static let easySwitchConfidenceThreshold = EasySwitchSettings.Keys.confidenceThreshold
        static let easySwitchDifferenceThreshold = EasySwitchSettings.Keys.differenceThreshold
        static let easySwitchEnglishEnabled = EasySwitchSettings.Keys.englishEnabled
        static let easySwitchRussianEnabled = EasySwitchSettings.Keys.russianEnabled
        static let easySwitchShowCorrectionNotification = EasySwitchSettings.Keys.showCorrectionNotification
        static let easySwitchPlaySoundOnCorrection = EasySwitchSettings.Keys.playSoundOnCorrection
        static let easySwitchPrivacyMode = EasySwitchSettings.Keys.privacyMode
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
            UserDefaults.standard.set(
                model.trimmingCharacters(in: .whitespacesAndNewlines),
                forKey: oldValue.modelUserDefaultsKey
            )
            model = storedModel(for: provider, allowLegacyValue: false)
            UserDefaults.standard.set(model, forKey: "model")
            availableModels = []
            modelCatalogError = ""
            Task { await refreshAvailableModels() }
        }
    }
    @Published var model: String = ""
    @Published var availableModels: [AIModelOption] = []
    @Published var isLoadingModels = false
    @Published var modelCatalogError = ""
    @Published var openAIKey: String = "" {
        didSet { providerKeyDidChange(.openai, from: oldValue, to: openAIKey) }
    }
    @Published var geminiKey: String = "" {
        didSet { providerKeyDidChange(.gemini, from: oldValue, to: geminiKey) }
    }
    @Published var claudeKey: String = "" {
        didSet { providerKeyDidChange(.claude, from: oldValue, to: claudeKey) }
    }
    @Published var customToken: String = ""
    /// OpenAI-compatible Chat Completions base URL (e.g. `https://api.example.com` or `https://host/v1`).
    @Published var customOpenAIBaseURL: String = ""
    @Published var appConsentRows: [AppConsentRow] = []
    @Published var hasAccessibilityPermission: Bool = false
    @Published var detailedCorrectionsEnabled: Bool = false
    @Published var selectionAssistantBetaEnabled: Bool = false
    @Published var toolboxEnabled: Bool = true {
        didSet {
            guard !isReloadingFromDefaults else { return }
            guard oldValue != toolboxEnabled else { return }
            SelectionAssistantSettings.setToolboxEnabled(toolboxEnabled)
        }
    }
    @Published var floatingIconEnabled: Bool = false {
        didSet {
            guard !isReloadingFromDefaults else { return }
            guard oldValue != floatingIconEnabled else { return }
            SelectionAssistantSettings.setFloatingIconEnabled(floatingIconEnabled)
        }
    }
    @Published var selectionAssistantDiagnosticsEnabled: Bool = false {
        didSet {
            guard !isReloadingFromDefaults else { return }
            guard oldValue != selectionAssistantDiagnosticsEnabled else { return }
            SelectionAssistantSettings.setDiagnosticsEnabled(selectionAssistantDiagnosticsEnabled)
        }
    }
    @Published var easySwitchEnabled: Bool = false
    @Published var easySwitchAutoCorrectWrongLayout: Bool = true
    @Published var easySwitchChangesKeyboardLayout: Bool = false
    @Published var easySwitchMinimumWordLength: Int = 3
    @Published var easySwitchConfidenceThreshold: Double = 0.65
    @Published var easySwitchDifferenceThreshold: Double = 0.35
    @Published var easySwitchEnglishEnabled: Bool = true
    @Published var easySwitchRussianEnabled: Bool = true
    @Published var easySwitchShowCorrectionNotification: Bool = true
    @Published var easySwitchPlaySoundOnCorrection: Bool = false
    @Published var easySwitchPrivacyMode: Bool = false
    @Published var easySwitchWhitelistText: String = ""
    @Published var onboardingStep: Int = 1
    @Published var onboardingErrorText: String = ""
    @Published var isOnboardingBusy: Bool = false
    @Published var isOnboardingComplete: Bool = false

    private let textService = TextAccessService()
    private let aiClient = AIClient()
    private var isReloadingFromDefaults = false
    private var autoSaveTask: DispatchWorkItem?
    private var accessibilityPermissionObserver: NSObjectProtocol?
    private var modelCatalogRequestID = UUID()

    init() {
        AccessibilityPermissionMonitor.shared.start()
        accessibilityPermissionObserver = NotificationCenter.default.addObserver(
            forName: .textoraAccessibilityPermissionDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let isTrusted = (notification.userInfo?["isTrusted"] as? Bool) ?? false
            Task { @MainActor [weak self] in
                self?.hasAccessibilityPermission = isTrusted
            }
        }
        reloadFromUserDefaults()
        isOnboardingComplete = UserDefaults.standard.bool(forKey: OnboardingDefaults.completedKey)
    }

    deinit {
        if let accessibilityPermissionObserver {
            NotificationCenter.default.removeObserver(accessibilityPermissionObserver)
        }
        autoSaveTask?.cancel()
    }

    /// Sync fields when reopening Settings so keys/model match disk (avoids stale SwiftUI state).
    func reloadFromUserDefaults() {
        isReloadingFromDefaults = true
        defer { isReloadingFromDefaults = false }
        EasySwitchSettings.registerDefaults()
        SelectionAssistantSettings.registerDefaults()
        provider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "provider") ?? "openai") ?? .openai
        model = storedModelForCurrentProvider()
        openAIKey = KeychainHelper.read(key: KeychainHelper.openAIKeyAccount) ?? ""
        geminiKey = KeychainHelper.read(key: KeychainHelper.geminiKeyAccount) ?? ""
        claudeKey = KeychainHelper.read(key: KeychainHelper.claudeKeyAccount) ?? ""
        customToken = KeychainHelper.read(key: KeychainHelper.customTokenAccount) ?? ""
        customOpenAIBaseURL = UserDefaults.standard.string(forKey: AIClient.openAICompatibleBaseURLUserDefaultsKey) ?? ""
        detailedCorrectionsEnabled = UserDefaults.standard.bool(forKey: SettingsKeys.detailedCorrectionsEnabled)
        selectionAssistantBetaEnabled = UserDefaults.standard.bool(forKey: SettingsKeys.selectionAssistantBetaEnabled)
        toolboxEnabled = UserDefaults.standard.bool(forKey: SettingsKeys.toolboxEnabled)
        floatingIconEnabled = UserDefaults.standard.bool(forKey: SettingsKeys.floatingIconEnabled)
        selectionAssistantDiagnosticsEnabled = UserDefaults.standard.bool(forKey: SettingsKeys.selectionAssistantDiagnosticsEnabled)
        easySwitchEnabled = UserDefaults.standard.bool(forKey: SettingsKeys.easySwitchEnabled)
        easySwitchAutoCorrectWrongLayout = UserDefaults.standard.bool(forKey: SettingsKeys.easySwitchAutoCorrectWrongLayout)
        easySwitchChangesKeyboardLayout = UserDefaults.standard.bool(forKey: SettingsKeys.easySwitchChangesKeyboardLayout)
        easySwitchMinimumWordLength = max(1, UserDefaults.standard.integer(forKey: SettingsKeys.easySwitchMinimumWordLength))
        easySwitchConfidenceThreshold = UserDefaults.standard.double(forKey: SettingsKeys.easySwitchConfidenceThreshold)
        easySwitchDifferenceThreshold = UserDefaults.standard.double(forKey: SettingsKeys.easySwitchDifferenceThreshold)
        easySwitchEnglishEnabled = UserDefaults.standard.bool(forKey: SettingsKeys.easySwitchEnglishEnabled)
        easySwitchRussianEnabled = UserDefaults.standard.bool(forKey: SettingsKeys.easySwitchRussianEnabled)
        easySwitchShowCorrectionNotification = UserDefaults.standard.bool(forKey: SettingsKeys.easySwitchShowCorrectionNotification)
        easySwitchPlaySoundOnCorrection = UserDefaults.standard.bool(forKey: SettingsKeys.easySwitchPlaySoundOnCorrection)
        easySwitchPrivacyMode = UserDefaults.standard.bool(forKey: SettingsKeys.easySwitchPrivacyMode)
        let easySwitchDictionary = UserDictionary()
        easySwitchWhitelistText = easySwitchDictionary.protectedWords().sorted().joined(separator: ", ")
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
                errorText = "API base URL is missing for Other"
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

    var recommendedModel: String {
        defaultModel(for: provider)
    }

    var hasCurrentProviderAPIKey: Bool {
        !apiKey(for: provider).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var modelPickerOptions: [AIModelOption] {
        let selected = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty, !availableModels.contains(where: { $0.id == selected }) else {
            return availableModels
        }
        return [AIModelOption(id: selected, displayName: selected)] + availableModels
    }

    func refreshAvailableModels() async {
        let requestedProvider = provider
        guard requestedProvider != .other else {
            availableModels = []
            modelCatalogError = ""
            isLoadingModels = false
            return
        }

        let key = apiKey(for: requestedProvider).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            availableModels = []
            modelCatalogError = "Add the API key to load available models."
            isLoadingModels = false
            return
        }

        let requestID = UUID()
        modelCatalogRequestID = requestID
        isLoadingModels = true
        modelCatalogError = ""
        do {
            let models = try await aiClient.availableModels(provider: requestedProvider, apiKey: key)
            guard modelCatalogRequestID == requestID, provider == requestedProvider else { return }
            availableModels = models
            if models.isEmpty {
                modelCatalogError = "The provider returned no compatible text models."
            }
        } catch {
            guard modelCatalogRequestID == requestID, provider == requestedProvider else { return }
            availableModels = []
            modelCatalogError = friendlyModelCatalogError(error.localizedDescription)
        }
        guard modelCatalogRequestID == requestID, provider == requestedProvider else { return }
        isLoadingModels = false
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
        UserDefaults.standard.set(trimmedModel, forKey: provider.modelUserDefaultsKey)
        UserDefaults.standard.set(trimmedModel, forKey: "model")
        UserDefaults.standard.set(
            customOpenAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: AIClient.openAICompatibleBaseURLUserDefaultsKey
        )
        SelectionAssistantSettings.setEnabled(true)
        UserDefaults.standard.set(toolboxEnabled, forKey: SettingsKeys.toolboxEnabled)
        UserDefaults.standard.set(floatingIconEnabled, forKey: SettingsKeys.floatingIconEnabled)
        UserDefaults.standard.set(selectionAssistantDiagnosticsEnabled, forKey: SettingsKeys.selectionAssistantDiagnosticsEnabled)
        UserDefaults.standard.set(easySwitchEnabled, forKey: SettingsKeys.easySwitchEnabled)
        UserDefaults.standard.set(easySwitchAutoCorrectWrongLayout, forKey: SettingsKeys.easySwitchAutoCorrectWrongLayout)
        UserDefaults.standard.set(easySwitchChangesKeyboardLayout, forKey: SettingsKeys.easySwitchChangesKeyboardLayout)
        UserDefaults.standard.set(max(1, easySwitchMinimumWordLength), forKey: SettingsKeys.easySwitchMinimumWordLength)
        UserDefaults.standard.set(easySwitchConfidenceThreshold, forKey: SettingsKeys.easySwitchConfidenceThreshold)
        UserDefaults.standard.set(easySwitchDifferenceThreshold, forKey: SettingsKeys.easySwitchDifferenceThreshold)
        UserDefaults.standard.set(easySwitchEnglishEnabled, forKey: SettingsKeys.easySwitchEnglishEnabled)
        UserDefaults.standard.set(easySwitchRussianEnabled, forKey: SettingsKeys.easySwitchRussianEnabled)
        UserDefaults.standard.set(easySwitchShowCorrectionNotification, forKey: SettingsKeys.easySwitchShowCorrectionNotification)
        UserDefaults.standard.set(easySwitchPlaySoundOnCorrection, forKey: SettingsKeys.easySwitchPlaySoundOnCorrection)
        UserDefaults.standard.set(easySwitchPrivacyMode, forKey: SettingsKeys.easySwitchPrivacyMode)
        let whitelist = easySwitchWhitelistText
            .split { $0.isWhitespace || $0 == "," || $0 == ";" || $0 == "\n" }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        let protectedWords = Array(Set(whitelist)).sorted()
        UserDefaults.standard.set(protectedWords, forKey: "easySwitch.userDictionary.whitelist")
        UserDefaults.standard.set([], forKey: "easySwitch.userDictionary.ignoredWords")
        NotificationCenter.default.post(name: EasySwitchManager.settingsDidChangeNotification, object: nil)
        NotificationCenter.default.post(name: SelectionAssistantSettings.settingsDidChangeNotification, object: nil)
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

    var settingsAutosaveToken: String {
        [
            provider.rawValue,
            model,
            openAIKey,
            geminiKey,
            claudeKey,
            customToken,
            customOpenAIBaseURL,
            String(toolboxEnabled),
            String(floatingIconEnabled),
            String(selectionAssistantDiagnosticsEnabled),
            String(easySwitchEnabled),
            String(easySwitchAutoCorrectWrongLayout),
            String(easySwitchChangesKeyboardLayout),
            String(easySwitchMinimumWordLength),
            String(format: "%.3f", easySwitchConfidenceThreshold),
            String(format: "%.3f", easySwitchDifferenceThreshold),
            String(easySwitchEnglishEnabled),
            String(easySwitchRussianEnabled),
            easySwitchWhitelistText,
            String(easySwitchShowCorrectionNotification),
            String(easySwitchPlaySoundOnCorrection),
            String(easySwitchPrivacyMode)
        ].joined(separator: "\u{1F}")
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
        onboardingStep = min(5, onboardingStep + 1)
    }

    func completeOnboarding() {
        isOnboardingComplete = true
        onboardingErrorText = ""
        saveSettings()
        UserDefaults.standard.set(true, forKey: OnboardingDefaults.completedKey)
        UserDefaults.standard.removeObject(forKey: OnboardingDefaults.skippedKey)
    }

    func prepareOnboardingSession() {
        onboardingStep = 1
        onboardingErrorText = ""
        isOnboardingBusy = false
        reloadFromUserDefaults()
        modelCatalogRequestID = UUID()
        availableModels = []
        modelCatalogError = ""
        isLoadingModels = false
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
                onboardingErrorText = "Set API URL for Other."
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

    private func friendlyModelCatalogError(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("401") || lower.contains("403") || lower.contains("api key") || lower.contains("permission") {
            return "Could not load models. Check the API key and its permissions."
        }
        if lower.contains("network") || lower.contains("timed out") || lower.contains("offline") {
            return "Could not load models. Check your internet connection."
        }
        return raw
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

    private func apiKey(for provider: AIProvider) -> String {
        switch provider {
        case .openai:
            return openAIKey
        case .gemini:
            return geminiKey
        case .claude:
            return claudeKey
        case .other:
            return customToken
        }
    }

    private func providerKeyDidChange(_ keyProvider: AIProvider, from oldValue: String, to newValue: String) {
        guard !isReloadingFromDefaults, provider == keyProvider else { return }
        let oldKey = oldValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let newKey = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard oldKey != newKey else { return }
        modelCatalogRequestID = UUID()
        availableModels = []
        modelCatalogError = ""
        isLoadingModels = false
    }

    private func storedModelForCurrentProvider() -> String {
        storedModel(for: provider, allowLegacyValue: true)
    }

    private func storedModel(for provider: AIProvider, allowLegacyValue: Bool) -> String {
        let defaultsStore = UserDefaults.standard
        let providerValue = defaultsStore.string(forKey: provider.modelUserDefaultsKey)
        let legacyValue = allowLegacyValue ? defaultsStore.string(forKey: "model") : nil
        let stored = (providerValue ?? legacyValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stored.isEmpty else { return "" }
        let defaults: Set<String> = [
            AIClient.Defaults.openAIModel,
            "gemini-1.5-pro",
            AIClient.Defaults.geminiModel,
            "claude-3-5-sonnet-latest",
            AIClient.Defaults.claudeModel,
            AIClient.Defaults.customModel
        ]
        if defaults.contains(stored) {
            defaultsStore.set("", forKey: provider.modelUserDefaultsKey)
            return ""
        }
        if providerValue == nil {
            defaultsStore.set(stored, forKey: provider.modelUserDefaultsKey)
        }
        return stored
    }

    func refreshAppConsents() {
        appConsentRows = textService.allAppConsents().map {
            AppConsentRow(id: $0.bundleID, bundleID: $0.bundleID, status: $0.status)
        }
    }

    func requestAccessibilityPermission() {
        textService.openAccessibilityPermissionSettings()
        // Permission is granted outside the app; re-check after a short delay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshAccessibilityPermissionStatus()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
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
