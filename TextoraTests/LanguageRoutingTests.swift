import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Textora

final class LanguageRoutingTests: XCTestCase {
    private let policy = LanguagePolicy.automatic(primary: .russian, secondary: .english)

    private func suite() -> UserDefaults {
        let name = "TextoraTests.LanguageRouting.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func enabledDefaults() -> UserDefaults {
        let defaults = suite()
        defaults.set(true, forKey: LanguageRoutingSettings.enabledKey)
        defaults.set("russian", forKey: LanguageRoutingSettings.primaryKey)
        defaults.set("english", forKey: LanguageRoutingSettings.secondaryKey)
        return defaults
    }

    private func envelope(source: String?, target: String?, payload: Any?, status: String = "ready") throws -> String {
        let object: [String: Any] = ["status": status, "sourceLanguage": source as Any? ?? NSNull(),
            "targetLanguage": target as Any? ?? NSNull(), "payload": payload ?? NSNull()]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    func testAllSourceDirectionsAndPayloadKindsUseTheSameRule() throws {
        // Text, Message and Summary share this decoder; a language outside the
        // target picker must also route to the primary language.
        for (source, target) in [("ru", "en"), ("en", "ru"), ("el", "ru"), ("fi", "ru")] {
            let payloads: [Any] = ["Translated text", ["draft": "Draft", "questions": []],
                                   ["overview": "Summary", "sections": []]]
            for payload in payloads {
                let raw = try envelope(source: source, target: target, payload: payload)
                let result = try AIClient.decodeRoutedResponse(raw, policy: policy) { $0 }
                guard case .ready(_, let direction) = result else { return XCTFail("Expected a result") }
                XCTAssertEqual(direction.source, source)
                XCTAssertEqual(direction.target.code, target)
            }
        }
    }

    func testWrongDirectionAndMalformedMetadataAreRejectedBeforePayloadIsUsed() throws {
        for (source, target) in [("ru", "ru"), ("en", "en"), ("el", "en"), ("unknown", "ru"), ("EN", "ru")] {
            var decoded = false
            XCTAssertThrowsError(try AIClient.decodeRoutedResponse(
                envelope(source: source, target: target, payload: "Untrusted"), policy: policy) { value in
                    decoded = true; return value
                })
            XCTAssertFalse(decoded)
        }
        XCTAssertThrowsError(try AIClient.decodeRoutedResponse(
            envelope(source: nil, target: "ru", payload: "Untrusted"), policy: policy) { $0 })
        XCTAssertThrowsError(try AIClient.decodeRoutedResponse("{}", policy: policy) { $0 })
    }

    func testAmbiguityHasNoPayloadAndFixedTargetDoesNotAskAgain() throws {
        let raw = try envelope(source: nil, target: nil, payload: nil, status: "needsTargetSelection")
        let response = try AIClient.decodeRoutedResponse(raw, policy: policy) { _ in XCTFail("Must not decode a result") }
        guard case .needsTargetSelection = response else { return XCTFail("Expected target selection") }
        XCTAssertThrowsError(try AIClient.decodeRoutedResponse(raw, policy: .target(.russian)) { $0 })
        XCTAssertThrowsError(try AIClient.decodeRoutedResponse(
            envelope(source: nil, target: nil, payload: "Must not insert", status: "needsTargetSelection"), policy: policy) { $0 })
        let explicit = try AIClient.decodeRoutedResponse(
            envelope(source: nil, target: "ru", payload: "OK"), policy: .target(.russian)) { $0 as? String }
        guard case .ready(let text, let direction) = explicit else { return XCTFail("Expected fixed-target result") }
        XCTAssertEqual(text, "OK", "An unchanged name, code or expression is valid")
        XCTAssertNil(direction.source)
        XCTAssertEqual(direction.target, .russian)
    }

    func testSettingsAreOptInAndLegacyTargetsSurviveEnabling() {
        let defaults = suite()
        defaults.set("greek", forKey: "translation.targetLanguage")
        defaults.set("french", forKey: "dictation.translation.target")
        XCTAssertFalse(LanguageRoutingSettings.load(defaults).enabled)
        XCTAssertNil(DictationTranslationSettings.load(defaults).routingPolicy)
        XCTAssertFalse(SummaryOptions.load(defaults).smartDirection)
        defaults.set(true, forKey: LanguageRoutingSettings.enabledKey)
        XCTAssertEqual(DictationTranslationSettings.load(defaults).routingPolicy, policy)
        XCTAssertEqual(defaults.string(forKey: "translation.targetLanguage"), "greek")
        XCTAssertEqual(defaults.string(forKey: "dictation.translation.target"), "french")
        defaults.set("russian", forKey: LanguageRoutingSettings.secondaryKey)
        XCTAssertFalse(LanguageRoutingSettings.load(defaults).enabled)
    }

    func testSpeechOptionsFreezePairAndTemporaryOverrideAtStopWithoutEnablingTranslation() {
        let defaults = enabledDefaults()
        XCTAssertFalse(DictationSessionOptions.load(defaults).translation.enabled)
        defaults.set(true, forKey: "dictation.translation.enabled")
        let snapshot = DictationSessionOptions.load(defaults)
        let overridden = DictationSessionOptions.load(defaults, temporaryTarget: .greek)
        defaults.set("french", forKey: LanguageRoutingSettings.primaryKey)
        XCTAssertEqual(snapshot.translation.routingPolicy, policy)
        XCTAssertEqual(overridden.translation.routingPolicy, .target(.greek))
        XCTAssertEqual(DictationSessionOptions.load(defaults).translation.routingPolicy,
                       .automatic(primary: .french, secondary: .english))
        XCTAssertNil(defaults.string(forKey: "dictation.translation.target"))
    }

    @MainActor
    func testRecordingOverrideChosenBeforeStartIsConsumedAtStopOnly() {
        let defaults = enabledDefaults()
        let override = RecordingTranslationOverride()
        override.target = .greek
        var recording = DictationRecordingSession()
        let id = UUID()
        recording.begin(id: id, shortcutMode: .toggle)
        XCTAssertTrue(recording.didStart(id: id))
        let frozen = recording.stop(options: .load(defaults, temporaryTarget: override.consume()))
        XCTAssertEqual(frozen?.translation.routingPolicy, .target(.greek))
        XCTAssertNil(override.target)
        XCTAssertEqual(DictationSessionOptions.load(defaults, temporaryTarget: override.consume()).translation.routingPolicy, policy)
    }

    @MainActor
    private func context(_ text: String) -> TextAccessService.FocusedTextContext {
        .init(text: text, frame: .zero, usesSelection: true,
              selectedRange: CFRange(location: 0, length: text.utf16.count),
              targetElement: AXUIElementCreateSystemWide(), targetAppPID: 999, targetBundleID: "test")
    }

    @MainActor
    private func wait(_ model: SelectionAssistantViewModel, for status: SelectionAssistantViewModel.TranslationStatus) async {
        if model.translationStatus == status { return }
        let finished = expectation(description: "Translation \(status)")
        let token = model.$translationStatus.filter { $0 == status }.prefix(1).sink { _ in finished.fulfill() }
        await fulfillment(of: [finished], timeout: 3)
        token.cancel()
    }

    @MainActor
    func testSelectionAmbiguityBlocksApplicationAndManualChoiceOnlyAffectsCurrentSource() async {
        let defaults = enabledDefaults()
        let legacy = UserDefaults.standard.object(forKey: SelectionAssistantSettings.Keys.translationLanguage)
        var requests: [(String, LanguagePolicy)] = []
        let model = SelectionAssistantViewModel(routedTranslator: { text, policy in
            requests.append((text, policy))
            if case .target(let target) = policy { return .ready("Resolved", .init(source: nil, target: target)) }
            return .needsTargetSelection
        }, routingDefaults: defaults)
        model.prepareHotKeyPresentation(.translate)
        model.setSelectionContext(context("OK"), automaticallyCheck: false, preservePresentation: true)
        model.translate()
        await wait(model, for: .needsTargetSelection)
        XCTAssertFalse(model.canUseTranslation)
        XCTAssertTrue(model.translatedText.isEmpty)
        model.selectTranslationLanguage(.greek)
        await wait(model, for: .ready)
        XCTAssertEqual(requests.last?.0, "OK")
        XCTAssertEqual(requests.last?.1, .target(.greek))
        XCTAssertEqual(model.translationDirection?.target, .greek)
        XCTAssertEqual(UserDefaults.standard.object(forKey: SelectionAssistantSettings.Keys.translationLanguage) as? String, legacy as? String)
        model.clear()
        model.prepareHotKeyPresentation(.translate)
        model.setSelectionContext(context("Next source"), automaticallyCheck: false, preservePresentation: true)
        model.translate()
        await wait(model, for: .needsTargetSelection)
        XCTAssertEqual(requests.last?.1, policy)
        XCTAssertTrue(model.usesAutomaticDirection)
    }

    @MainActor
    func testAutoOpensInlineSetupWithoutChangingPreferencesAndCancelKeepsResult() {
        let defaults = suite()
        defaults.set("greek", forKey: "dictation.translation.target")
        let model = SelectionAssistantViewModel(routingDefaults: defaults)
        model.prepareHotKeyPresentation(.translate)
        model.setSelectionContext(context("Original"), automaticallyCheck: false, preservePresentation: true)
        model.acceptTranslation("Existing translation")
        model.chooseAutomaticTranslation()
        XCTAssertTrue(model.showsTranslationSetup)
        XCTAssertFalse(model.canTranslate)
        XCTAssertFalse(model.canUseTranslation)
        XCTAssertEqual(model.translatedText, "Existing translation")
        XCTAssertNil(defaults.object(forKey: LanguageRoutingSettings.enabledKey))
        model.cancelTranslationSetup()
        XCTAssertFalse(model.showsTranslationSetup)
        XCTAssertEqual(model.translationStatus, .ready)
        XCTAssertEqual(model.translatedText, "Existing translation")
        XCTAssertEqual(defaults.string(forKey: "dictation.translation.target"), "greek")
        model.clear()
    }

    @MainActor
    func testInlineSetupEnablesSharedRuleAndTranslatesCurrentOriginal() async {
        let defaults = suite()
        var requests: [(String, LanguagePolicy)] = []
        let model = SelectionAssistantViewModel(routedTranslator: { text, policy in
            requests.append((text, policy))
            return .ready("Новый перевод", .init(source: "el", target: .russian))
        }, routingDefaults: defaults)
        model.prepareHotKeyPresentation(.translate)
        model.setSelectionContext(context("Καλημέρα"), automaticallyCheck: false, preservePresentation: true)
        model.acceptTranslation("Old result")
        model.chooseAutomaticTranslation()
        model.configureAutomaticTranslation(primary: .russian, secondary: .russian)
        XCTAssertTrue(model.showsTranslationSetup)
        XCTAssertNil(defaults.object(forKey: LanguageRoutingSettings.enabledKey))
        XCTAssertTrue(requests.isEmpty)
        model.configureAutomaticTranslation(primary: .russian, secondary: .english)
        await wait(model, for: .ready)
        XCTAssertFalse(model.showsTranslationSetup)
        XCTAssertTrue(model.usesAutomaticDirection)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.0, "Καλημέρα")
        XCTAssertEqual(requests.first?.1, policy)
        XCTAssertEqual(DictationTranslationSettings.load(defaults).routingPolicy, policy)
        XCTAssertEqual(model.translationLanguageLabel, "EL → RU")
        model.showTranslationSetup()
        model.cancelTranslationSetup()
        XCTAssertEqual(model.translatedText, "Новый перевод")
        model.clear()
    }

    @MainActor
    func testResolvedDirectionIsLockedForRegenerationAndLateAnswerCannotReplaceManualChoice() async {
        let defaults = enabledDefaults()
        var pending: CheckedContinuation<LanguageRoutingResult<String>, Error>?
        let started = expectation(description: "Automatic request started")
        var requests: [LanguagePolicy] = []
        let model = SelectionAssistantViewModel(routedTranslator: { _, policy in
            requests.append(policy)
            if case .automatic = policy {
                return try await withCheckedThrowingContinuation { pending = $0; started.fulfill() }
            }
            return .ready("New result", .init(source: "en", target: policy.fixedTarget!))
        }, routingDefaults: defaults)
        model.setSelectionContext(context("Original"), automaticallyCheck: false)
        model.translate()
        await fulfillment(of: [started], timeout: 3)
        model.selectTranslationLanguage(.french)
        await wait(model, for: .ready)
        pending?.resume(returning: .ready("Stale", .init(source: "en", target: .russian)))
        await Task.yield()
        XCTAssertEqual(model.translatedText, "New result")
        XCTAssertEqual(model.translationDirection?.target, .french)
        model.translate()
        await wait(model, for: .ready)
        XCTAssertEqual(requests.last, .target(.french))
        model.clear()
    }

    @MainActor
    func testChoosingCurrentFixedLanguageDuringAutomaticRequestStillReplacesRequest() async {
        let defaults = enabledDefaults()
        var pending: CheckedContinuation<LanguageRoutingResult<String>, Error>?
        let started = expectation(description: "Automatic request started")
        let model = SelectionAssistantViewModel(routedTranslator: { _, policy in
            if case .automatic = policy {
                return try await withCheckedThrowingContinuation { pending = $0; started.fulfill() }
            }
            return .ready("Explicit result", .init(source: nil, target: policy.fixedTarget!))
        }, routingDefaults: defaults)
        model.setSelectionContext(context("OK"), automaticallyCheck: false)
        let current = model.translationLanguage
        model.translate()
        await fulfillment(of: [started], timeout: 3)
        model.selectTranslationLanguage(current)
        await wait(model, for: .ready)
        XCTAssertEqual(model.translationDirection?.target, current)
        XCTAssertFalse(model.usesAutomaticDirection)
        pending?.resume(returning: .needsTargetSelection)
        await Task.yield()
        XCTAssertEqual(model.translatedText, "Explicit result")
        model.clear()
    }

    @MainActor
    func testAutomaticResultKeepsTargetOnRetryAndCloseDiscardsLateResponse() async {
        let defaults = enabledDefaults()
        var requests: [LanguagePolicy] = []
        var pending: CheckedContinuation<LanguageRoutingResult<String>, Error>?
        let started = expectation(description: "Retry pending")
        let model = SelectionAssistantViewModel(routedTranslator: { _, policy in
            requests.append(policy)
            if requests.count == 1 { return .ready("Перевод", .init(source: "en", target: .russian)) }
            return try await withCheckedThrowingContinuation { pending = $0; started.fulfill() }
        }, routingDefaults: defaults)
        model.setSelectionContext(context("Source"), automaticallyCheck: false)
        model.translate()
        await wait(model, for: .ready)
        XCTAssertEqual(model.translationLanguageLabel, "EN → RU")
        model.translate()
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(requests.last, .target(.russian))
        model.clear()
        pending?.resume(returning: .ready("Late", .init(source: "en", target: .russian)))
        await Task.yield()
        XCTAssertEqual(model.translationStatus, .idle)
        XCTAssertTrue(model.translatedText.isEmpty)
        XCTAssertNil(model.translationDirection)
    }

    @MainActor
    func testSummarySmartChoiceIsIndependentAndOverridesDoNotPersist() async {
        let defaults = enabledDefaults()
        defaults.set(false, forKey: LanguageRoutingSettings.enabledKey)
        var requests: [SummaryOptions] = []
        let model = SummaryViewModel(defaults: defaults, summarize: { _, options in
            requests.append(options)
            return TextSummary(overview: "Summary", sections: [],
                direction: options.routingPolicy.map { .init(source: "en", target: $0.fixedTarget ?? .russian) })
        })
        model.selectSmartDirection()
        func finish() async {
            if !model.busy { return }
            let done = expectation(description: "Summary ready")
            let token = model.$busy.filter { !$0 }.prefix(1).sink { _ in done.fulfill() }
            await fulfillment(of: [done], timeout: 3)
            token.cancel()
        }
        model.start(source: "Original", application: nil)
        await finish()
        XCTAssertEqual(requests.last?.routingPolicy, policy)
        model.selectLanguage(.greek)
        await finish()
        XCTAssertEqual(requests.last?.routingPolicy, .target(.greek))
        XCTAssertEqual(defaults.string(forKey: "summary.language"), "smart")
        model.start(source: "New original", application: nil)
        await finish()
        XCTAssertEqual(requests.last?.routingPolicy, policy)
        model.selectLanguage(nil)
        await finish()
        XCTAssertNil(requests.last?.routingPolicy)
        XCTAssertEqual(defaults.string(forKey: "summary.language"), "original")
    }

    @MainActor
    func testMessageKeepsMeaningQuestionsSeparateFromLanguageSelectionAndTracksEdits() async {
        let model = MessagePreviewModel()
        _ = await model.prepare(transcript: "OK") { MessageDraft(draft: "", questions: [], needsTargetSelection: true) }
        XCTAssertTrue(model.needsTargetSelection)
        XCTAssertTrue(model.questions.isEmpty)
        model.clarification = "Meaning clarification"
        _ = await model.prepare(transcript: "OK") {
            MessageDraft(draft: "", questions: ["What did you mean?"], direction: .init(source: nil, target: .russian))
        }
        XCTAssertFalse(model.needsTargetSelection)
        XCTAssertEqual(model.clarification, "Meaning clarification")
        XCTAssertEqual(model.questions, ["What did you mean?"])
        _ = await model.prepare(transcript: "OK") { MessageDraft(draft: "Draft", questions: []) }
        XCTAssertFalse(model.hasEditedDraft)
        model.draft = "Edited"
        XCTAssertTrue(model.hasEditedDraft)
    }

    @MainActor
    func testSmartPanelsRenderForVisualReview() async throws {
        let defaults = enabledDefaults()
        defaults.set(true, forKey: "dictation.translation.enabled")
        let model = SelectionAssistantViewModel(routedTranslator: { _, _ in .needsTargetSelection }, routingDefaults: defaults)
        model.prepareHotKeyPresentation(.translate)
        model.setSelectionContext(context("OK"), automaticallyCheck: false, preservePresentation: true)
        model.translate()
        await wait(model, for: .needsTargetSelection)
        let message = MessagePreviewModel()
        message.transcript = "OK"; message.needsTargetSelection = true; message.allowsLanguageSelection = true
        message.language = "Auto"; message.draftUsesAI = true
        let summary = SummaryViewModel(defaults: defaults, summarize: { _, _ in TextSummary(overview: "", sections: [], needsTargetSelection: true) })
        summary.selectSmartDirection(); summary.start(source: "OK", application: nil)
        await Task.yield()
        let compact = SelectionAssistantViewModel(routedTranslator: { _, _ in
            .ready("Привет", .init(source: "en", target: .russian))
        }, routingDefaults: defaults)
        compact.setSelectionContext(context("Hello"), automaticallyCheck: false)
        compact.translate(); await wait(compact, for: .ready)
        let expanded = SelectionAssistantViewModel(routingDefaults: defaults)
        expanded.setSelectionContext(context("Hello"), automaticallyCheck: false)
        expanded.isLanguagePickerExpanded = true
        let ambiguousCompact = SelectionAssistantViewModel(routedTranslator: { _, _ in .needsTargetSelection }, routingDefaults: defaults)
        ambiguousCompact.setSelectionContext(context("OK"), automaticallyCheck: false)
        ambiguousCompact.translate(); await wait(ambiguousCompact, for: .needsTargetSelection)
        let dictation = DictationOverlayModel()
        dictation.state = .result("OK"); dictation.canSelectTarget = true
        dictation.needsTargetSelection = true; dictation.canRetry = false
        dictation.resultMessage = "The source language is unclear. Choose a target language."
        let setupHotkey = SelectionAssistantViewModel(routingDefaults: suite())
        setupHotkey.prepareHotKeyPresentation(.translate)
        setupHotkey.setSelectionContext(context("Hello"), automaticallyCheck: false, preservePresentation: true)
        setupHotkey.chooseAutomaticTranslation()
        let setupToolbox = SelectionAssistantViewModel(routingDefaults: suite())
        setupToolbox.setSelectionContext(context("Hello"), automaticallyCheck: false)
        setupToolbox.chooseAutomaticTranslation()
        let readyHotkey = SelectionAssistantViewModel(routedTranslator: { _, _ in
            .ready("Hello", .init(source: "ru", target: .english))
        }, routingDefaults: defaults)
        readyHotkey.prepareHotKeyPresentation(.translate)
        readyHotkey.setSelectionContext(context("Привет"), automaticallyCheck: false, preservePresentation: true)
        readyHotkey.translate(); await wait(readyHotkey, for: .ready)
        let panels: [(String, AnyView, CGSize)] = [
            ("auto-option", AnyView(VStack(spacing: 8) {
                AutoTranslationOption(isSelected: false) { }
                AutoTranslationOption(isSelected: true) { }
            }.padding(8)), CGSize(width: 212, height: 136)),
            ("auto-setup-hotkeys", AnyView(SelectionToolbarView(viewModel: setupHotkey, onApply: {}, onClose: {})), CGSize(width: 510, height: SelectionToolbarView.hotKeyPanelHeight(for: setupHotkey))),
            ("auto-setup-toolbox", AnyView(SelectionToolbarView(viewModel: setupToolbox, onApply: {}, onClose: {})), CGSize(width: SelectionToolbarView.toolPanelWidth(for: setupToolbox), height: SelectionToolbarView.standardPanelHeight(for: setupToolbox))),
            ("translation-direction", AnyView(SelectionToolbarView(viewModel: readyHotkey, onApply: {}, onClose: {})), CGSize(width: 510, height: SelectionToolbarView.hotKeyPanelHeight(for: readyHotkey))),
            ("toolbox", AnyView(SelectionToolbarView(viewModel: compact, onApply: {}, onClose: {})), CGSize(width: SelectionToolbarView.toolPanelWidth(for: compact), height: 192)),
            ("toolbox-languages", AnyView(SelectionToolbarView(viewModel: expanded, onApply: {}, onClose: {})), CGSize(width: SelectionToolbarView.toolPanelWidth(for: expanded), height: 198)),
            ("toolbox-ambiguous", AnyView(SelectionToolbarView(viewModel: ambiguousCompact, onApply: {}, onClose: {})), CGSize(width: SelectionToolbarView.toolPanelWidth(for: ambiguousCompact), height: 192)),
            ("dictation", AnyView(DictationOverlayView(model: dictation)), CGSize(width: 560, height: 360)),
            ("settings", AnyView(SmartTranslationSettingsView()), CGSize(width: 420, height: 260)),
            ("recording", AnyView(RecordingCapsuleView(meter: RecordingMeterModel(), options: RecordingControlsModel(isExpanded: true), onStop: {}, isCopyOnly: true)), RecordingCapsuleLayout.size(expanded: true)),
            ("translation", AnyView(SelectionToolbarView(viewModel: model, onApply: {}, onClose: {})), CGSize(width: 510, height: SelectionToolbarView.hotKeyPanelHeight(for: model))),
            ("message", AnyView(MessagePreviewView(model: message, providerAvailable: true)), CGSize(width: 650, height: 540)),
            ("summary", AnyView(SummaryView(model: summary)), CGSize(width: 640, height: 590))
        ]
        let directory = URL(fileURLWithPath: "/private/tmp/textora-smart-ui")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, panel, size) in panels {
            let view = NSHostingView(rootView: panel.defaultAppStorage(defaults).environment(\.colorScheme, .dark)
                .background(Color(nsColor: .windowBackgroundColor)))
            view.appearance = NSAppearance(named: .darkAqua)
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = view
            view.frame = CGRect(origin: .zero, size: size)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
            window.close()
        }
        model.clear(); compact.clear(); expanded.clear(); ambiguousCompact.clear(); summary.cancel()
        setupHotkey.clear(); setupToolbox.clear(); readyHotkey.clear()
    }
}
