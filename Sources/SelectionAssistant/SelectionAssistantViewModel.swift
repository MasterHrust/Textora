import AppKit
import Foundation

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
        }
    }
}

@MainActor
final class SelectionAssistantViewModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case waiting
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

    @Published var operation: RewriteOperation {
        didSet {
            guard oldValue != operation else { return }
            SelectionAssistantSettings.setSelectedOperation(operation)
            if let context = currentContext {
                startCheck(for: context)
            }
        }
    }
    @Published var translationLanguage: TranslationLanguage = .english {
        didSet {
            guard oldValue != translationLanguage else { return }
            translatedText = ""
            translationStatus = .idle
            isLanguagePickerExpanded = false
        }
    }
    @Published private(set) var status: Status = .idle
    @Published private(set) var translationStatus: TranslationStatus = .idle
    @Published private(set) var originalText: String = ""
    @Published private(set) var rewrittenText: String = ""
    @Published private(set) var translatedText: String = ""
    @Published var isLanguagePickerExpanded = false

    private let textService = TextAccessService()
    private let aiClient = AIClient()
    private var currentContext: TextAccessService.FocusedTextContext?
    private var currentFingerprint: String?
    private var rewriteTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var requestID = 0
    private var translationRequestID = 0

    init() {
        SelectionAssistantSettings.registerDefaults()
        operation = SelectionAssistantSettings.selectedOperation()
    }

    var canApply: Bool {
        guard case .ready = status else { return false }
        return !rewrittenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && normalized(rewrittenText) != normalized(originalText)
    }

    var canTranslate: Bool {
        currentContext != nil && !originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var showsTranslationPanel: Bool {
        isLanguagePickerExpanded || hasTranslationContent || hasRewritePreview
    }

    var hasTranslationContent: Bool {
        switch translationStatus {
        case .idle:
            return false
        case .translating, .ready, .error:
            return true
        }
    }

    var hasRewritePreview: Bool {
        canApply
    }

    func prepareForSelectionMove() {
        if case .checking = status { return }
        if case .ready = status { return }
        if case .noChanges = status { return }
        status = .waiting
    }

    func clear() {
        rewriteTask?.cancel()
        rewriteTask = nil
        translationTask?.cancel()
        translationTask = nil
        requestID += 1
        translationRequestID += 1
        currentContext = nil
        currentFingerprint = nil
        originalText = ""
        rewrittenText = ""
        translatedText = ""
        status = .idle
        translationStatus = .idle
        isLanguagePickerExpanded = false
    }

    func setSelectionContext(_ context: TextAccessService.FocusedTextContext) {
        let fingerprint = Self.fingerprint(for: context)
        if fingerprint == currentFingerprint, !rewrittenText.isEmpty || status == .checking || status == .noChanges {
            return
        }
        currentContext = context
        currentFingerprint = fingerprint
        originalText = context.text
        rewrittenText = ""
        translatedText = ""
        translationStatus = .idle
        isLanguagePickerExpanded = false
        startCheck(for: context)
    }

    func apply(onFinished: @escaping () -> Void) {
        guard canApply, let context = currentContext else { return }
        status = .applying
        let text = rewrittenText
        let expectedFingerprint = currentFingerprint
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            let applyContext = self.freshApplyContext(expectedFingerprint: expectedFingerprint) ?? context
            let result = self.textService.applyRewrittenText(text, basedOn: applyContext)
            switch result {
            case .success, .clipboardArmed:
                self.clear()
                onFinished()
            case .failed, .unsupportedTarget:
                self.status = .error("Could not apply")
            }
        }
    }

    func translate() {
        guard canTranslate else { return }
        translationTask?.cancel()
        translationRequestID += 1
        let id = translationRequestID

        let config = providerConfig()
        guard let config else {
            translationStatus = .error("Add AI key in Settings")
            return
        }

        let text = originalText
        let language = translationLanguage
        translatedText = ""
        translationStatus = .translating
        translationTask = Task { @MainActor in
            do {
                let out = try await aiClient.translateText(
                    provider: config.provider,
                    model: config.model,
                    apiKey: config.key,
                    text: text,
                    targetLanguage: language.displayName
                )
                guard id == translationRequestID else { return }
                translatedText = out.trimmingCharacters(in: .whitespacesAndNewlines)
                translationStatus = translatedText.isEmpty ? .error("Empty translation") : .ready
            } catch is CancellationError {
                guard id == translationRequestID else { return }
            } catch {
                guard id == translationRequestID else { return }
                translatedText = ""
                translationStatus = .error(error.localizedDescription)
            }
        }
    }

    private func startCheck(for context: TextAccessService.FocusedTextContext) {
        rewriteTask?.cancel()
        requestID += 1
        let id = requestID
        originalText = context.text
        rewrittenText = ""

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
        rewriteTask = Task { @MainActor in
            do {
                let out = try await aiClient.rewriteText(
                    provider: config.provider,
                    model: config.model,
                    apiKey: config.key,
                    text: text,
                    operation: operation
                )
                guard id == requestID else { return }
                let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || normalized(out) == normalized(text) {
                    rewrittenText = text
                    status = .noChanges
                } else {
                    rewrittenText = out
                    status = .ready
                }
            } catch is CancellationError {
                guard id == requestID else { return }
            } catch {
                guard id == requestID else { return }
                rewrittenText = ""
                status = .error(error.localizedDescription)
            }
        }
    }

    private func freshApplyContext(expectedFingerprint: String?) -> TextAccessService.FocusedTextContext? {
        guard let expectedFingerprint else { return nil }
        guard let fresh = textService.selectedTextContextAnyFocus(
            minLength: 1,
            maxLength: 6000,
            allowClipboardFallback: true,
            allowBrowserClipboardSelection: true
        ) else {
            return nil
        }
        return Self.fingerprint(for: fresh) == expectedFingerprint ? fresh : nil
    }

    private func providerConfig() -> (provider: AIProvider, model: String, key: String)? {
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
        if trimmed.hasPrefix("@") || trimmed.hasPrefix("#") { return true }
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

    static func fingerprint(for context: TextAccessService.FocusedTextContext) -> String {
        let range = context.selectedRange.map { "\($0.location):\($0.length)" } ?? "nil"
        return [
            context.targetBundleID,
            String(context.targetAppPID),
            range,
            context.text
        ].joined(separator: "\u{1F}")
    }
}
