import AppKit
import XCTest
import SwiftUI
@testable import Textora

private actor ReviewGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
    var waiting: Bool { continuation != nil }
}

final class InteractionRevisionTests: XCTestCase {
    @MainActor
    func testCustomMeaningReplacesIncompatibleOptions() throws {
        let model = SelectionAssistantViewModel()
        model.setSelectionContext(context("We are helping with Alexey, as are the others in the Onboarding session."), automaticallyCheck: false)
        let question = MeaningQuestion(question: "Who is helping?", options: ["Helping Alexey directly", "A task involving Alexey"])
        model.acceptReview([OverlaySuggestion(operation: model.operation, text: "", meaningQuestions: [question])], generation: model.requestID)
        model.selectMeaningAnswer(question.options[0], for: 0)
        XCTAssertTrue(model.canClarifyMeaning)
        model.rejectMeaningOptions()
        XCTAssertFalse(model.canClarifyMeaning)
        model.selectMeaningAnswer(question.options[1], for: 0)
        let intended = "Я вместе с Алексеем помогаю кому-то, пока другие заняты онбордингом."
        model.customMeaning = intended
        XCTAssertTrue(model.meaningAnswers.isEmpty)
        XCTAssertTrue(model.canClarifyMeaning)
        XCTAssertTrue(model.clarificationForPreview.contains(intended))
        XCTAssertFalse(model.clarificationForPreview.contains(question.options[1]))
        XCTAssertFalse(model.canApply)
        try snapshot(model, name: "meaning-custom", size: CGSize(width: SelectionToolbarView.toolPanelWidth, height: 346))
        model.selectMeaningAnswer(question.options[0], for: 0)
        XCTAssertTrue(model.customMeaning.isEmpty)
        XCTAssertFalse(model.clarificationForPreview.contains(intended))
        XCTAssertTrue(model.clarificationForPreview.contains(question.options[0]))
    }

    func testSpelledDurationsPreserveQuantityWithoutWeakeningProtectedData() throws {
        func review(_ original: String, _ candidate: String) throws -> OverlaySuggestion {
            let payload: [String: Any] = ["fix": candidate, "formal": candidate, "shorten": candidate,
                "humanize": candidate, "recommended": "fix", "questions": []]
            let raw = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
            return try XCTUnwrap(AIClient().decodeCompleteReview(raw, original: original, requireMeaningAssessment: true).first)
        }
        let original = "I think ok, but one more thing, on the next week I will be completely busy and unfortunately - I will not be available. So for now, we can plan in 1 week, I will let you know about the feedback from the other people."
        let corrected = "I think that's okay, but there's one more thing: next week I will be completely busy and, unfortunately, unavailable. For now, we can plan in one week. I will let you know about the feedback from the others."
        XCTAssertNil(try review(original, corrected).validationError)
        XCTAssertNil(try review("Wait 2 weeks", "Wait two weeks").validationError)
        XCTAssertNil(try review("Wait one week", "Wait 1 week").validationError)
        for changed in ["Wait two weeks", "Wait 1 day", "Wait next week", "Wait twenty one weeks", "Wait twenty-one weeks"] {
            XCTAssertNotNil(try review("Wait 1 week", changed).validationError, changed)
        }
        XCTAssertNotNil(try review("Pay 1 USD", "Pay one USD").validationError)
        XCTAssertNotNil(try review("ID 1", "ID one").validationError)
        XCTAssertNotNil(try review("Visit https://example.com in 1 week", "Visit https://other.com in one week").validationError)
        XCTAssertEqual(AIClient.canonicalProtectedDurations("twenty one weeks"), "twenty one weeks")
    }

    func testMeaningReviewRejectsMissingOrMalformedAssessment() throws {
        let client = AIClient()
        let base = #"{"fix":"Original","formal":"Original","shorten":"Original","humanize":"Original","recommended":"none"}"#
        XCTAssertThrowsError(try client.decodeCompleteReview(base, original: "Original", requireMeaningAssessment: true))
        for questions in [#"[{"question":"Who?","options":["Only one"]}]"#, #"[{"question":"Who?","options":["Same","Same"]}]"#, #"[{"question":"","options":["One","Two"]}]"#] {
            let raw = String(base.dropLast()) + ",\"questions\":" + questions + "}"
            XCTAssertThrowsError(try client.decodeCompleteReview(raw, original: "Original", requireMeaningAssessment: true))
        }
        let clear = String(base.dropLast()) + ",\"questions\":[]}"
        XCTAssertTrue(try client.decodeCompleteReview(clear, original: "Original", requireMeaningAssessment: true).allSatisfy { $0.meaningQuestions.isEmpty })
    }

    @MainActor
    func testAmbiguityBlocksAllModesAndNeverBecomesLooksGood() throws {
        let original = "We are helping with Alexey, as are the others in the Onboarding session."
        let raw = #"{"fix":"We are helping Alexey.","formal":"Changed","shorten":"Changed","humanize":"Changed","recommended":"fix","questions":[{"question":"Who is helping?","options":["Together with Alexey","Helping Alexey"]},{"question":"What are the others doing?","options":["Also helping","Attending onboarding instead"]}]}"#
        let results = try AIClient().decodeCompleteReview(raw, original: original, requireMeaningAssessment: true)
        XCTAssertTrue(results.allSatisfy { $0.text == original && !$0.isRecommended })
        let model = SelectionAssistantViewModel()
        model.setSelectionContext(context(original), automaticallyCheck: false)
        let generation = model.requestID
        model.acceptReview(results, generation: generation)
        XCTAssertEqual(model.status, .meaningUnclear)
        XCTAssertFalse(model.canApply)
        try snapshot(model, name: "meaning-toolpanel", size: CGSize(width: SelectionToolbarView.toolPanelWidth, height: 346))
        model.prepareHotKeyPresentation(.rewrite)
        try snapshot(model, name: "meaning-hotkeys", size: CGSize(width: 510, height: SelectionToolbarView.hotKeyPanelHeight(for: model)))
        XCTAssertFalse(model.canClarifyMeaning)
        XCTAssertTrue(model.reviews.values.allSatisfy { $0 == .meaningUnclear })
        model.meaningAnswers[0] = "Together with Alexey"
        XCTAssertFalse(model.canClarifyMeaning)
        model.meaningAnswers[1] = "Attending onboarding instead"
        XCTAssertTrue(model.canClarifyMeaning)
        model.operation = .humanize
        XCTAssertEqual(model.status, .meaningUnclear)
        model.setSelectionContext(context(original), automaticallyCheck: false)
        XCTAssertEqual(model.meaningAnswers.count, 2, "Repeated selection must retain answers")
        model.meaningAnswers = [:]
        model.customMeaning = "Alexey and I help because others are at onboarding."
        XCTAssertTrue(model.canClarifyMeaning)
        model.acceptReview([OverlaySuggestion(operation: .humanize, text: "Alexey and I are helping out because the others are attending onboarding.")], generation: generation)
        XCTAssertEqual(model.status, .ready)
        XCTAssertTrue(model.canApply, "Resolution is a preview, not an automatic insertion")
        XCTAssertTrue(model.meaningQuestions.isEmpty)
        model.setSelectionContext(context("Another selection"), automaticallyCheck: false)
        model.acceptReview(results, generation: generation)
        XCTAssertTrue(model.meaningQuestions.isEmpty, "Stale ambiguity must not reappear")
        XCTAssertTrue(model.customMeaning.isEmpty)
    }

    @MainActor
    func testTranslationAndClosingDiscardMeaningQuestions() {
        let model = SelectionAssistantViewModel()
        model.setSelectionContext(context("Ambiguous text"), automaticallyCheck: false)
        let results = [OverlaySuggestion(operation: model.operation, text: "Ambiguous text", meaningQuestions: [MeaningQuestion(question: "Who?", options: ["One", "Two"])])]
        model.acceptReview(results, generation: model.requestID)
        model.prepareHotKeyPresentation(.translate)
        XCTAssertTrue(model.meaningQuestions.isEmpty)
        XCTAssertFalse(model.canApply)
        model.clear()
        XCTAssertTrue(model.meaningAnswers.isEmpty)
    }

    func testRewriteConfirmationHandlesEditorEmojiSerialization() {
        let original = "Ok, I'm doing team lead responsibilities :slightly_smiling_face:"
        let replacement = "Okay, I'm handling team lead responsibilities. :slightly_smiling_face:"
        let before = "Earlier paragraph\nOk, I'm doing team lead responsibilities 🙂"
        let after = "Earlier paragraph\nOkay, I'm handling team lead responsibilities. 🙂"
        XCTAssertTrue(TextAccessService.directReplacementWasConfirmed(before: before, after: after,
            selection: nil, original: original, replacement: replacement))
        XCTAssertFalse(TextAccessService.directReplacementWasConfirmed(before: before, after: before,
            selection: nil, original: original, replacement: replacement))
        XCTAssertFalse(TextAccessService.directReplacementWasConfirmed(before: before,
            after: after.replacingOccurrences(of: "🙂", with: "😢"), selection: nil, original: original, replacement: replacement))
        XCTAssertFalse(TextAccessService.directReplacementWasConfirmed(before: before,
            after: "Okay, I'm handling team lead responsibilities. 🙂", selection: nil, original: original, replacement: replacement))
        XCTAssertTrue(TextAccessService.copiedReplacementWasConfirmed(replacement: replacement,
            copied: "Okay, I'm handling team lead responsibilities. 🙂", changeCountBefore: 10, changeCountAfter: 11))
        XCTAssertNotEqual(TextAccessService.canonicalApplyText(":custom_emoji:"), TextAccessService.canonicalApplyText("🙂"))
    }

    @MainActor
    func testUnconfirmedApplicationCannotBeAppliedAgain() {
        let model = SelectionAssistantViewModel()
        model.setSelectionContext(context("Original"), automaticallyCheck: false)
        model.acceptReview([OverlaySuggestion(operation: model.operation, text: "Corrected")], generation: model.requestID)
        XCTAssertTrue(model.canApply)
        model.markUnconfirmedApplication()
        XCTAssertFalse(model.canApply)
        XCTAssertTrue(model.applicationNeedsReview)
        model.prepareForSelectionMove()
        model.setSelectionContext(context("New selection"), automaticallyCheck: false)
        XCTAssertFalse(model.applicationNeedsReview)
    }

    @MainActor
    func testNativeMicrophonePopoverMovesThroughEveryAnchor() async throws {
        final class State { var tip: MicrophoneTip? }
        let state = State()
        let binding = Binding<MicrophoneTip?>(get: { state.tip }, set: { state.tip = $0 })
        let presenter = MicrophoneTipPresenter()
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 350, height: 52),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 350, height: 52))
        window.contentView = content
        for tip in MicrophoneTip.allCases {
            let anchor = NSView(frame: NSRect(x: 10 + tip.rawValue * 65, y: 5, width: 40, height: 40))
            content.addSubview(anchor)
            presenter.register(anchor, for: tip)
        }
        window.orderFront(nil)
        for tip in MicrophoneTip.allCases {
            state.tip = tip
            presenter.update(binding)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(presenter.displayedTip, tip)
        }
        state.tip = nil
        presenter.update(binding)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(presenter.displayedTip)
    }

    @MainActor
    func testTranslationModeDoesNotStartOrAcceptRewrite() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: SelectionAssistantSettings.Keys.operation)
        defer {
            if let previous { defaults.set(previous, forKey: SelectionAssistantSettings.Keys.operation) }
            else { defaults.removeObject(forKey: SelectionAssistantSettings.Keys.operation) }
        }
        let model = SelectionAssistantViewModel()
        model.setSelectionContext(context("Translate this sentence"), automaticallyCheck: false)
        let oldGeneration = model.requestID
        model.prepareHotKeyPresentation(.translate)
        let generation = model.requestID
        model.operation = model.operation == .shorten ? .humanize : .shorten
        model.retryReview()
        XCTAssertEqual(model.requestID, generation, "Rewrite must not start in translation mode")
        model.acceptReview([OverlaySuggestion(operation: .shorten, text: "Late rewrite")], generation: oldGeneration)
        XCTAssertTrue(model.isTranslationMode)
        XCTAssertTrue(model.reviews.isEmpty)
        XCTAssertNil(model.recommendation)
        XCTAssertTrue(model.rewrittenText.isEmpty)
        model.setSelectionContext(context("Translate this sentence"), automaticallyCheck: false, preservePresentation: true)
        XCTAssertTrue(model.isTranslationMode)
        model.clear()
        XCTAssertFalse(model.isTranslationMode)
        model.prepareHotKeyPresentation(.rewrite)
        XCTAssertFalse(model.isTranslationMode)
    }

    @MainActor
    func testNewToolPanelSelectionAlwaysReturnsToRewrite() {
        let model = SelectionAssistantViewModel()
        model.prepareHotKeyPresentation(.translate)
        model.setSelectionContext(context("Old selection"), automaticallyCheck: false, preservePresentation: true)
        XCTAssertTrue(model.isTranslationMode)
        let oldGeneration = model.requestID
        // Protected-only input takes the Rewrite path without a network request.
        model.setSelectionContext(context("123"))
        XCTAssertFalse(model.isTranslationMode)
        XCTAssertEqual(model.presentationMode, .standard)
        XCTAssertEqual(model.translationStatus, .idle)
        XCTAssertEqual(model.status, .noChanges)
        XCTAssertTrue(model.translatedText.isEmpty)
        XCTAssertGreaterThan(model.requestID, oldGeneration)
        model.prepareHotKeyPresentation(.translate)
        model.prepareForSelectionMove()
        XCTAssertFalse(model.isTranslationMode)
        model.setSelectionContext(context("456"))
        XCTAssertEqual(model.status, .noChanges)
        XCTAssertEqual(model.translationStatus, .idle)
    }

    @MainActor
    func testExplicitTranslateHotKeyDoesNotStartRewriteOnSelection() {
        let model = SelectionAssistantViewModel()
        model.prepareHotKeyPresentation(.translate)
        model.setSelectionContext(context("123"), preservePresentation: true)
        XCTAssertTrue(model.isTranslationMode)
        XCTAssertEqual(model.status, .waiting)
        XCTAssertEqual(model.translationStatus, .idle, "Only explicit translate() may start a translation")
        XCTAssertTrue(model.reviews.isEmpty)
    }

    func testMicrophoneTipsAreLocalToEachControl() {
        let steps = MicrophoneTip.allCases
        XCTAssertEqual(steps, [.microphone, .translation, .languages, .swap, .drag])
        for (index, tip) in steps.enumerated() {
            XCTAssertFalse(tip.message.contains("Toolbox"))
            XCTAssertFalse(tip.message.contains("Rewrite"))
            XCTAssertFalse(tip.message.contains("Select text"))
            XCTAssertEqual(tip.next, index + 1 < steps.count ? steps[index + 1] : nil)
        }
    }

    @MainActor
    func testFeatureGuideAndTranslationSettingsSnapshots() throws {
        let suite = "TextoraTests.guide.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "dictation.translation.enabled")
        var views: [(String, AnyView)] = (0..<3).map {
            ("intro-\($0)", AnyView(TextoraFeatureGuide(initialStep: $0, onDone: {})))
        }
        views.append(("translation-settings", AnyView(DictationTranslationSettingsView().defaultAppStorage(defaults))))
        for (name, content) in views {
            let view = NSHostingView(rootView: content.padding().frame(width: 310)
                .background(Color(red: 0.13, green: 0.15, blue: 0.16))
                .environment(\.colorScheme, .dark))
            view.appearance = NSAppearance(named: .darkAqua)
            let size = view.fittingSize
            XCTAssertEqual(size.width, 310, accuracy: 1)
            XCTAssertLessThan(size.height, 480)
            view.frame = CGRect(origin: .zero, size: size)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let directory = URL(fileURLWithPath: "/private/tmp/textora-ui")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(name + ".png"))
        }
        XCTAssertLessThan(SelectionToolbarView.toolPanelWidth, 680)
    }

    func testEditableDialogsAndWebPopupsAreNotMenus() {
        for role in ["AXDialog", "AXSheet", "AXWindow", "AXPopover", "AXComboBox", "AXTextField", "AXTextArea", "AXWebArea", "AXGroup", "AXList", "AXTable"] {
            XCTAssertFalse(TextAccessService.isTransientSelectionSurface(role: role, subrole: ""), role)
        }
        XCTAssertFalse(TextAccessService.isTransientSelectionSurface(role: "AXWindow", subrole: "AXFloatingWindow"))
    }

    func testRealMenusRemainExcluded() {
        for role in ["AXMenu", "AXMenuBar", "AXMenuItem", "AXMenuBarItem", "AXMenuButton", "AXPopUpButton", "AXHelpTag"] {
            XCTAssertTrue(TextAccessService.isTransientSelectionSurface(role: role, subrole: ""), role)
        }
        XCTAssertTrue(TextAccessService.isTransientSelectionSurface(role: "AXWindow", subrole: "AXSystemMenu"))
    }

    @MainActor
    func testMicrophoneCompactAndExpandedControlSnapshots() throws {
        let model = DictationMicViewModel()
        model.showsDragHandle = true
        for expanded in [false, true] {
            model.showsTranslationControls = expanded
            let view = NSHostingView(rootView: DictationMicView(model: model, onHoverChanged: { _ in })
                .environment(\.colorScheme, .dark))
            let width: CGFloat = expanded ? 250 : 84
            view.frame = CGRect(x: 0, y: 0, width: width, height: 52)
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.fittingSize.width, width, accuracy: 1)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let directory = URL(fileURLWithPath: "/private/tmp/textora-ui")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(expanded ? "mic-controls.png" : "mic-compact.png"))
        }
    }

    @MainActor
    func testInternalCopyCannotDismissRewriteDuringApply() {
        let now = Date()
        XCTAssertTrue(SelectionAssistantController.shouldIgnoreCopyEvent(isApplying: true, now: now, ignoreUntil: .distantPast))
        XCTAssertTrue(SelectionAssistantController.shouldIgnoreCopyEvent(isApplying: false, now: now, ignoreUntil: now.addingTimeInterval(1)))
        XCTAssertFalse(SelectionAssistantController.shouldIgnoreCopyEvent(isApplying: false, now: now, ignoreUntil: .distantPast))
    }

    func testPasteVerificationRejectsStaleClipboard() {
        let replacement = "We need to have phone calls and SMS."
        XCTAssertFalse(TextAccessService.copiedReplacementWasConfirmed(replacement: replacement, copied: replacement, changeCountBefore: 10, changeCountAfter: 10))
        XCTAssertFalse(TextAccessService.copiedReplacementWasConfirmed(replacement: replacement, copied: "we need to have phone calls + SMS.", changeCountBefore: 10, changeCountAfter: 11))
        XCTAssertTrue(TextAccessService.copiedReplacementWasConfirmed(replacement: replacement, copied: replacement, changeCountBefore: 10, changeCountAfter: 11))
    }

    func testDirectWriteRequiresActualReplacementAtCapturedRange() {
        let original = "we need to have phone calls + SMS."
        let replacement = "We need to have phone calls and SMS."
        let before = "Yeap, " + original
        let range = CFRange(location: 6, length: original.utf16.count)
        XCTAssertFalse(TextAccessService.directReplacementWasConfirmed(before: before, after: before, selection: range, original: original, replacement: replacement))
        XCTAssertFalse(TextAccessService.directReplacementWasConfirmed(before: before, after: nil, selection: range, original: original, replacement: replacement))
        XCTAssertFalse(TextAccessService.directReplacementWasConfirmed(before: before, after: before + replacement, selection: range, original: original, replacement: replacement))
        XCTAssertTrue(TextAccessService.directReplacementWasConfirmed(before: before, after: "Yeap, " + replacement, selection: range, original: original, replacement: replacement))
        XCTAssertTrue(TextAccessService.directReplacementWasConfirmed(before: "hello", after: "Hello", selection: CFRange(location: 0, length: 5), original: "hello", replacement: "Hello"))
    }

    func testReplacementConfirmationHandlesRelativeWebOffsetsAndWhitespace() {
        XCTAssertTrue(TextAccessService.directReplacementWasConfirmed(before: "Yeap, r u how?", after: "Yeap, How are you?\n", selection: CFRange(location: 0, length: 8), original: "r u how?", replacement: "How are you?"))
        XCTAssertTrue(TextAccessService.directReplacementWasConfirmed(before: "r u how?", after: "How are you?", selection: nil, original: "r u how?", replacement: "How are you?"))
        XCTAssertFalse(TextAccessService.directReplacementWasConfirmed(before: "hello hello", after: "Hello hello", selection: nil, original: "hello", replacement: "Hello"))
        XCTAssertFalse(TextAccessService.directReplacementWasConfirmed(before: "Yeap, r u how?", after: "How are you?", selection: nil, original: "r u how?", replacement: "How are you?"))
    }

    @MainActor
    func testDictationTranslationMenuKeepsSizeWhenEnabled() throws {
        let suite = "TextoraTests.translation-menu.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func size(enabled: Bool) -> CGSize {
            defaults.set(enabled, forKey: "dictation.translation.enabled")
            let view = NSHostingView(rootView: DictationTranslationSettingsView()
                .defaultAppStorage(defaults).padding().frame(width: 310))
            view.layoutSubtreeIfNeeded()
            return view.fittingSize
        }
        let disabled = size(enabled: false)
        let enabled = size(enabled: true)
        XCTAssertGreaterThan(disabled.height, 100)
        XCTAssertEqual(disabled.width, enabled.width, accuracy: 0.5)
        XCTAssertEqual(disabled.height, enabled.height, accuracy: 0.5)
    }

    @MainActor
    private func context(_ text: String) -> TextAccessService.FocusedTextContext {
        TextAccessService.FocusedTextContext(text: text, frame: .zero,
            usesSelection: true, selectedRange: CFRange(location: 0, length: text.utf16.count),
            targetElement: AXUIElementCreateSystemWide(), targetAppPID: 999, targetBundleID: "test")
    }

    @MainActor
    func testLateReviewCannotOverwriteNewContextOrClosedPanel() {
        let model = SelectionAssistantViewModel()
        model.setSelectionContext(context("First"), automaticallyCheck: false)
        let old = model.requestID
        model.setSelectionContext(context("Second"), automaticallyCheck: false)
        model.acceptReview([OverlaySuggestion(operation: .fixGrammar, text: "Wrong")], generation: old)
        XCTAssertEqual(model.originalText, "Second")
        XCTAssertTrue(model.rewrittenText.isEmpty)
        let current = model.requestID
        model.clear()
        model.acceptReview([OverlaySuggestion(operation: .fixGrammar, text: "Wrong")], generation: current)
        XCTAssertEqual(model.status, .idle)
        XCTAssertTrue(model.originalText.isEmpty)
    }

    @MainActor
    func testPreviewSnapshotsAndRecommendedSelection() throws {
        let defaults = UserDefaults.standard
        let oldOperation = defaults.object(forKey: SelectionAssistantSettings.Keys.operation)
        defer {
            if let oldOperation { defaults.set(oldOperation, forKey: SelectionAssistantSettings.Keys.operation) }
            else { defaults.removeObject(forKey: SelectionAssistantSettings.Keys.operation) }
        }
        let model = SelectionAssistantViewModel()
        let original = "I would like to kindly ask you to send the report tomorrow."
        model.setSelectionContext(context(original), automaticallyCheck: false)
        model.acceptReview(RewriteOperation.allCases.map {
            OverlaySuggestion(operation: $0, text: $0 == .shorten ? "Please send the report tomorrow." : original, isRecommended: $0 == .shorten)
        }, generation: model.requestID)
        XCTAssertEqual(model.operation, .shorten)
        XCTAssertTrue(model.canApply)
        try snapshot(model, name: "toolpanel-result", size: CGSize(width: SelectionToolbarView.toolPanelWidth, height: 164))
        model.prepareHotKeyPresentation(.rewrite)
        try snapshot(model, name: "hotkeys-result", size: CGSize(width: 510, height: SelectionToolbarView.hotKeyPanelHeight(for: model)))
        model.clear()
        model.setSelectionContext(context(original), automaticallyCheck: false)
        try snapshot(model, name: "toolpanel-loading", size: CGSize(width: SelectionToolbarView.toolPanelWidth, height: 164))
        model.acceptReview(RewriteOperation.allCases.map { OverlaySuggestion(operation: $0, text: original) }, generation: model.requestID)
        XCTAssertFalse(model.canApply)
        XCTAssertEqual(model.status, .noChanges)
        try snapshot(model, name: "toolpanel-clean", size: CGSize(width: SelectionToolbarView.toolPanelWidth, height: 164))
    }

    @MainActor
    private func snapshot(_ model: SelectionAssistantViewModel, name: String, size: CGSize) throws {
        let view = NSHostingView(rootView: SelectionToolbarView(viewModel: model, onApply: {}, onTranslationCopied: {}, onClose: {}).environment(\.colorScheme, .dark))
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: "/private/tmp/textora-ui")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }

    func testIncompleteReviewIsAnErrorNotGreenChecks() {
        XCTAssertThrowsError(try AIClient().decodeCompleteReview("{}", original: "Hello"))
        XCTAssertThrowsError(try AIClient().decodeCompleteReview(#"{"fix":"Hello","formal":"Hello","shorten":"Hello","humanize":"Hello"}"#, original: "Hello"))
    }

    func testCompleteReviewPreservesAllFourCleanStates() throws {
        let result = try AIClient().decodeCompleteReview(#"{"fix":"Hello","formal":"Hello","shorten":"Hello","humanize":"Hello","recommended":"none"}"#, original: "Hello")
        XCTAssertEqual(result.count, 4)
        XCTAssertTrue(result.allSatisfy { $0.text == "Hello" && !$0.isRecommended })
    }

    func testRecommendationAndSameSuggestionForDifferentModesAreRetained() throws {
        let result = try AIClient().decodeCompleteReview(#"{"fix":"Hello","formal":"Hello","shorten":"Hi","humanize":"Hi","recommended":"humanize"}"#, original: "Hello")
        XCTAssertEqual(result.filter { $0.text == "Hi" }.count, 2)
        XCTAssertEqual(result.first(where: \.isRecommended)?.operation, .humanize)
    }

    func testReviewRejectsOnlyVariantWithChangedProtectedURL() throws {
        let result = try AIClient().decodeCompleteReview(#"{"fix":"See https://evil.example","formal":"See https://safe.example","shorten":"See https://safe.example","humanize":"See https://safe.example","recommended":"fix"}"#, original: "See https://safe.example")
        XCTAssertNotNil(result.first?.validationError)
        XCTAssertEqual(result.filter { $0.validationError == nil }.count, 3)
    }

    func testCapitalizedSentenceWordsDoNotBlockRewrites() throws {
        let result = try AIClient().decodeCompleteReview(#"{"fix":"Отправьте отчёт завтра.","formal":"Прошу отправить отчёт завтра.","shorten":"Отправьте отчёт.","humanize":"Пришлите отчёт завтра, пожалуйста.","recommended":"fix"}"#, original: "Нужно отправить отчёт завтра.")
        XCTAssertTrue(result.allSatisfy { $0.validationError == nil })
    }

    func testRejectedReviewIsNotCachedOnRetry() async throws {
        let service = RewriteReviewService()
        _ = try await service.review(key: "retry") {
            [OverlaySuggestion(operation: .fixGrammar, text: "", validationError: "Protected URL")]
        }
        let retried = try await service.review(key: "retry") {
            [OverlaySuggestion(operation: .fixGrammar, text: "Safe correction")]
        }
        XCTAssertEqual(retried.first?.text, "Safe correction")
    }

    @MainActor
    func testInvalidVariantDoesNotBlockSafePreviewOrShowGreenCheck() {
        let model = SelectionAssistantViewModel()
        model.setSelectionContext(context("See https://safe.example"), automaticallyCheck: false)
        model.acceptReview([
            OverlaySuggestion(operation: .fixGrammar, text: "", validationError: "Protected URL"),
            OverlaySuggestion(operation: .shorten, text: "https://safe.example", isRecommended: true)
        ], generation: model.requestID)
        XCTAssertTrue(model.canApply)
        XCTAssertEqual(model.reviews[.fixGrammar], .error)
        model.operation = .fixGrammar
        XCTAssertFalse(model.canApply)
        XCTAssertTrue(model.rewrittenText.isEmpty)
    }

    func testLatestReviewReplacesPendingAndDropsUncancellableResponse() async throws {
        let service = RewriteReviewService()
        let gate = ReviewGate()
        let first = Task { try await service.review(key: "first") {
            await gate.wait()
            return [OverlaySuggestion(operation: .fixGrammar, text: "old")]
        } }
        for _ in 0..<10000 {
            if await gate.waiting { break }
            await Task.yield()
        }
        let second = Task { try await service.review(key: "second") {
            XCTFail("Superseded request must never start")
            return []
        } }
        for _ in 0..<10000 {
            if await service.pendingKey == "second" { break }
            await Task.yield()
        }
        let third = Task { try await service.review(key: "third") {
            [OverlaySuggestion(operation: .shorten, text: "latest")]
        } }
        for _ in 0..<10000 {
            if await service.pendingKey == "third" { break }
            await Task.yield()
        }
        let pending = await service.pendingCount
        XCTAssertEqual(pending, 1)
        await gate.open()
        do { _ = try await first.value; XCTFail("Old response must be discarded") } catch is CancellationError {} catch { XCTFail("\(error)") }
        do { _ = try await second.value; XCTFail("Pending request must be discarded") } catch is CancellationError {} catch { XCTFail("\(error)") }
        let result = try await third.value
        XCTAssertEqual(result.first?.text, "latest")
        let cached = try await service.review(key: "third") { XCTFail("Cached result should be reused"); return [] }
        XCTAssertEqual(cached, result)
    }

    func testLegacyFloatingOnlyMigratesAndHotkeysSurvive() throws {
        let name = "TextoraTests.ModeMigration.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: SelectionAssistantSettings.Keys.floatingIconEnabled)
        defaults.set(false, forKey: SelectionAssistantSettings.Keys.toolboxEnabled)
        SelectionAssistantSettings.registerDefaults(defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: SelectionAssistantSettings.Keys.toolboxEnabled))
        XCTAssertFalse(defaults.bool(forKey: SelectionAssistantSettings.Keys.floatingIconEnabled))
        SelectionAssistantSettings.setInterfaceModes(toolbox: false, hotKeys: true, defaults: defaults)
        SelectionAssistantSettings.registerDefaults(defaults: defaults)
        XCTAssertTrue(SelectionAssistantSettings.hotKeysModeEnabled(defaults: defaults))
    }

    func testDictationTranslationSnapshotDoesNotChangeMidRecording() throws {
        let name = "TextoraTests.Translation.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "dictation.translation.enabled")
        defaults.set("russian", forKey: "dictation.translation.source")
        defaults.set("english", forKey: "dictation.translation.target")
        let snapshot = DictationTranslationSettings.load(defaults)
        defaults.set("french", forKey: "dictation.translation.target")
        XCTAssertTrue(snapshot.enabled)
        XCTAssertEqual(snapshot.target, .english)
        XCTAssertEqual(DictationTranslationSettings.load(defaults).target, .french)
    }

    @MainActor
    func testMovingSelectionDisablesOldContextBeforeNewResolution() {
        let model = SelectionAssistantViewModel()
        let context = TextAccessService.FocusedTextContext(text: "Hello", frame: .zero,
            usesSelection: true, selectedRange: CFRange(location: 0, length: 5),
            targetElement: AXUIElementCreateSystemWide(), targetAppPID: 999, targetBundleID: "test")
        model.setSelectionContext(context, automaticallyCheck: false)
        XCTAssertTrue(model.canTranslate)
        model.prepareForSelectionMove()
        XCTAssertFalse(model.canApply)
        XCTAssertFalse(model.canTranslate)
        XCTAssertEqual(model.status, .waiting)
        model.clear()
        XCTAssertFalse(model.hasRewritePreview)
    }
}
