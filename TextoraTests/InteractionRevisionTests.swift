import AppKit
import XCTest
import Combine
import SwiftUI
@testable import Textora

private actor ReviewGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
    var waiting: Bool { continuation != nil }
}

final class InteractionRevisionTests: XCTestCase {
    // Legacy translation scenarios must ignore the running app's Auto preference.
    private func legacyRoutingDefaults() -> UserDefaults {
        let name = "TextoraTests.LegacyRouting.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    @MainActor
    func testFloatingHelpersOnlyAcceptKeyboardFocusWhenRecordingControlsOptIn() {
        let panel = DraggableFloatingPanel(contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        XCTAssertFalse(panel.canBecomeKey, "Idle helpers must not take typing from the editor")
        panel.allowsKeyboardInteraction = true
        XCTAssertTrue(panel.canBecomeKey, "Recording language controls need keyboard interaction")
        panel.allowsKeyboardInteraction = false
        XCTAssertFalse(panel.canBecomeKey)
    }

    @MainActor
    func testRecordingMetersDoNotInvalidateTheControlsOrCollapseLanguageOptions() {
        let overlay = DictationOverlayModel()
        let microphone = DictationMicViewModel()
        overlay.recordingControls.isExpanded = true
        microphone.recordingControls.isExpanded = true
        let overlayOptions = ObjectIdentifier(overlay.recordingControls)
        let microphoneOptions = ObjectIdentifier(microphone.recordingControls)
        var overlayUpdates = 0
        var microphoneUpdates = 0
        let first = overlay.objectWillChange.sink { overlayUpdates += 1 }
        let second = microphone.objectWillChange.sink { microphoneUpdates += 1 }
        for tick in 0..<120 {
            overlay.level = Float(tick % 10) / 10
            overlay.elapsed = Double(tick) / 10
            microphone.level = overlay.level
            microphone.elapsed = overlay.elapsed
        }
        XCTAssertEqual(overlayUpdates, 0, "Audio ticks must only redraw the meter and clock")
        XCTAssertEqual(microphoneUpdates, 0)
        XCTAssertEqual(ObjectIdentifier(overlay.recordingControls), overlayOptions)
        XCTAssertEqual(ObjectIdentifier(microphone.recordingControls), microphoneOptions)
        XCTAssertTrue(overlay.recordingControls.isExpanded)
        XCTAssertTrue(microphone.recordingControls.isExpanded)
        first.cancel(); second.cancel()
    }

    @MainActor
    func testDictationRecordingAndCopyOnlyViewsRenderInBothThemes() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/textora-dictation-140-53")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            let suiteName = "TextoraTests.RecordingUI.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let meter = RecordingMeterModel()
            meter.level = 0.55; meter.elapsed = 42
            func render<V: View>(_ view: V, name: String, size: CGSize) throws {
                let host = NSHostingView(rootView: view.defaultAppStorage(defaults)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .background(Color(nsColor: .windowBackgroundColor)))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                    styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                host.frame = CGRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            }
            defaults.set("text", forKey: "dictation.outputMode")
            try render(RecordingCapsuleView(meter: meter, options: RecordingControlsModel(), onStop: {}),
                name: "recording-text", size: RecordingCapsuleLayout.size(expanded: false))
            try render(RecordingCapsuleView(meter: RecordingMeterModel(), options: RecordingControlsModel(), onStop: {}, isPreparing: true),
                name: "recording-preparing", size: RecordingCapsuleLayout.size(expanded: false))
            defaults.set("message", forKey: "dictation.outputMode")
            defaults.set(true, forKey: "dictation.translation.enabled")
            defaults.set("russian", forKey: "dictation.translation.source")
            defaults.set("english", forKey: "dictation.translation.target")
            try render(RecordingCapsuleView(meter: meter, options: RecordingControlsModel(isExpanded: true), onStop: {}),
                name: "recording-message-translation", size: RecordingCapsuleLayout.size(expanded: true))
            defaults.set("auto", forKey: "dictation.translation.source")
            try render(RecordingCapsuleView(meter: meter, options: RecordingControlsModel(isExpanded: true), onStop: {}),
                name: "recording-auto-language", size: RecordingCapsuleLayout.size(expanded: true))
            try render(RecordingCapsuleView(meter: meter, options: RecordingControlsModel(), onStop: {}, isCopyOnly: true),
                name: "recording-copy-only", size: RecordingCapsuleLayout.size(expanded: false))
            let microphone = DictationMicViewModel()
            microphone.state = .recording(language: .russian)
            microphone.showsDragHandle = true
            microphone.recordingControls.isExpanded = true
            try render(DictationMicView(model: microphone, onHoverChanged: { _ in }),
                name: "recording-toolbox-options", size: RecordingCapsuleLayout.size(expanded: true))
            let overlay = DictationOverlayModel()
            overlay.state = .result("Hi Rob, I’m running late. I’ll finish tomorrow morning.")
            overlay.isCopyOnly = true; overlay.canRetry = false
            overlay.resultMessage = "Ready to copy. Paste with ⌘V wherever you choose."
            try render(DictationOverlayView(model: overlay), name: "dictation-copy-result", size: CGSize(width: 560, height: 360))
            overlay.state = .transcribing
            try render(DictationOverlayView(model: overlay), name: "dictation-processing", size: CGSize(width: 430, height: 88))
            let message = MessagePreviewModel()
            message.canInsert = false
            message.transcript = "Tell Rob I am running late and will finish tomorrow morning."
            message.draft = "Hi Rob, I’m running late. I’ll finish tomorrow morning."
            try render(MessagePreviewView(model: message, providerAvailable: false), name: "message-copy-only", size: CGSize(width: 650, height: 540))
            let local = MessagePreviewModel()
            local.transcript = "Один, два, три."
            local.draft = local.transcript; local.style = "Work"
            local.canInsert = false
            try render(MessagePreviewView(model: local, providerAvailable: false),
                name: "message-local-no-provider", size: CGSize(width: 650, height: 540))
            try render(MessagePreviewView(model: local, providerAvailable: true),
                name: "message-local-ai-optional", size: CGSize(width: 650, height: 540))
            local.draftUsesAI = true; local.aiWasRequested = true
            try render(MessagePreviewView(model: local, providerAvailable: true),
                name: "message-ai-draft", size: CGSize(width: 650, height: 540))
            local.draftUsesAI = false; local.busy = true
            try render(MessagePreviewView(model: local, providerAvailable: true),
                name: "message-ai-request", size: CGSize(width: 650, height: 540))
            local.busy = false; local.notice = "AI improvement is unavailable. Your local draft is still available."
            try render(MessagePreviewView(model: local, providerAvailable: true),
                name: "message-ai-error-local-retained", size: CGSize(width: 650, height: 540))
            defaults.set("message", forKey: "dictation.outputMode")
            defaults.set(false, forKey: "dictation.translation.enabled")
            try render(RecordingCapsuleView(meter: meter, options: RecordingControlsModel(isExpanded: true), onStop: {}),
                name: "recording-message-local", size: RecordingCapsuleLayout.size(expanded: true))
            let navigation = SettingsNavigation(defaults: defaults)
            navigation.open(.shortcuts)
            let settings = AppViewModel(isPreview: true)
            settings.offlineDictationEnabled = true
            try render(ContentView(viewModel: settings, navigation: navigation,
                styleStore: PersonalStyleStore(defaults: defaults)),
                name: "dictation-shortcut-settings", size: CGSize(width: 900, height: 650))
        }
    }

    func testBackgroundPollingWaitsUntilTypingStopsAndResumesForSelection() {
        let gate = BackgroundTextPollingGate()
        XCTAssertTrue(gate.allowsPolling(now: 10))
        var backgroundReads = 0
        for key in 0..<30 {
            let time = 10 + Double(key) * 0.1
            gate.pauseForTyping(now: time)
            if gate.allowsPolling(now: time + 0.09) { backgroundReads += 1 }
        }
        XCTAssertEqual(backgroundReads, 0, "Neither selection nor microphone polling should query the host during continuous typing")
        XCTAssertFalse(gate.allowsPolling(now: 13.69))
        XCTAssertTrue(gate.allowsPolling(now: 13.71))
        gate.pauseForTyping(now: 14)
        gate.resumeForSelection()
        XCTAssertTrue(gate.allowsPolling(now: 14.01), "A selection gesture must not wait for the typing delay")
        for code: UInt16 in [0, 1, 7, 8, 9, 36, 51, 117, 123] {
            XCTAssertTrue(BackgroundTextPollingGate.isTypingKey(keyCode: code, command: false, shift: false))
        }
        XCTAssertFalse(BackgroundTextPollingGate.isTypingKey(keyCode: 0, command: true, shift: false))
        for code: UInt16 in [115, 119, 123, 124, 125, 126] {
            XCTAssertFalse(BackgroundTextPollingGate.isTypingKey(keyCode: code, command: false, shift: true))
        }
    }

    @MainActor
    func testStyleSettingsSuspendReturnAndRewriteHotkeysWithoutLosingOriginalResult() {
        let defaults = UserDefaults(suiteName: "TextoraStyleSuspension.\(UUID().uuidString)")!
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let model = SelectionAssistantViewModel(pasteboard: board, styleStore: PersonalStyleStore(defaults: defaults), routingDefaults: legacyRoutingDefaults())
        model.setSelectionContext(context("Original message"), automaticallyCheck: false)
        model.acceptReview([OverlaySuggestion(operation: model.operation, text: "Corrected message")], generation: model.requestID)
        XCTAssertTrue(model.canApply)
        let request = model.requestID
        let original = model.originalText
        let result = model.rewrittenText
        let source = model.sourceBundleID
        let controller = SelectionAssistantController(viewModel: model)

        controller.suspendForStyleEditing()
        controller.suspendForStyleEditing()
        XCTAssertTrue(controller.isPausedForStyleEditing)
        // A Return event from the Settings editor must not dispatch insertion.
        controller.applyCurrentRewrite()
        XCTAssertEqual(model.status, .ready)
        XCTAssertFalse(model.isApplying)
        // A global Rewrite shortcut must not resolve a field inside Textora.
        controller.performHotKeyAction(.rewrite)
        XCTAssertEqual(model.requestID, request)
        XCTAssertEqual(model.originalText, original)
        XCTAssertEqual(model.rewrittenText, result)
        XCTAssertEqual(model.sourceBundleID, source)

        controller.resumeAfterStyleEditing()
        XCTAssertFalse(controller.isPausedForStyleEditing)
        XCTAssertEqual(model.status, .ready)
        XCTAssertEqual(model.originalText, original)
        XCTAssertEqual(model.rewrittenText, result)
        controller.stop()
    }

    @MainActor
    func testRecreatedInsertionFieldNeedsMatchingIdentityWindowGeometryAndSelection() async {
        let window = AXUIElementCreateApplication(88)
        func field(element: AXUIElement, identifier: String = "composer", role: String = "AXTextArea",
                   windowID: AXUIElement = window, frame: CGRect = CGRect(x: 10, y: 20, width: 200, height: 80),
                   text: String = "Original", range: CFRange = CFRange(location: 0, length: 8),
                   hasIdentity: Bool = true) -> TextAccessService.FocusedTextContext {
            .init(text: text, frame: frame, usesSelection: true, selectedRange: range, targetElement: element,
                  targetAppPID: 999, targetBundleID: "test", insertionIdentity: hasIdentity
                    ? .init(identifier: identifier, role: role, window: windowID) : nil)
        }
        let before = field(element: AXUIElementCreateApplication(999))
        let newElement = AXUIElementCreateApplication(1000)
        let after = field(element: newElement)
        var writes = 0
        let worker = SelectionTextWorker(selectionReader: { _ in after }, applicationWriter: { _, _ in writes += 1; return .dispatched },
                                         frontmostPID: { 999 })
        let result = await worker.apply("Rewritten", captured: before)
        XCTAssertEqual(result, .dispatched)
        XCTAssertEqual(writes, 1)
        for changed in [field(element: newElement, identifier: "other"), field(element: newElement, role: "AXTextField"),
                        field(element: newElement, windowID: AXUIElementCreateApplication(89)),
                        field(element: newElement, frame: CGRect(x: 10, y: 120, width: 200, height: 80)),
                        field(element: newElement, hasIdentity: false)] {
            XCTAssertEqual(SelectionTextWorker.applicationContextFailure(captured: before, fresh: changed), .targetChanged)
        }
        XCTAssertEqual(SelectionTextWorker.applicationContextFailure(captured: before, fresh: field(element: newElement, text: "Changed")), .selectionChanged)
        XCTAssertEqual(SelectionTextWorker.applicationContextFailure(captured: before, fresh: field(element: newElement, range: CFRange(location: 12, length: 8))), .selectionChanged)
    }

    func testGeneratedProseUsesShortDashesAndPreservesURLsAndCode() throws {
        let input = "Hello — world. 14:10–14:20.\nhttps://example.com/a—b `a–b`\n```\na—b\n```\nПривет — мир."
        let expected = "Hello - world. 14:10-14:20.\nhttps://example.com/a—b `a–b`\n```\na—b\n```\nПривет - мир."
        XCTAssertEqual(GeneratedTextStyle.shortDashes(input), expected)
        XCTAssertEqual(GeneratedTextStyle.shortDashes(expected), expected)
        XCTAssertEqual(GeneratedTextStyle.shortDashes(""), "")
        let values: [String: Any] = ["fix": "Hello — world", "formal": "Hello – world", "shorten": "Hello — world",
                                   "humanize": "Hello — world", "recommended": "fix", "questions": []]
        let raw = String(data: try JSONSerialization.data(withJSONObject: values), encoding: .utf8)!
        XCTAssertTrue(try AIClient().decodeCompleteReview(raw, original: "Hello world", requireMeaningAssessment: true)
            .allSatisfy { $0.text == "Hello - world" })
    }

    private var savedTranslationLanguage: Any?

    override func setUp() {
        super.setUp()
        savedTranslationLanguage = UserDefaults.standard.object(forKey: SelectionAssistantSettings.Keys.translationLanguage)
    }

    override func tearDown() {
        let key = SelectionAssistantSettings.Keys.translationLanguage
        if let savedTranslationLanguage { UserDefaults.standard.set(savedTranslationLanguage, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
        super.tearDown()
    }

    @MainActor
    func testMeaningPreviewIdentifiesUnansweredQuestionsAfterChoosingHungerGamesInterpretation() throws {
        let model = SelectionAssistantViewModel(routingDefaults: legacyRoutingDefaults())
        model.setSelectionContext(context("Hi Rob, Sorry, I was on the Hunger Games it tooks more time"), automaticallyCheck: false)
        let questions = [
            MeaningQuestion(question: "What were you doing with The Hunger Games?",
                            options: ["Watching it", "Working on or participating in it"]),
            MeaningQuestion(question: "What took more time?",
                            options: ["The Hunger Games activity", "Another task"])
        ]
        model.acceptReview([OverlaySuggestion(operation: model.operation, text: "", meaningQuestions: questions)], generation: model.requestID)
        XCTAssertEqual(model.unansweredMeaningQuestionIndices, [0, 1])
        model.selectMeaningAnswer(questions[0].options[1], for: 0)
        XCTAssertEqual(model.unansweredMeaningQuestionIndices, [1])
        XCTAssertFalse(model.canClarifyMeaning, "The second question must be visible and identified, not silently assumed")
        try snapshot(model, name: "meaning-one-answer-toolpanel",
                     size: CGSize(width: SelectionToolbarView.toolPanelWidth, height: 346))
        model.prepareHotKeyPresentation(.rewrite)
        try snapshot(model, name: "meaning-one-answer-hotkeys",
                     size: CGSize(width: 510, height: SelectionToolbarView.hotKeyPanelHeight(for: model)))

        model.selectMeaningAnswer("Invalid answer", for: 1)
        model.selectMeaningAnswer("Invalid question", for: 2)
        XCTAssertEqual(model.unansweredMeaningQuestionIndices, [1])
        model.customMeaning = " \n "
        XCTAssertFalse(model.canClarifyMeaning)
        model.selectMeaningAnswer(questions[1].options[0], for: 1)
        XCTAssertTrue(model.unansweredMeaningQuestionIndices.isEmpty)
        XCTAssertTrue(model.canClarifyMeaning)
        XCTAssertTrue(model.clarificationForPreview.contains(questions[0].options[1]))
        XCTAssertTrue(model.clarificationForPreview.contains(questions[1].options[0]))
        XCTAssertFalse(model.canApply, "Answers prepare a preview; they must never insert a guessed rewrite")

        model.rejectMeaningOptions()
        model.selectMeaningAnswer(questions[1].options[1], for: 1)
        XCTAssertEqual(model.unansweredMeaningQuestionIndices, [0], "Questions can be answered in either order")
        XCTAssertFalse(model.canClarifyMeaning)
        model.customMeaning = "Я работал над проектом Hunger Games, работа заняла больше времени."
        XCTAssertTrue(model.canClarifyMeaning, "A written explanation replaces all multiple-choice answers")
        XCTAssertTrue(model.meaningAnswers.isEmpty)
        model.customMeaning = ""
        XCTAssertFalse(model.canClarifyMeaning)
        XCTAssertEqual(model.unansweredMeaningQuestionIndices, [0, 1])
    }

    @MainActor
    func testApplyPreflightKeepsAXRepresentationAndRejectsActualSelectionChanges() async {
        let original = context("Hi 🙂")
        func fresh(text: String = "Hi 🙂", range: CFRange? = CFRange(location: 0, length: 5),
                   element: AXUIElement? = nil, pid: pid_t = 999, bundle: String = "test") -> TextAccessService.FocusedTextContext {
            .init(text: text, frame: .zero, usesSelection: true, selectedRange: range,
                  targetElement: element ?? original.targetElement, targetAppPID: pid, targetBundleID: bundle)
        }
        let cases: [(TextAccessService.FocusedTextContext, TextAccessService.ApplyResult)] = [
            (fresh(), .dispatched),
            (fresh(range: nil), .dispatched),
            (fresh(text: "Hi :slightly_smiling_face:", range: nil), .dispatched),
            (fresh(text: "Hi 🙁"), .rejected(.selectionChanged)),
            (fresh(range: CFRange(location: 10, length: 5)), .rejected(.selectionChanged)),
            (fresh(element: AXUIElementCreateApplication(999)), .rejected(.targetChanged)),
            (fresh(pid: 123), .rejected(.targetChanged)),
            (fresh(bundle: "other"), .rejected(.targetChanged))
        ]
        for (current, expected) in cases {
            var reads = [Bool]()
            var writes = 0
            let worker = SelectionTextWorker(selectionReader: { allowClipboard in
                reads.append(allowClipboard)
                return current
            }, applicationWriter: { text, selected in
                writes += 1
                XCTAssertEqual(text, "Hello 🙂")
                XCTAssertEqual(selected.text, current.text)
                return .dispatched
            }, frontmostPID: { 999 })
            let result = await worker.apply("Hello 🙂", captured: original)
            XCTAssertEqual(result, expected)
            XCTAssertEqual(reads, [false], "A readable AX selection must not be replaced by clipboard metadata, even after a mismatch")
            XCTAssertEqual(writes, expected == .dispatched ? 1 : 0)
        }
        let capturedWithoutRange = fresh(range: nil)
        XCTAssertNil(SelectionTextWorker.applicationContextFailure(captured: capturedWithoutRange, fresh: original))
    }

    @MainActor
    func testApplyPreflightUsesExplicitFallbackOnlyForUnavailableAXSelection() async {
        let original = context("Original")
        let clipboardContext = TextAccessService.FocusedTextContext(text: original.text, frame: .zero,
            usesSelection: true, selectedRange: nil, targetElement: original.targetElement,
            targetAppPID: original.targetAppPID, targetBundleID: original.targetBundleID)
        var reads = [Bool]()
        var writes = 0
        let worker = SelectionTextWorker(selectionReader: { allowClipboard in
            reads.append(allowClipboard)
            return allowClipboard ? clipboardContext : nil
        }, applicationWriter: { _, fresh in
            writes += 1
            XCTAssertNil(fresh.selectedRange)
            return .success
        }, frontmostPID: { 999 })
        let result = await worker.apply("Rewritten", captured: original)
        XCTAssertEqual(result, .success)
        XCTAssertEqual(reads, [false, true])
        XCTAssertEqual(writes, 1)

        let otherAppWorker = SelectionTextWorker(selectionReader: { _ in
            XCTFail("Do not send copy to a different foreground app")
            return original
        }, frontmostPID: { 123 })
        let otherResult = await otherAppWorker.apply("Rewritten", captured: original)
        XCTAssertEqual(otherResult, .rejected(.targetChanged))
        let unavailableWorker = SelectionTextWorker(selectionReader: { _ in nil }, frontmostPID: { 999 })
        let unavailableResult = await unavailableWorker.apply("Rewritten", captured: original)
        XCTAssertEqual(unavailableResult, .rejected(.selectionUnavailable))
    }

    func testCopyConfirmationWaitsForDelayedClipboardWithoutAcceptingStaleOrDifferentText() {
        for readyAt in [1, 3, 10, 14] {
            var polls = 0
            let result = TextAccessService.waitForCopiedSelection(expected: "Selected", baselineChangeCount: 10,
                read: { polls >= readyAt ? (11, "Selected") : (10, "Selected") },
                shouldContinue: { true }, pause: { polls += 1 })
            XCTAssertEqual(result, 11)
            XCTAssertEqual(polls, readyAt)
        }
        var polls = 0
        XCTAssertNil(TextAccessService.waitForCopiedSelection(expected: "Selected", baselineChangeCount: 10,
            read: { (10, "Selected") }, shouldContinue: { true }, pause: { polls += 1 }))
        XCTAssertEqual(polls, 14, "Matching old clipboard contents are not proof of a copy")
        polls = 0
        XCTAssertNil(TextAccessService.waitForCopiedSelection(expected: "Selected", baselineChangeCount: 10,
            read: { (11, "Different selection") }, shouldContinue: { true }, pause: { polls += 1 }))
        XCTAssertEqual(polls, 1, "Do not wait past evidence that the selection changed")
        polls = 0
        XCTAssertNil(TextAccessService.waitForCopiedSelection(expected: "Selected", baselineChangeCount: 10,
            read: { XCTFail("Must stop after cancellation/focus change"); return (11, "Selected") },
            shouldContinue: { polls == 0 }, pause: { polls += 1 }))
        XCTAssertEqual(polls, 1)
        polls = 0
        XCTAssertEqual(TextAccessService.waitForCopiedSelection(expected: "Selected", baselineChangeCount: 10,
            read: { (11, polls < 3 ? nil : "Selected") }, shouldContinue: { true }, pause: { polls += 1 }), 11)
    }

    @MainActor
    func testInsertionRefusalExplainsReasonAndKeepsRewriteAndTranslationCopyable() throws {
        let pasteboard = NSPasteboard(name: .init("Textora.apply-reasons.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        for translating in [false, true] {
            for reason in TextAccessService.ApplyFailureReason.allCases {
                let model = SelectionAssistantViewModel(pasteboard: pasteboard, routingDefaults: legacyRoutingDefaults())
                model.setSelectionContext(context("Original"), automaticallyCheck: false)
                if translating {
                    model.prepareHotKeyPresentation(.translate)
                    model.acceptTranslation("Перевод")
                } else {
                    model.acceptReview([OverlaySuggestion(operation: model.operation, text: "Rewritten")], generation: model.requestID)
                }
                var closed = false
                model.completeApplication(.rejected(reason), onFinished: { closed = true })
                XCTAssertFalse(closed)
                XCTAssertTrue(model.resultNotice.contains(reason.message))
                XCTAssertTrue(model.resultNotice.contains("Copied to clipboard - press ⌘V"))
                XCTAssertEqual(pasteboard.string(forType: .string), translating ? "Перевод" : "Rewritten")
                if translating { XCTAssertTrue(model.canUseTranslation) }
            }
        }
    }

    @MainActor
    func testCustomMeaningReplacesIncompatibleOptions() throws {
        let model = SelectionAssistantViewModel(routingDefaults: legacyRoutingDefaults())
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
        let model = SelectionAssistantViewModel(routingDefaults: legacyRoutingDefaults())
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
        let model = SelectionAssistantViewModel(routingDefaults: legacyRoutingDefaults())
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
    func testRecommendationDoesNotReplaceUsersSavedRewriteMode() {
        let key = SelectionAssistantSettings.Keys.operation
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        SelectionAssistantSettings.setSelectedOperation(.makeProfessional)
        let model = SelectionAssistantViewModel(routingDefaults: legacyRoutingDefaults())
        model.setSelectionContext(context("Original"), automaticallyCheck: false)
        model.acceptReview([OverlaySuggestion(operation: .humanize, text: "Corrected", isRecommended: true)], generation: model.requestID)
        XCTAssertEqual(model.operation, .humanize)
        XCTAssertEqual(SelectionAssistantSettings.selectedOperation(), .makeProfessional)
        XCTAssertEqual(SelectionAssistantViewModel(routingDefaults: legacyRoutingDefaults()).operation, .makeProfessional)
        model.operation = .shorten
        XCTAssertEqual(SelectionAssistantSettings.selectedOperation(), .shorten)
    }

    @MainActor
    func testRejectedApplicationRequiresFreshSelectionBeforeRetry() {
        let model = SelectionAssistantViewModel(routingDefaults: legacyRoutingDefaults())
        model.setSelectionContext(context("Original"), automaticallyCheck: false)
        model.acceptReview([OverlaySuggestion(operation: model.operation, text: "Corrected")], generation: model.requestID)
        XCTAssertTrue(model.canApply)
        model.completeApplication(.failed, onFinished: { XCTFail("A rejected write must keep the result") })
        XCTAssertFalse(model.canApply)
        XCTAssertTrue(model.applicationNeedsSelection)
        model.prepareForSelectionMove()
        model.setSelectionContext(context("New selection"), automaticallyCheck: false)
        XCTAssertFalse(model.applicationNeedsSelection)
    }

    @MainActor
    func testRejectedApplicationRecoversWhenSameTextIsSelectedAgain() {
        let model = SelectionAssistantViewModel(routingDefaults: legacyRoutingDefaults())
        model.setSelectionContext(context("Original"), automaticallyCheck: false)
        model.acceptReview([OverlaySuggestion(operation: model.operation, text: "Corrected")], generation: model.requestID)
        model.completeApplication(.failed, onFinished: { XCTFail("A rejected write must keep the result") })
        model.setSelectionContext(context("Original"), automaticallyCheck: false)
        XCTAssertFalse(model.applicationNeedsSelection)
        XCTAssertTrue(model.resultNotice.isEmpty)
        XCTAssertTrue(model.rewrittenText.isEmpty)
        XCTAssertEqual(model.status, .waiting)
    }

    @MainActor
    func testRejectedApplicationDiscardsStaleModeErrorsAndLateReviews() {
        let model = SelectionAssistantViewModel(routingDefaults: legacyRoutingDefaults())
        model.setSelectionContext(context("Original"), automaticallyCheck: false)
        let generation = model.requestID
        model.acceptReview([OverlaySuggestion(operation: model.operation, text: "Corrected")], generation: generation)
        model.completeApplication(.failed, onFinished: { XCTFail("A rejected write must keep the result") })
        model.operation = model.operation == .humanize ? .fixGrammar : .humanize
        model.retryReview()
        model.acceptReview([OverlaySuggestion(operation: model.operation, text: "Stale")], generation: generation)
        XCTAssertEqual(model.status, .ready)
        XCTAssertEqual(model.rewrittenText, "Corrected")
        XCTAssertTrue(model.reviews.isEmpty)
        XCTAssertFalse(model.canApply)
        XCTAssertTrue(model.canTranslate)
    }

    func testAcceptedWriteWithUnavailableOrStaleReadbackIsTerminal() {
        for after in [nil, "Original", "Different editor serialization"] as [String?] {
            var writes = 0
            var reads = 0
            let result = TextAccessService.performSelectionReplacement(write: {
                writes += 1
                return true
            }, confirm: {
                reads += 1
                return TextAccessService.directReplacementWasConfirmed(before: "Original", after: after,
                    selection: nil, original: "Original", replacement: "Corrected")
            })
            XCTAssertEqual(result, .dispatched)
            XCTAssertEqual(writes, 1, "Missing readback must never cause another write")
            XCTAssertEqual(reads, 1)
        }
        XCTAssertEqual(TextAccessService.performSelectionReplacement(write: { false }, confirm: {
            XCTFail("A rejected write must not start post-insertion checks")
            return true
        }), .failed)
        XCTAssertEqual(TextAccessService.performSelectionReplacement(write: { true }, confirm: { true }), .success)
    }

    @MainActor
    func testAcceptedApplicationClosesRewriteAndTranslationWithoutWarning() {
        for action in [TextoraHotKeyAction.rewrite, .translate] {
            for result in [TextAccessService.ApplyResult.success, .dispatched] {
                let model = SelectionAssistantViewModel(routingDefaults: legacyRoutingDefaults())
                model.setSelectionContext(context("Original"), automaticallyCheck: false)
                model.acceptReview([OverlaySuggestion(operation: model.operation, text: "Corrected")], generation: model.requestID)
                model.prepareHotKeyPresentation(action)
                var closed = 0
                model.completeApplication(result, onFinished: { closed += 1 })
                XCTAssertEqual(closed, 1)
                XCTAssertEqual(model.status, .idle)
                XCTAssertEqual(model.translationStatus, .idle)
                XCTAssertFalse(model.applicationNeedsSelection)
                XCTAssertTrue(model.resultNotice.isEmpty)
                XCTAssertTrue(model.rewrittenText.isEmpty)
                XCTAssertFalse(model.canApply)
            }
        }
    }

    @MainActor
    func testFailedAndChangedTargetsKeepResultWithActionableRecovery() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for result in [TextAccessService.ApplyResult.failed, .unsupportedTarget, .clipboardArmed] {
            pasteboard.clearContents()
            pasteboard.setString("Previous clipboard", forType: .string)
            let model = SelectionAssistantViewModel(pasteboard: pasteboard, routingDefaults: legacyRoutingDefaults())
            model.setSelectionContext(context("Original"), automaticallyCheck: false)
            model.acceptReview([OverlaySuggestion(operation: model.operation, text: "Corrected")], generation: model.requestID)
            XCTAssertEqual(pasteboard.string(forType: .string), "Previous clipboard")
            model.completeApplication(result, onFinished: { XCTFail("No write was sent") })
            XCTAssertEqual(model.rewrittenText, "Corrected")
            XCTAssertFalse(model.canApply)
            XCTAssertTrue(model.applicationNeedsSelection)
            XCTAssertFalse(model.resultNotice.contains("confirmed"))
            XCTAssertEqual(pasteboard.string(forType: .string), "Corrected")
            XCTAssertEqual(model.resultNotice, "Could not insert. Copied to clipboard - press ⌘V.")
            if result == .unsupportedTarget {
                try snapshot(model, name: "paste-recovery-toolpanel", size: CGSize(width: SelectionToolbarView.toolPanelWidth, height: 164))
                model.prepareHotKeyPresentation(.rewrite)
                try snapshot(model, name: "paste-recovery-hotkeys", size: CGSize(width: 510, height: SelectionToolbarView.hotKeyPanelHeight(for: model)))
            }
        }
    }

    @MainActor
    func testFailedTranslationCopiesTranslationAndKeepsPreview() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for result in [TextAccessService.ApplyResult.failed, .unsupportedTarget, .clipboardArmed] {
            pasteboard.clearContents()
            pasteboard.setString("Previous clipboard", forType: .string)
            let model = SelectionAssistantViewModel(pasteboard: pasteboard, routingDefaults: legacyRoutingDefaults())
            model.prepareHotKeyPresentation(.translate)
            model.setSelectionContext(context("Good morning"), automaticallyCheck: false, preservePresentation: true)
            model.acceptTranslation("Доброе утро")
            XCTAssertEqual(model.translationStatus, .ready)
            XCTAssertEqual(pasteboard.string(forType: .string), "Previous clipboard")
            model.completeApplication(result, onFinished: { XCTFail("Failed insertion must keep the preview open") })
            XCTAssertEqual(model.translatedText, "Доброе утро")
            XCTAssertEqual(pasteboard.string(forType: .string), "Доброе утро")
            XCTAssertEqual(model.resultNotice, "Could not insert. Copied to clipboard - press ⌘V.")
            XCTAssertTrue(model.applicationNeedsSelection)
            XCTAssertFalse(model.isApplying)
            XCTAssertTrue(model.canTranslate)
            if result == .unsupportedTarget {
                try snapshot(model, name: "translation-paste-recovery-hotkeys", size: CGSize(width: 510, height: SelectionToolbarView.hotKeyPanelHeight(for: model)))
            }
        }
    }

    @MainActor
    private func waitForTranslation(_ model: SelectionAssistantViewModel,
                                    status: SelectionAssistantViewModel.TranslationStatus) async {
        if model.translationStatus == status { return }
        let finished = expectation(description: "Translation status: \(status)")
        let observation = model.$translationStatus.filter { $0 == status }.prefix(1).sink { _ in finished.fulfill() }
        await fulfillment(of: [finished], timeout: 3)
        observation.cancel()
    }

    @MainActor
    func testChangingLanguageAfterFailedInsertionTranslatesOriginalAndCopiesNewResult() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let key = SelectionAssistantSettings.Keys.translationLanguage
        let previousLanguage = UserDefaults.standard.object(forKey: key)
        defer {
            if let previousLanguage { UserDefaults.standard.set(previousLanguage, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        for hotKey in [false, true] {
            for failure in [TextAccessService.ApplyResult.failed, .unsupportedTarget, .clipboardArmed] {
                var requests: [(String, TranslationLanguage)] = []
                let model = SelectionAssistantViewModel(pasteboard: pasteboard, translator: { text, language in
                    requests.append((text, language))
                    return language == .russian ? "Доброе утро" : "Bonjour"
                }, routingDefaults: legacyRoutingDefaults())
                if hotKey { model.prepareHotKeyPresentation(.translate) }
                model.translationLanguage = .russian
                model.setSelectionContext(context("Good morning"), automaticallyCheck: false, preservePresentation: hotKey)
                model.translate()
                await waitForTranslation(model, status: .ready)
                model.completeApplication(failure, onFinished: { XCTFail("Failed insertion must keep the panel") })
                XCTAssertEqual(pasteboard.string(forType: .string), "Доброе утро")
                XCTAssertTrue(model.applicationNeedsSelection)
                model.selectTranslationLanguage(.french)
                XCTAssertEqual(model.translationStatus, .translating)
                XCTAssertTrue(model.resultNotice.isEmpty)
                XCTAssertFalse(model.canUseTranslation)
                XCTAssertFalse(model.copyTranslation())
                if failure == .unsupportedTarget {
                    try snapshot(model, name: hotKey ? "translate-language-change-loading-hotkeys" : "translate-language-change-loading-toolpanel",
                                 size: CGSize(width: hotKey ? 510 : SelectionToolbarView.toolPanelWidth,
                                              height: hotKey ? SelectionToolbarView.hotKeyPanelHeight(for: model) : 164))
                }
                await waitForTranslation(model, status: .ready)
                XCTAssertEqual(model.translatedText, "Bonjour")
                XCTAssertEqual(model.originalText, "Good morning")
                XCTAssertEqual(requests.map { $0.0 }, ["Good morning", "Good morning"])
                XCTAssertEqual(requests.map { $0.1 }, [.russian, .french])
                XCTAssertTrue(model.canUseTranslation)
                XCTAssertTrue(model.applicationNeedsSelection, "A new translation must not re-enable insertion into a stale selection")
                // The same result click now copies; it must never retry AX or close.
                model.applyTranslation(onFinished: { XCTFail("Copy must leave language switching available") })
                XCTAssertEqual(pasteboard.string(forType: .string), "Bonjour")
                XCTAssertEqual(model.resultNotice, "Copied - press ⌘V")
                XCTAssertFalse(model.isApplying)
                model.selectTranslationLanguage(.russian)
                await waitForTranslation(model, status: .ready)
                XCTAssertTrue(model.copyTranslation())
                XCTAssertEqual(pasteboard.string(forType: .string), "Доброе утро")
            }
        }
    }

    @MainActor
    func testCopyThenChangeLanguageKeepsSourceAndStartsTranslation() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var requests = 0
        let model = SelectionAssistantViewModel(pasteboard: pasteboard, translator: { text, language in
            requests += 1
            return "\(language.rawValue): \(text)"
        }, routingDefaults: legacyRoutingDefaults())
        model.translationLanguage = .english
        model.setSelectionContext(context("Original"), automaticallyCheck: false)
        model.selectTranslationLanguage(.russian)
        XCTAssertEqual(requests, 0, "Choosing a language before entering Translate must not send a request")
        model.translate()
        await waitForTranslation(model, status: .ready)
        XCTAssertTrue(model.copyTranslation())
        XCTAssertFalse(model.applicationNeedsSelection)
        model.selectTranslationLanguage(.french)
        await waitForTranslation(model, status: .ready)
        XCTAssertEqual(model.translatedText, "french: Original")
        XCTAssertEqual(requests, 2)
        XCTAssertTrue(model.copyTranslation())
        XCTAssertEqual(pasteboard.string(forType: .string), "french: Original")
        model.selectTranslationLanguage(.french)
        XCTAssertEqual(requests, 2, "Selecting the current ready language must not duplicate a request")
    }

    @MainActor
    func testLatestLanguageWinsEvenWhenCancelledTranslationReturnsLate() async {
        var pending: [TranslationLanguage: CheckedContinuation<String, Error>] = [:]
        let firstStarted = expectation(description: "Russian request started")
        let secondStarted = expectation(description: "French request started")
        let firstCompleted = expectation(description: "Cancelled request returned late")
        let model = SelectionAssistantViewModel(translator: { _, language in
            let result: String = try await withCheckedThrowingContinuation { continuation in
                pending[language] = continuation
                (language == .russian ? firstStarted : secondStarted).fulfill()
            }
            if language == .russian { firstCompleted.fulfill() }
            return result
        }, routingDefaults: legacyRoutingDefaults())
        model.translationLanguage = .russian
        model.setSelectionContext(context("Original"), automaticallyCheck: false)
        model.translate()
        await fulfillment(of: [firstStarted], timeout: 3)
        model.selectTranslationLanguage(.french)
        await fulfillment(of: [secondStarted], timeout: 3)
        pending.removeValue(forKey: .french)?.resume(returning: "Bonjour")
        await waitForTranslation(model, status: .ready)
        pending.removeValue(forKey: .russian)?.resume(returning: "Late response")
        await fulfillment(of: [firstCompleted], timeout: 3)
        XCTAssertEqual(model.translatedText, "Bonjour")
        XCTAssertEqual(model.translationLanguage, .french)
        XCTAssertEqual(model.translationStatus, .ready)
    }

    @MainActor
    func testTranslationErrorAfterClipboardFallbackCanBeRetried() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var shouldFail = true
        let model = SelectionAssistantViewModel(pasteboard: pasteboard, translator: { _, _ in
            if shouldFail { throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Translation unavailable"]) }
            return "Bonjour"
        }, routingDefaults: legacyRoutingDefaults())
        model.prepareHotKeyPresentation(.translate)
        model.translationLanguage = .russian
        model.setSelectionContext(context("Original"), automaticallyCheck: false, preservePresentation: true)
        model.acceptTranslation("Оригинал")
        model.completeApplication(.failed, onFinished: { XCTFail() })
        model.selectTranslationLanguage(.french)
        await waitForTranslation(model, status: .error("Translation unavailable"))
        XCTAssertTrue(model.translatedText.isEmpty)
        XCTAssertFalse(model.canUseTranslation)
        XCTAssertFalse(model.copyTranslation())
        XCTAssertTrue(model.canTranslate)
        try snapshot(model, name: "translate-language-change-error-hotkeys",
                     size: CGSize(width: 510, height: SelectionToolbarView.hotKeyPanelHeight(for: model)))
        shouldFail = false
        model.selectTranslationLanguage(.french)
        await waitForTranslation(model, status: .ready)
        XCTAssertTrue(model.copyTranslation())
        XCTAssertEqual(pasteboard.string(forType: .string), "Bonjour")
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
        let model = SelectionAssistantViewModel(routingDefaults: legacyRoutingDefaults())
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
        let model = SelectionAssistantViewModel(routingDefaults: legacyRoutingDefaults())
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
        let model = SelectionAssistantViewModel(routingDefaults: legacyRoutingDefaults())
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
        XCTAssertEqual(MicrophoneTip.languages.next(smartDirection: true), .drag)
        XCTAssertEqual(MicrophoneTip.languages.next(smartDirection: false), .swap)
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

    func testUserClipboardShortcutsAreRecognizedWithoutIgnoringRealInputDuringProbe() {
        for keyCode: UInt16 in [7, 8, 9] {
            for flags: NSEvent.ModifierFlags in [.command, [.command, .shift], [.command, .option, .shift]] {
                XCTAssertTrue(SelectionAssistantController.isUserClipboardShortcut(keyCode: keyCode, characters: "ф", modifiers: flags))
                XCTAssertFalse(SelectionAssistantController.isUserClipboardShortcut(keyCode: keyCode, characters: nil, modifiers: flags,
                    sourceUserData: TextAccessService.syntheticSelectionEventTag))
            }
            XCTAssertFalse(SelectionAssistantController.isUserClipboardShortcut(keyCode: keyCode, characters: nil, modifiers: []))
        }
        for character in ["c", "C", "x", "v"] {
            XCTAssertTrue(SelectionAssistantController.isUserClipboardShortcut(keyCode: 50, characters: character, modifiers: .command))
        }
        XCTAssertFalse(SelectionAssistantController.isUserClipboardShortcut(keyCode: 0, characters: "a", modifiers: .command))
        for keyCode: CGKeyCode in [8, 9] {
            let events = TextAccessService.clipboardShortcutEvents(keyCode: keyCode)
            XCTAssertEqual(events.count, 2)
            XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
            for event in events {
                XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), TextAccessService.syntheticSelectionEventTag)
                XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), Int64(keyCode))
                XCTAssertTrue(event.flags.contains(.maskCommand))
            }
        }
    }

    @MainActor
    func testAutomaticSelectionNeverBorrowsClipboardButExplicitInvocationCan() async throws {
        let pasteboard = NSPasteboard(name: .init("Textora.passive-selection.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("User copied text", forType: .string)
        let html = Data("<span style='font-family:sans-serif'>User copied text</span>".utf8)
        item.setData(html, forType: .html)
        pasteboard.writeObjects([item])
        let originalChangeCount = pasteboard.changeCount
        let expected = context("AX selection")
        var allowedReads = [Bool]()
        let worker = SelectionTextWorker(selectionReader: { allowClipboard in
            allowedReads.append(allowClipboard)
            if allowClipboard {
                pasteboard.clearContents()
                pasteboard.setString("Simulated explicit copy", forType: .string)
            }
            return expected
        })
        for _ in 0..<20 {
            let selection = await worker.selection()
            XCTAssertEqual(selection?.text, expected.text)
            XCTAssertEqual(pasteboard.changeCount, originalChangeCount, "Even temporary writes would race with first paste")
            XCTAssertEqual(pasteboard.string(forType: .string), "User copied text")
            XCTAssertEqual(pasteboard.data(forType: .html), html)
        }
        XCTAssertEqual(allowedReads, Array(repeating: false, count: 20))
        _ = await worker.selection(intent: .userInvoked)
        XCTAssertEqual(allowedReads.last, true, "An explicit Textora hotkey keeps the fallback for weak AX applications")
        XCTAssertEqual(pasteboard.string(forType: .string), "Simulated explicit copy")
    }

    func testCancelledSelectionDoesNotStartCopyFallback() async {
        var reads = 0
        let worker = SelectionTextWorker(selectionReader: { _ in reads += 1; return nil })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await worker.selection(intent: .userInvoked)
        }
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertEqual(reads, 0)
    }

    func testPassiveSelectionUsesAXTextOrExactUTF16RangeWithoutClipboard() {
        XCTAssertEqual(TextAccessService.passiveSelectedText(selectedText: "selected without range", value: nil, range: nil), "selected without range")
        let value = "Before Привет 👩🏽‍💻 after"
        let range = (value as NSString).range(of: "Привет 👩🏽‍💻")
        XCTAssertEqual(TextAccessService.passiveSelectedText(selectedText: nil, value: value,
            range: CFRange(location: range.location, length: range.length)), "Привет 👩🏽‍💻")
        for range in [CFRange(location: -1, length: 1), CFRange(location: 0, length: 0),
                      CFRange(location: 999, length: 1), CFRange(location: 1, length: Int.max)] {
            XCTAssertNil(TextAccessService.passiveSelectedText(selectedText: nil, value: value, range: range))
        }
        XCTAssertNil(TextAccessService.passiveSelectedText(selectedText: "  ", value: nil, range: nil))
        XCTAssertNil(TextAccessService.passiveSelectedText(selectedText: nil, value: "   ", range: CFRange(location: 0, length: 2)))
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
        let model = SelectionAssistantViewModel(routingDefaults: legacyRoutingDefaults())
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
        let model = SelectionAssistantViewModel(routingDefaults: legacyRoutingDefaults())
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
        let view = NSHostingView(rootView: SelectionToolbarView(viewModel: model, onApply: {}, onClose: {}).environment(\.colorScheme, .dark))
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: "/private/tmp/textora-ui")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }

    private func numericReview(_ original: String, _ candidate: String) throws -> [OverlaySuggestion] {
        let payload: [String: Any] = ["fix": candidate, "formal": candidate,
            "shorten": candidate, "humanize": candidate, "recommended": "fix", "questions": []]
        let raw = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        return try AIClient().decodeCompleteReview(raw, original: original, requireMeaningAssessment: true)
    }

    func testCreditLimitScreenshotAllowsGrammarAndThousandsFormattingInEveryMode() throws {
        let original = "Please increase to 20,000 credits/month until 2026-10-31 with rolling back to 12000 starting 2026-11-01.\n\n(i) Confirmed with David re this new functionality from OpenAI with a temporary increase of limits. It will help us to provide extra credits for dedicated projects whilst control the budget spend on AI."
        let corrected = "Please increase the limit to 20,000 credits/month until 2026-10-31, then revert to 12,000 starting 2026-11-01.\n\n(i) I confirmed this new OpenAI functionality with David, including a temporary increase in limits. It will help us provide extra credits for dedicated projects while controlling AI spending."
        for result in try numericReview(original, corrected) {
            XCTAssertNil(result.validationError, result.operation.rawValue)
            XCTAssertEqual(result.text, corrected)
        }
    }

    func testThousandsSeparatorsAreEquivalentInBothDirections() throws {
        for (plain, grouped) in [("12000", "12,000"), ("20000", "20,000"),
                                 ("1000", "1,000"), ("1234567", "1,234,567"),
                                 ("12345678", "12,345,678"), ("12000.50", "12,000.50"),
                                 ("9007199254740993", "9,007,199,254,740,993")] {
            for (before, after) in [(plain, grouped), (grouped, plain)] {
                XCTAssertTrue(try numericReview("Allow \(before) credits", "Allow \(after) credits").allSatisfy { $0.validationError == nil }, "\(before) → \(after)")
            }
        }
    }

    func testCalendarAndClockFormattingMatrix() throws {
        let dateVariants = ["20th October 2026", "20 October 2026", "October 20, 2026", "Oct. 20th, 2026", "2026-10-20"]
        let timeVariants = ["14:10-14:20", "14:10–14:20", "14:10 — 14:20", "14:10 to 14:20",
                            "14:10 and 14:20", "2:10 PM–2:20 PM", "2:10–2:20 PM", "14:10:00-14:20:00"]
        for date in dateVariants {
            for time in timeVariants {
                let text = "Appointment at \(time) on \(date)."
                let baseline = "Appointment at 14:10-14:20 on 20th October 2026."
                for (before, after) in [(baseline, text), (text, baseline)] {
                    XCTAssertTrue(try numericReview(before, after).allSatisfy { $0.validationError == nil }, "\(before) → \(after)")
                }
            }
        }
        for (before, after) in [("00:00", "12:00 AM"), ("12:00", "12:00 PM"), ("09:05", "9:05 AM"),
                                ("1st January", "January 1"), ("2nd Feb. 2028", "2028-02-02"),
                                ("23rd September 2026", "Sep 23, 2026")] {
            XCTAssertTrue(try numericReview(before, after).allSatisfy { $0.validationError == nil }, "\(before) → \(after)")
        }
    }

    func testCalendarAndClockValueChangesRemainFlagged() throws {
        let baseline = "Appointment at 14:10-14:20 on 20th October 2026."
        for changed in ["14:11-14:20", "14:10-14:21", "14:20-14:10", "2:10 AM–2:20 AM", "14:10", "14:10-14:20:01"] {
            XCTAssertTrue(try numericReview(baseline, "Appointment at \(changed) on 20 October 2026.").allSatisfy { $0.validationError != nil }, changed)
        }
        for changed in ["21 October 2026", "20 November 2026", "20 October 2027", "20 October", "2026-10-20 and 2026-10-20"] {
            XCTAssertTrue(try numericReview(baseline, "Appointment at 14:10–14:20 on \(changed).").allSatisfy { $0.validationError != nil }, changed)
        }
        for (before, after) in [("20th", "21st"), ("12:00 AM", "12:00 PM"), ("-12.5", "12.5"),
                                ("12%", "12"), ("12‰", "12%"),
                                ("https://example.com/2026-10-20", "https://example.com/20-10-2026"),
                                ("ID AB2026-10-20", "ID AB2026-10-21"),
                                ("Call +44 20 1234 5678", "Call +44 20 1234 5679")] {
            XCTAssertTrue(try numericReview(before, after).allSatisfy { $0.validationError != nil }, "\(before) → \(after)")
        }
    }

    func testNumericValueChangesRemainRejected() throws {
        for (before, after) in [("12,000", "12,001"), ("20,000", "2,000"),
                                 ("12000", "120000"), ("12,000.50", "12,000.05"),
                                 ("12.5", "125"), ("1,25", "125"),
                                 ("1,234,56", "123456"), ("0012000", "12,000"),
                                 ("9,007,199,254,740,993", "9007199254740992")] {
            XCTAssertTrue(try numericReview("Allow \(before) credits", "Allow \(after) credits").allSatisfy { $0.validationError != nil }, "\(before) → \(after)")
        }
    }

    func testFormattingDoesNotHideMissingAddedOrDuplicatedNumbers() throws {
        let original = "Allow 20,000 credits, then 12000 credits."
        for candidate in ["Allow 20,000 credits.", "Allow 12,000 credits.",
                          "Allow 20,000 credits, then 12,000 credits and 500 credits.",
                          "Allow 20,000 credits, then 12,000 credits and 12,000 credits."] {
            XCTAssertTrue(try numericReview(original, candidate).allSatisfy { $0.validationError != nil }, candidate)
        }
    }

    func testThousandsFormattingStillProtectsDatesCurrencyLinksAndIdentifiers() throws {
        let pairs = [
            ("until 2026-10-31", "until 2026-11-01"),
            ("from 2026-11-01", "from 2026-11-02"),
            ("EUR", "USD"), ("€", "$"),
            ("https://example.com/12000", "https://example.com/12,000"),
            ("person12000@example.com", "person12001@example.com"),
            ("@team12000", "@team12001"), ("#project12000", "#project12001"),
            ("ID AB12000", "ID AB12001"),
            ("🙂", "😢")
        ]
        for (before, after) in pairs {
            XCTAssertTrue(try numericReview("Allow 12000 credits \(before)", "Allow 12,000 credits \(before)").allSatisfy { $0.validationError == nil }, before)
            XCTAssertTrue(try numericReview("Allow 12000 credits \(before)", "Allow 12,000 credits \(after)").allSatisfy { $0.validationError != nil }, "\(before) → \(after)")
        }
    }

    @MainActor
    func testFormattedNumbersProduceActionablePreviewInAllModes() throws {
        let model = SelectionAssistantViewModel(routingDefaults: legacyRoutingDefaults())
        let original = "Please increase to 20000 credits until 2026-10-31."
        model.setSelectionContext(context(original), automaticallyCheck: false)
        model.acceptReview(try numericReview(original, "Please increase the limit to 20,000 credits until 2026-10-31."), generation: model.requestID)
        for operation in RewriteOperation.allCases {
            model.operation = operation
            XCTAssertEqual(model.status, .ready)
            XCTAssertTrue(model.canApply, operation.rawValue)
            XCTAssertEqual(model.reviews[operation], .suggestion)
        }
    }

    @MainActor
    func testTokenValidationDoesNotDiscardOrBlockGeneratedVariants() throws {
        let original = "Allow 12000 credits until 2026-10-31."
        let safe = "Allow 12,000 credits until 2026-10-31."
        let payload = ["fix": "Allow 20,000 credits until 2026-10-31.",
                       "formal": safe, "shorten": safe, "humanize": safe, "recommended": "fix"]
        let raw = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        let results = try AIClient().decodeCompleteReview(raw, original: original)
        let model = SelectionAssistantViewModel(routingDefaults: legacyRoutingDefaults())
        model.setSelectionContext(context(original), automaticallyCheck: false)
        model.acceptReview(results, generation: model.requestID)
        for operation in RewriteOperation.allCases {
            model.operation = operation
            XCTAssertTrue(model.canApply, operation.rawValue)
            XCTAssertEqual(model.reviews[operation], .suggestion)
            if operation == .fixGrammar {
                XCTAssertEqual(model.rewrittenText, payload["fix"])
            } else {
                XCTAssertEqual(model.rewrittenText, safe)
            }
        }
    }

    @MainActor
    func testSchoolAppointmentPreviewSurvivesProtectedDateFormatting() throws {
        let original = "Good morning dear teachers, Can I have an appointment at 14:10–14:20 for Primary Parents' Evening on Tuesday, 20th October 2026? Thank you."
        let candidate = "Good morning, dear teachers. Could I please book an appointment from 14:10 to 14:20 for Primary Parents’ Evening on Tuesday, 20 October 2026? Thank you."
        let results = try numericReview(original, candidate)
        XCTAssertTrue(results.allSatisfy { $0.validationError == nil })
        let model = SelectionAssistantViewModel(routingDefaults: legacyRoutingDefaults())
        model.prepareHotKeyPresentation(.rewrite)
        model.setSelectionContext(context(original), automaticallyCheck: false, preservePresentation: true)
        model.acceptReview(results, generation: model.requestID)
        for operation in RewriteOperation.allCases {
            model.operation = operation
            XCTAssertEqual(model.rewrittenText, candidate)
            XCTAssertEqual(model.status, .ready)
            XCTAssertTrue(model.canApply)
        }
        try snapshot(model, name: "school-appointment-preview", size: CGSize(width: 510, height: SelectionToolbarView.hotKeyPanelHeight(for: model)))
    }

    func testRetryFetchesFreshReviewAfterNumericValidationFailure() async throws {
        let service = RewriteReviewService()
        let original = "Allow 12000 credits until 2026-10-31."
        let unsafe = try numericReview(original, "Allow 20000 credits until 2026-10-31.")
        let safe = try numericReview(original, "Allow 12,000 credits until 2026-10-31.")
        let first = try await service.review(key: "credit-limit") { unsafe }
        XCTAssertTrue(first.allSatisfy { $0.validationError != nil })
        let retried = try await service.review(key: "credit-limit") { safe }
        XCTAssertTrue(retried.allSatisfy { $0.validationError == nil })
        XCTAssertTrue(retried.allSatisfy { $0.text.contains("12,000") })
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

    func testReviewRetainsVariantWithChangedProtectedURL() throws {
        let result = try AIClient().decodeCompleteReview(#"{"fix":"See https://evil.example","formal":"See https://safe.example","shorten":"See https://safe.example","humanize":"See https://safe.example","recommended":"fix"}"#, original: "See https://safe.example")
        XCTAssertNotNil(result.first?.validationError)
        XCTAssertEqual(result.first?.text, "See https://evil.example")
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
        let model = SelectionAssistantViewModel(routingDefaults: legacyRoutingDefaults())
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
        let model = SelectionAssistantViewModel(routingDefaults: legacyRoutingDefaults())
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
