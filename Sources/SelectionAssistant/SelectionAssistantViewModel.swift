import AppKit
import Foundation
import Combine

enum TranslationLanguage: String, CaseIterable, Identifiable {
    case english
    case russian
    case spanish
    case portuguese
    case german
    case french
    case italian
    case chinese
    case japanese
    case korean
    case arabic
    case turkish
    case ukrainian
    case polish
    case dutch
    case hindi
    case indonesian
    case vietnamese
    case thai
    case hebrew
    case greek
    case czech
    case swedish
    case romanian

    var id: String { rawValue }

    var flag: String {
        switch self {
        case .english: return "🇬🇧"
        case .russian: return "🇷🇺"
        case .spanish: return "🇪🇸"
        case .portuguese: return "🇵🇹"
        case .german: return "🇩🇪"
        case .french: return "🇫🇷"
        case .italian: return "🇮🇹"
        case .chinese: return "🇨🇳"
        case .japanese: return "🇯🇵"
        case .korean: return "🇰🇷"
        case .arabic: return "🇸🇦"
        case .turkish: return "🇹🇷"
        case .ukrainian: return "🇺🇦"
        case .polish: return "🇵🇱"
        case .dutch: return "🇳🇱"
        case .hindi: return "🇮🇳"
        case .indonesian: return "🇮🇩"
        case .vietnamese: return "🇻🇳"
        case .thai: return "🇹🇭"
        case .hebrew: return "🇮🇱"
        case .greek: return "🇬🇷"
        case .czech: return "🇨🇿"
        case .swedish: return "🇸🇪"
        case .romanian: return "🇷🇴"
        }
    }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .russian: return "Russian"
        case .spanish: return "Spanish"
        case .portuguese: return "Portuguese"
        case .german: return "German"
        case .french: return "French"
        case .italian: return "Italian"
        case .chinese: return "Chinese"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .arabic: return "Arabic"
        case .turkish: return "Turkish"
        case .ukrainian: return "Ukrainian"
        case .polish: return "Polish"
        case .dutch: return "Dutch"
        case .hindi: return "Hindi"
        case .indonesian: return "Indonesian"
        case .vietnamese: return "Vietnamese"
        case .thai: return "Thai"
        case .hebrew: return "Hebrew"
        case .greek: return "Greek"
        case .czech: return "Czech"
        case .swedish: return "Swedish"
        case .romanian: return "Romanian"
        }
    }
}

@MainActor
final class SelectionAssistantViewModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case waiting
        case meaningUnclear
        case checking
        case ready
        case noChanges
        case applying
        case error(String)
    }

    enum TranslationStatus: Equatable {
        case idle
        case translating
        case ready
        case error(String)
    }

    enum PresentationMode: Equatable {
        case standard
        case hotKeyRewrite
        case hotKeyTranslate
    }

    enum ReviewState { case unknown, clean, suggestion, error, meaningUnclear }
    @Published private(set) var meaningQuestions: [MeaningQuestion] = []
    @Published var meaningAnswers: [Int: String] = [:]
    @Published var customMeaning = "" {
        didSet {
            if !customMeaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                meaningAnswers = [:]
            }
        }
    }
    private var meaningClarification = ""

    var unansweredMeaningQuestionIndices: [Int] {
        meaningQuestions.indices.filter { index in
            !(meaningAnswers[index].map { meaningQuestions[index].options.contains($0) } ?? false)
        }
    }

    var canClarifyMeaning: Bool {
        !customMeaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (!meaningQuestions.isEmpty && unansweredMeaningQuestionIndices.isEmpty)
    }

    func clarifyMeaning() {
        guard status == .meaningUnclear, canClarifyMeaning, let currentContext else { return }
        meaningClarification = clarificationForPreview
        reviewedTexts = [:]
        reviews = [:]
        startCheck(for: currentContext)
    }

    func selectMeaningAnswer(_ answer: String, for index: Int) {
        guard meaningQuestions.indices.contains(index), meaningQuestions[index].options.contains(answer) else { return }
        customMeaning = ""
        meaningAnswers[index] = answer
    }

    func rejectMeaningOptions() {
        meaningAnswers = [:]
    }

    var clarificationForPreview: String {
        let custom = customMeaning.trimmingCharacters(in: .whitespacesAndNewlines)
        // An explicit correction replaces previous guesses, including earlier rounds.
        if !custom.isEmpty { return "User's intended meaning (replaces earlier interpretations):\n" + custom }
        let answers = meaningQuestions.indices.compactMap { index -> String? in
            guard let answer = meaningAnswers[index], meaningQuestions[index].options.contains(answer) else { return nil }
            return "\(meaningQuestions[index].question): \(answer)"
        }
        return meaningClarification + "\n" + answers.joined(separator: "\n")
    }

    private func resetMeaning() {
        meaningQuestions = []
        meaningAnswers = [:]
        customMeaning = ""
        meaningClarification = ""
    }
    @Published private(set) var reviews: [RewriteOperation: ReviewState] = [:]
    @Published private(set) var recommendation: RewriteOperation?
    private var reviewedTexts: [RewriteOperation: String] = [:]
    private var selectingRecommendation = false
    private var manuallySelectedOperation: RewriteOperation?

    @Published var operation: RewriteOperation {
        didSet {
            guard oldValue != operation else { return }
            if !selectingRecommendation { SelectionAssistantSettings.setSelectedOperation(operation) }
            if selectingRecommendation || isTranslationMode || applicationNeedsSelection || isApplying { return }
            manuallySelectedOperation = operation
            explicitlyRequestedRewrite = true
            if status == .meaningUnclear { return }
            if status == .checking, UserDefaults.standard.bool(forKey: AppViewModel.SettingsKeys.smartAIEnabled) { return }
            if reviews[operation] == .error {
                rewrittenText = ""
                status = .error("Empty rewrite. Please retry.")
                return
            }
            if let result = reviewedTexts[operation] {
                rewrittenText = result
                status = normalized(result) == normalized(originalText) ? .noChanges : .ready
                rememberResult()
                return
            }
            if let context = currentContext {
                startCheck(for: context)
            }
        }
    }
    @Published var translationLanguage: TranslationLanguage = .english {
        didSet {
            guard oldValue != translationLanguage else { return }
            translationTask?.cancel()
            translationRequestID += 1
            SelectionAssistantSettings.setTranslationLanguage(translationLanguage)
            translatedText = ""
            translationStatus = .idle
            resultNotice = ""
            isLanguagePickerExpanded = false
        }
    }
    @Published private(set) var status: Status = .idle
    @Published private(set) var translationStatus: TranslationStatus = .idle
    @Published private(set) var originalText: String = ""
    @Published private(set) var rewrittenText: String = ""
    @Published private(set) var translatedText: String = ""
    @Published private(set) var resultNotice = ""
    @Published var isLanguagePickerExpanded = false
    @Published private(set) var presentationMode: PresentationMode = .standard
    @Published private(set) var isTranslationMode = false
    @Published private(set) var applicationNeedsSelection = false

    private let aiClient = AIClient()
    private let history: RecentResults
    private let styleStore: PersonalStyleStore
    private var styleRefreshAllowsCopyOnly = false
    private let pasteboard: NSPasteboard
    private let translator: (@MainActor (String, TranslationLanguage) async throws -> String)?
    private var currentContext: TextAccessService.FocusedTextContext?
    private var currentFingerprint: String?
    private var rewriteTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var applyTask: Task<Void, Never>?
    @Published private(set) var isApplyingTranslation = false
    var isApplying: Bool { status == .applying || isApplyingTranslation }
    private(set) var requestID = 0
    private var translationRequestID = 0
    private var styleSubscription: AnyCancellable?
    private var requestStyle: StyleProfile?
    private var historyToken: Int?
    private var historyID = UUID()
    private var explicitlyRequestedRewrite = false
    var sourceBundleID: String? { currentContext?.targetBundleID }

    private func styleChanged() {
        guard let context = currentContext, !isApplying,
              styleStore.profile(for: context.targetBundleID)?.cacheKey != requestStyle?.cacheKey else { return }
        explicitlyRequestedRewrite = true
        if isTranslationMode {
            translationTask?.cancel()
            translationRequestID += 1
            translationStatus = .idle
            translate()
        } else {
            styleRefreshAllowsCopyOnly = applicationNeedsSelection
            startCheck(for: context)
        }
    }

    private func rememberResult(status: String = "Ready") {
        let text = isTranslationMode ? translatedText : rewrittenText
        guard !text.isEmpty, let context = currentContext else { return }
        history.record(OperationResult(id: historyID, kind: isTranslationMode ? .translate : .rewrite,
            source: originalText, result: text, application: OriginApplication.name(context.targetBundleID),
            language: isTranslationMode ? translationLanguage.displayName : nil, style: requestStyle?.name, status: status), token: historyToken)
    }

    init(pasteboard: NSPasteboard = .general,
         translator: (@MainActor (String, TranslationLanguage) async throws -> String)? = nil,
         styleStore: PersonalStyleStore? = nil,
         history: RecentResults? = nil) {
        self.history = history ?? .shared
        self.styleStore = styleStore ?? .shared
        self.pasteboard = pasteboard
        self.translator = translator
        SelectionAssistantSettings.registerDefaults()
        operation = SelectionAssistantSettings.selectedOperation()
        if UserDefaults.standard.object(forKey: SelectionAssistantSettings.Keys.translationLanguage) != nil {
            translationLanguage = SelectionAssistantSettings.translationLanguage()
        } else if let legacy = UserDefaults.standard.string(forKey: "inlineTranslate.lastTargetLanguage"),
                  let saved = TranslationLanguage.allCases.first(where: {
                      $0.displayName.caseInsensitiveCompare(legacy) == .orderedSame
                  }) {
            translationLanguage = saved
            SelectionAssistantSettings.setTranslationLanguage(saved)
        }
        styleSubscription = NotificationCenter.default.publisher(for: PersonalStyleStore.changed, object: self.styleStore)
            .sink { [weak self] _ in Task { @MainActor in self?.styleChanged() } }
    }

    var canApply: Bool {
        guard !applicationNeedsSelection else { return false }
        guard !isApplyingTranslation else { return false }
        guard case .ready = status else { return false }
        return !rewrittenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && normalized(rewrittenText) != normalized(originalText)
    }

    var canTranslate: Bool {
        !isApplying && translationStatus != .translating && currentContext != nil && !originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canUseTranslation: Bool {
        translationStatus == .ready && !translatedText.isEmpty && !isApplying
    }

    func selectTranslationLanguage(_ language: TranslationLanguage) {
        guard !isApplying else { return }
        let changed = translationLanguage != language
        translationLanguage = language
        isLanguagePickerExpanded = false
        // Changing the language of an existing translation is itself an
        // explicit translation request in both presentations.
        if isTranslationMode, changed || translationStatus != .ready { translate() }
    }

    var showsTranslationPanel: Bool {
        isLanguagePickerExpanded || hasTranslationContent || hasRewritePreview
    }

    var hasTranslationContent: Bool {
        if isTranslationMode { return true }
        switch translationStatus {
        case .idle:
            return false
        case .translating, .ready, .error:
            return true
        }
    }

    var hasRewritePreview: Bool {
        !originalText.isEmpty
    }

    func prepareForSelectionMove() {
        isTranslationMode = false
        resetMeaning()
        applicationNeedsSelection = false
        resultNotice = ""
        applyTask?.cancel()
        isApplyingTranslation = false
        rewriteTask?.cancel()
        translationTask?.cancel()
        requestID += 1
        translationRequestID += 1
        currentFingerprint = nil
        currentContext = nil
        reviewedTexts = [:]
        reviews = [:]
        recommendation = nil
        manuallySelectedOperation = nil
        rewrittenText = ""
        translatedText = ""
        translationStatus = .idle
        status = .waiting
    }

    func clear() {
        resetMeaning()
        applicationNeedsSelection = false
        // Translation is an explicit action for one selection, not a sticky workflow.
        isTranslationMode = false
        applyTask?.cancel()
        isApplyingTranslation = false
        rewriteTask?.cancel()
        rewriteTask = nil
        translationTask?.cancel()
        translationTask = nil
        requestID += 1
        translationRequestID += 1
        currentContext = nil
        reviewedTexts = [:]
        reviews = [:]
        recommendation = nil
        currentFingerprint = nil
        originalText = ""
        rewrittenText = ""
        translatedText = ""
        resultNotice = ""
        status = .idle
        translationStatus = .idle
        isLanguagePickerExpanded = false
        presentationMode = .standard
    }

    func prepareHotKeyPresentation(_ action: TextoraHotKeyAction) {
        if action == .translate { enterTranslationMode() }
        else { isTranslationMode = false }
        selectingRecommendation = true
        operation = SelectionAssistantSettings.selectedOperation()
        selectingRecommendation = false
        translationLanguage = SelectionAssistantSettings.translationLanguage()
        presentationMode = action == .rewrite ? .hotKeyRewrite : .hotKeyTranslate
        isLanguagePickerExpanded = false
    }

    func setSelectionContext(
        _ context: TextAccessService.FocusedTextContext,
        automaticallyCheck: Bool = true,
        preservePresentation: Bool = false
    ) {
        if !preservePresentation { presentationMode = .standard }
        let fingerprint = Self.fingerprint(for: context)
        if !applicationNeedsSelection, fingerprint == currentFingerprint, isTranslationMode, translationStatus != .idle { return }
        if !applicationNeedsSelection, fingerprint == currentFingerprint, !rewrittenText.isEmpty || status == .checking || status == .noChanges || status == .meaningUnclear {
            return
        }
        // Preserve translation only for an explicit HotKey Translate invocation.
        // Repeated notifications above retain the current selection's preview.
        if presentationMode != .hotKeyTranslate { isTranslationMode = false }
        currentContext = context
        styleRefreshAllowsCopyOnly = false
        historyID = UUID()
        historyToken = history.consentToken
        explicitlyRequestedRewrite = preservePresentation && presentationMode == .hotKeyRewrite
        resetMeaning()
        applicationNeedsSelection = false
        resultNotice = ""
        applyTask?.cancel()
        isApplyingTranslation = false
        manuallySelectedOperation = nil
        reviewedTexts = [:]
        reviews = [:]
        recommendation = nil
        rewriteTask?.cancel()
        translationTask?.cancel()
        requestID += 1
        translationRequestID += 1
        currentFingerprint = fingerprint
        originalText = context.text
        rewrittenText = ""
        translatedText = ""
        translationStatus = .idle
        isLanguagePickerExpanded = false
        if automaticallyCheck {
            if isTranslationMode { status = .waiting }
            else { startCheck(for: context) }
        } else {
            status = .waiting
        }
    }

    func apply(onFinished: @escaping () -> Void) {
        guard canApply, let context = currentContext else { return }
        rememberResult(status: "Insertion requested")
        status = .applying
        let text = rewrittenText
        let generation = requestID
        applyTask = Task { [weak self] in
            guard let self, self.requestID == generation else { return }
            let result = await SelectionTextWorker.shared.apply(text, captured: context)
            guard !Task.isCancelled, self.requestID == generation else { return }
            self.completeApplication(result, onFinished: onFinished)
        }
    }

    func completeApplication(_ result: TextAccessService.ApplyResult, onFinished: () -> Void) {
        switch result {
        case .success, .dispatched:
            rememberResult(status: result == .success ? "Inserted" : "Sent to app")
            // Close quietly when the write was sent. Lack of AX readback is
            // neither a failed insertion nor permission to send another paste.
            clear()
            onFinished()
        case .clipboardArmed, .failed, .unsupportedTarget, .rejected:
            rememberResult(status: "Copied after insertion refusal")
            rewriteTask?.cancel()
            translationTask?.cancel()
            requestID += 1
            translationRequestID += 1
            reviews = [:]
            reviewedTexts = [:]
            recommendation = nil
            applicationNeedsSelection = true
            isApplyingTranslation = false
            let text = isTranslationMode ? translatedText : rewrittenText
            let failureMessage: String
            if case .rejected(let reason) = result { failureMessage = reason.message }
            else { failureMessage = "Could not insert." }
            resultNotice = writeToClipboard(text)
                ? "\(failureMessage) Copied to clipboard - press ⌘V."
                : "Could not insert or copy. Select and copy the result below."
            status = .ready
        }
    }

    func copyApplicationResult() {
        copyResult(isTranslationMode ? translatedText : rewrittenText)
    }

    func copyRewrite() {
        guard !rewrittenText.isEmpty else { return }
        copyResult(rewrittenText)
    }

    private func copyResult(_ text: String) {
        rememberResult(status: "Copied")
        guard !text.isEmpty else { return }
        resultNotice = writeToClipboard(text)
            ? "Copied - press ⌘V" : "Could not copy"
    }

    private func writeToClipboard(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    func applyTranslation(onFinished: @escaping () -> Void = {}) {
        guard canUseTranslation, let context = currentContext else { return }
        // An invalid insertion target does not invalidate the captured source
        // or the translated result. Subsequent clicks copy without retrying AX.
        if applicationNeedsSelection {
            copyTranslation()
            return
        }
        rememberResult(status: "Insertion requested")
        let text = translatedText
        let generation = translationRequestID
        isApplyingTranslation = true
        applyTask = Task {
            let result = await SelectionTextWorker.shared.apply(text, captured: context)
            guard !Task.isCancelled, generation == translationRequestID else { return }
            isApplyingTranslation = false
            completeApplication(result, onFinished: onFinished)
        }
    }

    private func enterTranslationMode() {
        resetMeaning()
        isTranslationMode = true
        rewriteTask?.cancel()
        rewriteTask = nil
        requestID += 1
        rewrittenText = ""
        reviewedTexts = [:]
        reviews = [:]
        recommendation = nil
        manuallySelectedOperation = nil
        status = .idle
    }

    func returnToRewrite() {
        guard !isApplying else { return }
        translationTask?.cancel()
        translationRequestID += 1
        translationStatus = .idle
        translatedText = ""
        resultNotice = ""
        isTranslationMode = false
        if let currentContext { startCheck(for: currentContext) }
    }

    func translate() {
        guard canTranslate else { return }
        enterTranslationMode()
        translationTask?.cancel()
        translationRequestID += 1
        let id = translationRequestID

        let text = originalText
        let language = translationLanguage
        requestStyle = styleStore.profile(for: sourceBundleID)
        let style = requestStyle
        historyToken = history.consentToken
        historyID = UUID()

        translatedText = ""
        resultNotice = ""
        translationStatus = .translating
        translationTask = Task { @MainActor in
            do {
                let out: String
                if let translator { out = try await translator(text, language) }
                else {
                    guard let config = Self.providerConfiguration() else { throw FeatureError.noProvider }
                    out = try await aiClient.translateText(provider: config.provider, model: config.model, apiKey: config.key,
                        text: text, targetLanguage: language.displayName, style: style)
                }
                guard id == translationRequestID, !Task.isCancelled else { return }
                acceptTranslation(out)
            } catch is CancellationError {
                guard id == translationRequestID else { return }
            } catch {
                guard id == translationRequestID else { return }
                translatedText = ""
                translationStatus = .error(error.localizedDescription)
            }
        }
    }

    func acceptTranslation(_ text: String) {
        guard isTranslationMode, currentContext != nil else { return }
        translatedText = GeneratedTextStyle.shortDashes(text.trimmingCharacters(in: .whitespacesAndNewlines))
        translationStatus = translatedText.isEmpty ? .error("Empty translation") : .ready
        rememberResult()
    }

    @discardableResult
    func copyTranslation() -> Bool {
        guard case .ready = translationStatus,
              !translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        rememberResult(status: "Copied")
        let copied = writeToClipboard(translatedText)
        resultNotice = copied ? "Copied - press ⌘V" : "Could not copy"
        return copied
    }

    func retryReview() {
        guard !isTranslationMode, !applicationNeedsSelection else { return }
        guard let currentContext else { return }
        reviewedTexts = [:]
        reviews = [:]
        recommendation = nil
        startCheck(for: currentContext)
    }

    private func startCheck(for context: TextAccessService.FocusedTextContext) {
        guard !isTranslationMode else { return }
        rewriteTask?.cancel()
        requestID += 1
        let id = requestID
        originalText = context.text
        rewrittenText = ""
        meaningQuestions = []
        meaningAnswers = [:]
        customMeaning = ""

        guard !shouldSkipProtectedOnly(context.text) else {
            status = .noChanges
            return
        }

        let config = providerConfig()
        guard let config else {
            status = .error("Add AI key in Settings")
            return
        }

        status = .checking
        let text = context.text
        let operation = operation
        let smart = UserDefaults.standard.bool(forKey: AppViewModel.SettingsKeys.smartAIEnabled)
        let clarification = meaningClarification
        requestStyle = styleStore.profile(for: context.targetBundleID)
        let style = requestStyle
        let key = [config.provider.rawValue, config.model, String(config.key.hashValue),
                   UserDefaults.standard.string(forKey: AIClient.openAICompatibleBaseURLUserDefaultsKey) ?? "",
                   smart ? "smart" : operation.rawValue, text, clarification, style?.cacheKey ?? "no-style"].joined(separator: "\u{1f}")
        rewriteTask = Task { @MainActor in
            do {
                if smart {
                    let results = try await RewriteReviewService.shared.review(key: key) { [aiClient] in
                        try await aiClient.overlaySuggestions(
                        provider: config.provider, model: config.model, apiKey: config.key,
                        text: text, requireCompleteReview: true, clarification: clarification, style: style
                        )
                    }
                    guard id == requestID, !Task.isCancelled else { return }
                    acceptReview(results, generation: id)
                    return
                }
                let results = try await RewriteReviewService.shared.review(key: key) { [aiClient] in
                    let results = try await aiClient.overlaySuggestions(
                    provider: config.provider,
                    model: config.model,
                    apiKey: config.key,
                    text: text,
                    requireCompleteReview: true,
                    selectedOperation: operation,
                    clarification: clarification, style: style
                )
                    return results.filter { $0.operation == operation }
                }
                guard id == requestID, !Task.isCancelled else { return }
                acceptReview(results, generation: id)
            } catch is CancellationError {
                guard id == requestID else { return }
            } catch {
                guard id == requestID else { return }
                rewrittenText = ""
                reviews = Dictionary(uniqueKeysWithValues: RewriteOperation.allCases.map { ($0, .error) })
                status = .error(error.localizedDescription)
            }
        }
    }

    func acceptReview(_ results: [OverlaySuggestion], generation: Int) {
        guard !isTranslationMode, (!applicationNeedsSelection || styleRefreshAllowsCopyOnly), generation == requestID, currentContext != nil else { return }
        meaningQuestions = results.first(where: { !$0.meaningQuestions.isEmpty })?.meaningQuestions ?? []
        meaningAnswers = [:]
        customMeaning = ""
        if !meaningQuestions.isEmpty {
            rewrittenText = ""
            reviewedTexts = [:]
            recommendation = nil
            reviews = Dictionary(uniqueKeysWithValues: results.map { ($0.operation, .meaningUnclear) })
            status = .meaningUnclear
            return
        }
        reviewedTexts = Dictionary(results.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { ($0.operation, $0.text) }, uniquingKeysWith: { _, latest in latest })
        reviews = reviewedTexts.mapValues { normalized($0) == normalized(originalText) ? .clean : .suggestion }
        for result in results where reviewedTexts[result.operation] == nil { reviews[result.operation] = .error }
        recommendation = results.first { $0.isRecommended && reviews[$0.operation] == .suggestion }?.operation
        selectingRecommendation = true
        let fallback = reviews[operation] == .error
            ? results.first(where: { reviews[$0.operation] == .suggestion })?.operation
                ?? results.first(where: { reviewedTexts[$0.operation] != nil })?.operation ?? operation
            : operation
        operation = manuallySelectedOperation ?? recommendation ?? fallback
        selectingRecommendation = false
        if reviews[operation] == .error {
            rewrittenText = ""
            status = .error("Empty rewrite. Please retry.")
            return
        }
        rewrittenText = reviewedTexts[operation] ?? originalText
        status = normalized(rewrittenText) == normalized(originalText) ? .noChanges : .ready
        if explicitlyRequestedRewrite { rememberResult() }
    }

    private func providerConfig() -> (provider: AIProvider, model: String, key: String)? {
        Self.providerConfiguration()
    }

    static func providerConfiguration() -> (provider: AIProvider, model: String, key: String)? {
        let defaults = UserDefaults.standard
        let provider = AIProvider(rawValue: defaults.string(forKey: "provider") ?? "openai") ?? .openai
        let fallbackModel: String
        let key: String
        switch provider {
        case .openai:
            fallbackModel = AIClient.Defaults.openAIModel
            key = KeychainHelper.read(key: KeychainHelper.openAIKeyAccount) ?? ""
        case .gemini:
            fallbackModel = AIClient.Defaults.geminiModel
            key = KeychainHelper.read(key: KeychainHelper.geminiKeyAccount) ?? ""
        case .claude:
            fallbackModel = AIClient.Defaults.claudeModel
            key = KeychainHelper.read(key: KeychainHelper.claudeKeyAccount) ?? ""
        case .other:
            fallbackModel = AIClient.Defaults.customModel
            key = KeychainHelper.read(key: KeychainHelper.customTokenAccount) ?? ""
            let base = defaults
                .string(forKey: AIClient.openAICompatibleBaseURLUserDefaultsKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !base.isEmpty else { return nil }
        }
        guard !key.isEmpty else { return nil }
        let model = defaults.string(forKey: "model") ?? fallbackModel
        return (provider, model.isEmpty ? fallbackModel : model, key)
    }

    private func shouldSkipProtectedOnly(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if trimmed.range(of: #"^[@#]\S+$"#, options: .regularExpression) != nil { return true }
        if trimmed.range(of: #"^(https?://|www\.|\S+@\S+\.\S+)\S*$"#, options: .regularExpression) != nil {
            return true
        }
        if trimmed.rangeOfCharacter(from: .letters) == nil { return true }
        return false
    }

    private func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
    }

    nonisolated static func fingerprint(for context: TextAccessService.FocusedTextContext) -> String {
        let range = context.usesSelection ? "text-selection" : (context.selectedRange.map { "\($0.location):\($0.length)" } ?? "nil")
        let text = context.text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return [
            context.targetBundleID,
            String(context.targetAppPID),
            range,
            text
        ].joined(separator: "\u{1F}")
    }
}
