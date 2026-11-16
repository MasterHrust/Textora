import AppKit
import Carbon
import Combine
import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    /// Rendering fixtures never read credentials, start monitors or persist settings.
    let isPreview: Bool
    enum OnboardingInterfaceMode {
        case toolbox
        case hotKeys
    }

    enum SettingsKeys {
        static let detailedCorrectionsEnabled = "overlay.detailedCorrections.enabled"
        static let smartAIEnabled = "overlay.smartAI.enabled"
        static let selectionAssistantBetaEnabled = SelectionAssistantSettings.Keys.enabled
        static let toolboxEnabled = SelectionAssistantSettings.Keys.toolboxEnabled
        static let hotKeysModeEnabled = SelectionAssistantSettings.Keys.hotKeysModeEnabled
    }

    private enum OnboardingDefaults {
        static let completedKey = "onboarding.byok.completed.v2"
        static let skippedKey = "onboarding.byok.skipped"
    }

    struct AppConsentRow: Identifiable {
        let id: String
        let bundleID: String
        var status: TextAccessService.AppConsentStatus
    }

    @Published var originalText = ""
    @Published var rewrittenText = ""
    @Published var operation: RewriteOperation = .fixGrammar {
        didSet {
            guard !isReloadingFromDefaults, oldValue != operation else { return }
            SelectionAssistantSettings.setSelectedOperation(operation)
        }
    }
    @Published var translationLanguage: TranslationLanguage = .english {
        didSet {
            guard !isReloadingFromDefaults, oldValue != translationLanguage else { return }
            SelectionAssistantSettings.setTranslationLanguage(translationLanguage)
        }
    }
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
            modelCatalogRequestID = UUID()
            availableModels = []
            modelCatalogError = ""
            isLoadingModels = false
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
    @Published var customToken: String = "" {
        didSet { providerKeyDidChange(.other, from: oldValue, to: customToken) }
    }
    /// OpenAI-compatible Chat Completions base URL (e.g. `https://api.example.com` or `https://host/v1`).
    @Published var customOpenAIBaseURL: String = "" {
        didSet { providerKeyDidChange(.other, from: oldValue, to: customOpenAIBaseURL) }
    }
    @Published var localToken: String = "" {
        didSet { providerKeyDidChange(.local, from: oldValue, to: localToken) }
    }
    @Published var localBaseURL: String = "" {
        didSet { providerKeyDidChange(.local, from: oldValue, to: localBaseURL) }
    }
    var compatibleBaseURL: String {
        get { provider == .local ? localBaseURL : customOpenAIBaseURL }
        set {
            if provider == .local { localBaseURL = newValue }
            else { customOpenAIBaseURL = newValue }
        }
    }
    var compatibleToken: String {
        get { provider == .local ? localToken : customToken }
        set {
            if provider == .local { localToken = newValue }
            else { customToken = newValue }
        }
    }
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
    @Published var hotKeysModeEnabled: Bool = false {
        didSet {
            guard !isReloadingFromDefaults, oldValue != hotKeysModeEnabled else { return }
            SelectionAssistantSettings.setHotKeysModeEnabled(hotKeysModeEnabled)
        }
    }
    @Published var rewriteHotKey = TextoraHotKey(keyCode: 15, modifiers: UInt32(cmdKey | optionKey), isEnabled: true) {
        didSet {
            guard !isReloadingFromDefaults, oldValue != rewriteHotKey else { return }
            SelectionAssistantSettings.setHotKey(rewriteHotKey, for: .rewrite)
        }
    }
    @Published var translateHotKey = TextoraHotKey(keyCode: 17, modifiers: UInt32(cmdKey | optionKey), isEnabled: true) {
        didSet {
            guard !isReloadingFromDefaults, oldValue != translateHotKey else { return }
            SelectionAssistantSettings.setHotKey(translateHotKey, for: .translate)
        }
    }
    @Published var summaryHotKey = TextoraHotKey(keyCode: 1, modifiers: UInt32(controlKey | optionKey | cmdKey), isEnabled: true) {
        didSet {
            guard !isReloadingFromDefaults, oldValue != summaryHotKey else { return }
            SelectionAssistantSettings.setHotKey(summaryHotKey, for: .summary)
        }
    }
    @Published var offlineDictationEnabled = false {
        didSet {
            guard !isReloadingFromDefaults, oldValue != offlineDictationEnabled else { return }
            OfflineDictationSettings.isEnabled = offlineDictationEnabled
        }
    }
    @Published var dictationHotKey = TextoraHotKey(keyCode: 1, modifiers: UInt32(cmdKey | optionKey), isEnabled: true) {
        didSet {
            guard !isReloadingFromDefaults, oldValue != dictationHotKey else { return }
            SelectionAssistantSettings.setHotKey(dictationHotKey, for: .dictate)
        }
    }
    @Published var historyHotKey = TextoraHotKey(keyCode: 4, modifiers: UInt32(controlKey | optionKey | cmdKey), isEnabled: true) {
        didSet {
            guard !isReloadingFromDefaults, oldValue != historyHotKey else { return }
            SelectionAssistantSettings.setHotKey(historyHotKey, for: .history)
        }
    }
    @Published var selectedMicrophoneUID = "" {
        didSet {
            guard !isReloadingFromDefaults, oldValue != selectedMicrophoneUID else { return }
            OfflineDictationSettings.microphoneUID = selectedMicrophoneUID
        }
    }
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginRequiresApproval = false
    @Published private(set) var launchAtLoginErrorText = ""
    @Published private(set) var speechModelState: SpeechModelState = .notDownloaded
    @Published private(set) var microphones: [SpeechMicrophone] = []
    @Published var onboardingStep: Int = 1
    @Published var onboardingErrorText: String = ""
    @Published var isOnboardingBusy: Bool = false
    @Published var isOnboardingComplete: Bool = false

    private let textService = TextAccessService()
    private let aiClient = AIClient()
    private var isReloadingFromDefaults = false
    private var autoSaveTask: DispatchWorkItem?
    private var savedCloudPreferences: [String: String] = [:]
    private var savedAPIKeys: [AIProvider: String] = [:]

    private var cloudPreferences: [String: String] {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["provider": provider.rawValue, "model": trimmedModel,
                provider.modelUserDefaultsKey: trimmedModel,
                AIClient.openAICompatibleBaseURLUserDefaultsKey:
                    customOpenAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                AIClient.localBaseURLUserDefaultsKey: localBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)]
    }
    private var accessibilityPermissionObserver: NSObjectProtocol?
    private var modelCatalogRequestID = UUID()
    private var speechModelCancellable: AnyCancellable?

    init(isPreview: Bool = false) {
        self.isPreview = isPreview
        if isPreview {
            isReloadingFromDefaults = true
            return
        }
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
        speechModelCancellable = SpeechModelManager.shared.$state.sink { [weak self] state in
            self?.speechModelState = state
        }
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
        guard !isPreview else { return }
        isReloadingFromDefaults = true
        defer { isReloadingFromDefaults = false }
        SelectionAssistantSettings.registerDefaults()
        provider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "provider") ?? "openai") ?? .openai
        model = storedModelForCurrentProvider()
        openAIKey = KeychainHelper.read(key: KeychainHelper.openAIKeyAccount) ?? ""
        geminiKey = KeychainHelper.read(key: KeychainHelper.geminiKeyAccount) ?? ""
        claudeKey = KeychainHelper.read(key: KeychainHelper.claudeKeyAccount) ?? ""
        customToken = KeychainHelper.read(key: KeychainHelper.customTokenAccount) ?? ""
        customOpenAIBaseURL = UserDefaults.standard.string(forKey: AIClient.openAICompatibleBaseURLUserDefaultsKey) ?? ""
        localToken = KeychainHelper.read(key: KeychainHelper.localTokenAccount) ?? ""
        localBaseURL = UserDefaults.standard.string(forKey: AIClient.localBaseURLUserDefaultsKey) ?? ""
        detailedCorrectionsEnabled = UserDefaults.standard.bool(forKey: SettingsKeys.detailedCorrectionsEnabled)
        selectionAssistantBetaEnabled = UserDefaults.standard.bool(forKey: SettingsKeys.selectionAssistantBetaEnabled)
        toolboxEnabled = UserDefaults.standard.bool(forKey: SettingsKeys.toolboxEnabled)
        hotKeysModeEnabled = SelectionAssistantSettings.hotKeysModeEnabled()
        operation = SelectionAssistantSettings.selectedOperation()
        translationLanguage = SelectionAssistantSettings.translationLanguage()
        rewriteHotKey = SelectionAssistantSettings.hotKey(for: .rewrite)
        translateHotKey = SelectionAssistantSettings.hotKey(for: .translate)
        summaryHotKey = SelectionAssistantSettings.hotKey(for: .summary)
        OfflineDictationSettings.registerDefaults()
        offlineDictationEnabled = OfflineDictationSettings.isEnabled
        dictationHotKey = SelectionAssistantSettings.hotKey(for: .dictate)
        historyHotKey = SelectionAssistantSettings.hotKey(for: .history)
        selectedMicrophoneUID = OfflineDictationSettings.microphoneUID
        speechModelState = SpeechModelManager.shared.state
        microphones = SpeechAudioRecorder.microphones()
        refreshLaunchAtLoginStatus()
        hasAccessibilityPermission = textService.hasAccessibilityPermission()
        refreshAppConsents()
        savedCloudPreferences = cloudPreferences
        savedAPIKeys = [.openai: openAIKey, .gemini: geminiKey, .claude: claudeKey, .other: customToken, .local: localToken]
    }

    func refreshLaunchAtLoginStatus() {
        guard !isPreview else { return }
        let state = LaunchAtLoginManager.state
        launchAtLoginEnabled = state.isRegistered
        launchAtLoginRequiresApproval = state == .requiresApproval
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        launchAtLoginErrorText = ""
        do {
            try LaunchAtLoginManager.setEnabled(enabled)
        } catch {
            launchAtLoginErrorText = "Could not update Login Items: \(error.localizedDescription)"
        }
        refreshLaunchAtLoginStatus()
    }

    func openLoginItemsSettings() {
        LaunchAtLoginManager.openSystemSettings()
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
        case .local:
            key = localToken
        }
        guard provider.isOpenAICompatible || !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorText = "API key is missing for selected provider"
            return
        }
        if provider.isOpenAICompatible {
            guard AIClient.validatedOpenAICompatibleURL(from: compatibleBaseURL) != nil else {
                errorText = "Enter a valid API base URL for \(provider.displayName)."
                return
            }
            guard provider != .local || !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                errorText = "Choose a local model or enter its ID."
                return
            }
        }
        isLoading = true
        errorText = ""
        let source = originalText
        let historyToken = RecentResults.shared.consentToken
        do {
            rewrittenText = try await aiClient.rewriteText(
                provider: provider,
                model: model,
                apiKey: key,
                text: source,
                operation: operation
            )
            RecentResults.shared.record(OperationResult(kind: .rewrite, source: source, result: rewrittenText), token: historyToken)
        } catch {
            errorText = error.localizedDescription
        }
        isLoading = false
    }

    var recommendedModel: String {
        defaultModel(for: provider)
    }

    var canLoadModels: Bool {
        if provider.isOpenAICompatible {
            return AIClient.validatedOpenAICompatibleURL(from: compatibleBaseURL) != nil
        }
        return !apiKey(for: provider).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var modelPickerOptions: [AIModelOption] {
        let selected = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty, !availableModels.contains(where: { $0.id == selected }) else {
            return availableModels
        }
        return [AIModelOption(id: selected, displayName: selected)] + availableModels
    }

    func refreshAvailableModels() async {
        guard !isPreview else { return }
        let requestID = UUID()
        modelCatalogRequestID = requestID
        let requestedProvider = provider
        let baseURL = compatibleBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedProvider.isOpenAICompatible || AIClient.validatedOpenAICompatibleURL(from: baseURL) != nil else {
            availableModels = []
            modelCatalogError = "Enter a valid API base URL to load models."
            isLoadingModels = false
            return
        }

        let key = apiKey(for: requestedProvider).trimmingCharacters(in: .whitespacesAndNewlines)
        guard requestedProvider.isOpenAICompatible || !key.isEmpty else {
            availableModels = []
            modelCatalogError = "Add the API key to load available models."
            isLoadingModels = false
            return
        }

        isLoadingModels = true
        modelCatalogError = ""
        do {
            let models = try await aiClient.availableModels(provider: requestedProvider, apiKey: key, baseURL: baseURL)
            guard modelCatalogRequestID == requestID, provider == requestedProvider else { return }
            availableModels = models
            if requestedProvider.isOpenAICompatible, let first = models.first, model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model = first.id
            }
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

    @discardableResult
    func saveSettings() -> Bool {
        guard !isPreview else { return true }
        // Only save edits made in this window. Another retained window may
        // have changed the provider/model since this one loaded its snapshot.
        for (key, value) in cloudPreferences where savedCloudPreferences[key] != value {
            UserDefaults.standard.set(value, forKey: key)
            savedCloudPreferences[key] = value
        }
        // Interface, rewrite, language, shortcuts and dictation preferences
        // persist at the moment the user changes them. A retained Settings or
        // onboarding window must not overwrite newer choices from the toolbar.
        let account: String
        let key: String
        switch provider {
        case .openai: account = KeychainHelper.openAIKeyAccount; key = openAIKey
        case .gemini: account = KeychainHelper.geminiKeyAccount; key = geminiKey
        case .claude: account = KeychainHelper.claudeKeyAccount; key = claudeKey
        case .other: account = KeychainHelper.customTokenAccount; key = customToken
        case .local: account = KeychainHelper.localTokenAccount; key = localToken
        }
        guard savedAPIKeys[provider] != key else { return true }
        let keyResult = KeychainHelper.save(key: account, value: key)
        if case .failure(let error) = keyResult {
            errorText = error.localizedDescription
            onboardingErrorText = error.localizedDescription
            return false
        }
        savedAPIKeys[provider] = key
        return true
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
            localToken,
            localBaseURL,
            String(toolboxEnabled),
            String(hotKeysModeEnabled),
            operation.rawValue,
            translationLanguage.rawValue,
            String(rewriteHotKey.keyCode), String(rewriteHotKey.modifiers), String(rewriteHotKey.isEnabled),
            String(translateHotKey.keyCode), String(translateHotKey.modifiers), String(translateHotKey.isEnabled),
            String(summaryHotKey.keyCode), String(summaryHotKey.modifiers), String(summaryHotKey.isEnabled),
            String(offlineDictationEnabled),
            String(dictationHotKey.keyCode), String(dictationHotKey.modifiers), String(dictationHotKey.isEnabled),
            selectedMicrophoneUID
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
        onboardingStep = min(8, onboardingStep + 1)
    }

    var onboardingInterfaceMode: OnboardingInterfaceMode {
        if hotKeysModeEnabled && !toolboxEnabled { return .hotKeys }
        return .toolbox
    }

    var hasValidOnboardingInterfaceSelection: Bool {
        switch onboardingInterfaceMode {
        case .hotKeys:
            return rewriteHotKey.isEnabled || translateHotKey.isEnabled
        case .toolbox:
            return toolboxEnabled
        }
    }

    func selectOnboardingInterfaceMode(_ mode: OnboardingInterfaceMode) {
        switch mode {
        case .toolbox:
            updateInterfaceModes(toolbox: true, hotKeys: false)
        case .hotKeys:
            updateInterfaceModes(toolbox: false, hotKeys: true)
            rewriteHotKey.isEnabled = true
            translateHotKey.isEnabled = true
        }
    }

    func setInterfaceMode(_ mode: OnboardingInterfaceMode, enabled: Bool) {
        guard enabled else { return }
        switch mode {
        case .toolbox:
            updateInterfaceModes(toolbox: true, hotKeys: false)
        case .hotKeys:
            updateInterfaceModes(toolbox: false, hotKeys: true)
            if !rewriteHotKey.isEnabled && !translateHotKey.isEnabled {
                rewriteHotKey.isEnabled = true
                translateHotKey.isEnabled = true
            }
        }
    }

    private func updateInterfaceModes(toolbox: Bool, hotKeys: Bool) {
        if isPreview {
            toolboxEnabled = toolbox
            hotKeysModeEnabled = hotKeys
            return
        }
        isReloadingFromDefaults = true
        toolboxEnabled = toolbox
        hotKeysModeEnabled = hotKeys
        isReloadingFromDefaults = false
        SelectionAssistantSettings.setInterfaceModes(
            toolbox: toolbox,
            hotKeys: hotKeys
        )
    }

    @discardableResult
    func completeOnboarding() -> Bool {
        onboardingErrorText = ""
        guard saveSettings() else { return false }
        isOnboardingComplete = true
        UserDefaults.standard.set(true, forKey: "features.personalization.v1.seen")
        UserDefaults.standard.set(true, forKey: OnboardingDefaults.completedKey)
        UserDefaults.standard.removeObject(forKey: OnboardingDefaults.skippedKey)
        return true
    }

    func continueWithoutCloudAI() {
        onboardingErrorText = ""
        moveOnboardingNext()
    }

    func setOfflineDictationEnabled(_ enabled: Bool) {
        offlineDictationEnabled = enabled
        if enabled {
            dictationHotKey.isEnabled = true
            Task { _ = await SpeechAudioRecorder.requestPermission() }
        }
    }

    func downloadSpeechModel() {
        setOfflineDictationEnabled(true)
        SpeechModelManager.shared.download()
    }

    func pauseSpeechModelDownload() { SpeechModelManager.shared.pause() }
    func cancelSpeechModelDownload() { SpeechModelManager.shared.cancel() }
    func verifySpeechModel() { SpeechModelManager.shared.verify() }
    func deleteSpeechModel() { SpeechModelManager.shared.deleteModel() }
    func refreshMicrophones() { microphones = SpeechAudioRecorder.microphones() }

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
        case .local, .other:
            key = compatibleToken.trimmingCharacters(in: .whitespacesAndNewlines)
            validationModel = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultModel(for: provider) : model
            if AIClient.validatedOpenAICompatibleURL(from: compatibleBaseURL) == nil {
                onboardingErrorText = "Enter a valid API URL for \(provider.displayName)."
                return false
            }
            if provider == .local && validationModel.isEmpty {
                onboardingErrorText = "Choose a local model or enter its ID."
                return false
            }
        }
        guard provider.isOpenAICompatible || !key.isEmpty else {
            onboardingErrorText = "Add an API key for the selected provider."
            return false
        }
        isOnboardingBusy = true
        defer { isOnboardingBusy = false }
        guard saveSettings() else { return false }
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
            self?.autoSaveTask = nil
            self?.saveSettings()
        }
        autoSaveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
    }

    func flushPendingSave() {
        guard autoSaveTask != nil else { return }
        autoSaveTask?.cancel()
        autoSaveTask = nil
        _ = saveSettings()
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
        case .local:
            return ""
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
        case .local:
            return localToken
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
        // A model that used to be a default may still be an explicit user
        // choice. Preserve it across releases just like a custom model.
        if providerValue == nil {
            defaultsStore.set(stored, forKey: provider.modelUserDefaultsKey)
        }
        return stored
    }

    func refreshAppConsents() {
        guard !isPreview else { return }
        appConsentRows = textService.allAppConsents().map {
            AppConsentRow(id: $0.bundleID, bundleID: $0.bundleID, status: $0.status)
        }
    }

    func requestAccessibilityPermission() {
        textService.openAccessibilitySettings()
        // Permission is granted outside the app; re-check after a short delay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshAccessibilityPermissionStatus()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshAccessibilityPermissionStatus()
        }
    }

    func refreshAccessibilityPermissionStatus() {
        guard !isPreview else { return }
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
