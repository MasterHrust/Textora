import Carbon
import AppKit
import XCTest
@testable import Textora

final class OfflineSpeechTests: XCTestCase {
    private func dictationTargetFixture() -> TextAccessService.DictationTarget {
        .init(element: AXUIElementCreateApplication(123), appPID: 123,
              bundleID: "com.tinyspeck.slackmacgap", selectedRange: CFRange(location: 0, length: 0),
              anchor: .zero, elementFrame: .zero, role: "AXTextArea", subrole: "",
              identifier: "message-editor", originalValue: "")
    }

    func testSlackAccessibilityHandshakeDoesNotIncludeTelegramOrOtherApps() {
        XCTAssertTrue(TextAccessService.needsExplicitDictationAccessibility(bundleID: "com.tinyspeck.slackmacgap"))
        XCTAssertTrue(TextAccessService.needsExplicitDictationAccessibility(bundleID: "COM.TINYSPECK.SLACKMACGAP"))
        for bundle in ["ru.keepcoder.Telegram", "org.telegram.desktop", "com.apple.Notes", "com.google.Chrome", "", "other.slack.app"] {
            XCTAssertFalse(TextAccessService.needsExplicitDictationAccessibility(bundleID: bundle))
        }
    }

    func testDictationWaitsForSlackAccessibilityTreeAfterOneHandshake() async {
        let target = dictationTargetFixture()
        var reads = 0
        var preparations = 0
        var waits = 0
        let result = await SelectionTextWorker.resolveDictationTarget(read: {
            reads += 1
            return reads == 3 ? .success(target) : .unavailable
        }, prepareAccessibility: {
            preparations += 1
            return true
        }, isOriginalAppActive: { true }, waitForAccessibility: { waits += 1 })
        guard case .success(let captured) = result else { return XCTFail("Expected the newly exposed editor") }
        XCTAssertEqual(captured.identifier, "message-editor")
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(waits, 2)
    }

    func testAvailableDictationTargetDoesNotEnableAccessibilityOrWait() async {
        let target = dictationTargetFixture()
        let result = await SelectionTextWorker.resolveDictationTarget(read: { .success(target) },
            prepareAccessibility: { XCTFail("Working targets must keep their existing path"); return false },
            isOriginalAppActive: { true }, waitForAccessibility: { XCTFail("No delay for a working target") })
        guard case .success = result else { return XCTFail("Expected original target") }
    }

    func testSlackDictationDoesNotRetryPermissionOrSecureFieldFailures() async {
        let cases: [TextAccessService.DictationTargetResult] = [
            .permissionDenied, .secureField, .permissionRequired(bundleID: "test", anchor: .zero)
        ]
        for initial in cases {
            var reads = 0
            _ = await SelectionTextWorker.resolveDictationTarget(read: { reads += 1; return initial },
                prepareAccessibility: { XCTFail("Do not bypass consent or secure-field exclusions"); return true },
                isOriginalAppActive: { true }, waitForAccessibility: { XCTFail("Do not retry") })
            XCTAssertEqual(reads, 1)
        }
    }

    func testSlackDictationRetriesAreBoundedAndRequireSuccessfulHandshake() async {
        for prepared in [false, true] {
            var reads = 0
            var waits = 0
            let result = await SelectionTextWorker.resolveDictationTarget(read: { reads += 1; return .unavailable },
                prepareAccessibility: { prepared }, isOriginalAppActive: { true }, waitForAccessibility: { waits += 1 })
            guard case .unavailable = result else { return XCTFail("Never invent a target") }
            XCTAssertEqual(reads, prepared ? 4 : 1)
            XCTAssertEqual(waits, prepared ? 3 : 0)
        }
    }

    func testSlackDictationStopsWhenAppChangesOrRequestIsCancelled() async {
        var active = true
        var reads = 0
        let result = await SelectionTextWorker.resolveDictationTarget(read: { reads += 1; return .unavailable },
            prepareAccessibility: { true }, isOriginalAppActive: { active }, waitForAccessibility: { active = false })
        guard case .unavailable = result else { return XCTFail("Do not capture the newly focused app") }
        XCTAssertEqual(reads, 1)
        let task = Task {
            var reads = 0
            let result = await SelectionTextWorker.resolveDictationTarget(read: { reads += 1; return .unavailable },
                prepareAccessibility: { true }, isOriginalAppActive: { true }, waitForAccessibility: {
                    withUnsafeCurrentTask { $0?.cancel() }
                })
            XCTAssertEqual(reads, 1)
            guard case .unavailable = result else { return XCTFail("Do not read after cancellation") }
        }
        await task.value
    }

    func testDictationRecognizesWritableContenteditableContainersWithoutNativeTextRoles() {
        for role in ["AXGroup", "AXGenericElement", "AXLayoutArea"] {
            // Empty editors need not expose AXValue or an AX selection range.
            // A supported writable text operation is sufficient on the focus chain.
            XCTAssertTrue(TextAccessService.isWritableDictationContainer(role: role, subrole: "",
                editable: nil, enabled: true, readOnly: nil, selectedTextSettable: true, valueSettable: false))
            XCTAssertTrue(TextAccessService.isWritableDictationContainer(role: role, subrole: "",
                editable: nil, enabled: nil, readOnly: nil, selectedTextSettable: false, valueSettable: true))
            XCTAssertFalse(TextAccessService.isWritableDictationContainer(role: role, subrole: "",
                editable: nil, enabled: true, readOnly: nil, selectedTextSettable: false, valueSettable: false))
        }
    }

    func testDictationContainerFallbackRejectsReadOnlyDisabledSecureAndNonTextControls() {
        for (editable, enabled, readOnly): (Bool?, Bool?, Bool?) in [(false, true, nil), (nil, false, nil), (true, true, true)] {
            XCTAssertFalse(TextAccessService.isWritableDictationContainer(role: "AXGroup", subrole: "",
                editable: editable, enabled: enabled, readOnly: readOnly, selectedTextSettable: true, valueSettable: true))
        }
        for role in ["AXStaticText", "AXButton", "AXSlider", "AXCheckBox", "AXWebArea", "AXWindow", "AXApplication", "AXMenuItem"] {
            XCTAssertFalse(TextAccessService.isWritableDictationContainer(role: role, subrole: "",
                editable: nil, enabled: true, readOnly: nil, selectedTextSettable: false, valueSettable: true))
        }
        XCTAssertFalse(TextAccessService.isWritableDictationContainer(role: "AXGroup", subrole: "AXSecureTextField",
            editable: true, enabled: true, readOnly: nil, selectedTextSettable: true, valueSettable: true))
    }

    private func focusedDictationGraph(focused: Int?, links: [Int: Int] = [:], parents: [Int: Int] = [:],
                                        editable: Set<Int>, excluded: Set<Int> = [], foreign: Set<Int> = [],
                                        alternates: [Int] = [], maximumNodes: Int = 24) -> Int? {
        TextAccessService.resolveDictationFocus(focused: focused, alternateFocusedElements: { alternates },
            isSameNode: { $0 == $1 }, isOwnedByOriginalApp: { !foreign.contains($0) },
            focusedChild: { links[$0] }, parent: { parents[$0] },
            isExcluded: { excluded.contains($0) }, isEditable: { editable.contains($0) }, maximumNodes: maximumNodes)
    }

    func testDictationFollowsDeclaredFocusedChildWhenSystemFocusIsAContainer() {
        XCTAssertEqual(focusedDictationGraph(focused: 1, links: [1: 2], editable: [2]), 2)
        XCTAssertEqual(focusedDictationGraph(focused: 1, parents: [1: 3], editable: [2], alternates: [2]), 2)
        // The application/window may expose a deeper focus endpoint than the
        // successfully returned system-wide container. No child tree is scanned.
        XCTAssertEqual(focusedDictationGraph(focused: 1, links: [3: 2], parents: [1: 3], editable: [2]), 2)
    }

    func testDictationRetainsWritableParentForStaticTextInsideAnEditor() {
        XCTAssertEqual(focusedDictationGraph(focused: 1, parents: [1: 2, 2: 3], editable: [2]), 2)
        XCTAssertNil(focusedDictationGraph(focused: 1, parents: [1: 3], editable: []), "Static text and whole documents do not become editors")
    }

    func testDictationSensitiveFocusIsATerminalBarrierBeforeEditableAncestorsOrAlternates() {
        XCTAssertEqual(focusedDictationGraph(focused: 1, parents: [1: 2], editable: [2, 3], excluded: [1], alternates: [3]), 1)
        XCTAssertEqual(focusedDictationGraph(focused: 1, links: [1: 2], editable: [1, 3], excluded: [2], alternates: [3]), 2)
        // Disabled/read-only native controls are excluded by the same gate.
        XCTAssertEqual(focusedDictationGraph(focused: 1, parents: [1: 2], editable: [2], excluded: [1]), 1)
    }

    func testDictationFocusNeverAcceptsForeignAppNodesAndDoesNotSearchUnrelatedEditors() {
        XCTAssertNil(focusedDictationGraph(focused: 1, links: [1: 2], editable: [2], foreign: [2]))
        XCTAssertNil(focusedDictationGraph(focused: 1, editable: [2]), "An unrelated editor is not visited without an actual focus or ancestor link")
        XCTAssertNil(focusedDictationGraph(focused: 1, editable: [1], foreign: [1]))
    }

    func testDictationFocusTraversalHandlesCyclesAndHasOneSharedNodeBudget() {
        XCTAssertNil(focusedDictationGraph(focused: 1, links: [1: 2, 2: 1], parents: [1: 2, 2: 1], editable: []))
        var visited: [Int] = []
        let result = TextAccessService.resolveDictationFocus(focused: 0, alternateFocusedElements: { [100] },
            isSameNode: { $0 == $1 }, isOwnedByOriginalApp: { visited.append($0); return true },
            focusedChild: { _ in nil }, parent: { $0 + 1 }, isExcluded: { _ in false },
            isEditable: { $0 == 100 }, maximumNodes: 24)
        XCTAssertNil(result)
        XCTAssertEqual(visited, Array(0..<24), "Alternate endpoints cannot reset the traversal budget")
    }

    func testDictationRequiresPositiveEditabilityAndNeverTreatsADocumentOrLabelAsAField() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox"] {
            XCTAssertTrue(TextAccessService.isWritableDictationContainer(role: role, subrole: "", editable: nil,
                enabled: true, readOnly: nil, selectedTextSettable: false, valueSettable: false))
            XCTAssertFalse(TextAccessService.isWritableDictationContainer(role: role, subrole: "", editable: false,
                enabled: true, readOnly: nil, selectedTextSettable: true, valueSettable: true))
        }
        for role in ["AXGroup", "AXGenericElement", "AXLayoutArea"] {
            XCTAssertTrue(TextAccessService.isWritableDictationContainer(role: role, subrole: "", editable: true,
                enabled: true, readOnly: nil, selectedTextSettable: false, valueSettable: false))
        }
        for role in ["AXWebArea", "AXDocument", "AXStaticText", "AXWindow", "AXApplication", "AXButton", "AXMenuItem"] {
            XCTAssertFalse(TextAccessService.isWritableDictationContainer(role: role, subrole: "", editable: true,
                enabled: true, readOnly: nil, selectedTextSettable: true, valueSettable: true))
        }
    }

    func testCopyOnlyDictationRequiresAnAllowedStableNonSensitiveOrigin() {
        func allowed(originPID: pid_t = 123, originBundle: String = "test.app", currentPID: pid_t? = 123,
                     currentBundle: String? = "test.app", trusted: Bool = true,
                     consent: TextAccessService.AppConsentStatus = .allowed,
                     own: Bool = false, suppressed: Bool = false, sensitive: Bool = false) -> Bool {
            TextAccessService.canUseCopyOnlyDictation(originPID: originPID, originBundleID: originBundle,
                currentPID: currentPID, currentBundleID: currentBundle, accessibilityTrusted: trusted,
                consent: consent, isOwnApplication: own, isSuppressedApplication: suppressed, isSensitiveField: sensitive)
        }
        XCTAssertTrue(allowed())
        XCTAssertFalse(allowed(trusted: false))
        XCTAssertFalse(allowed(consent: .unknown))
        XCTAssertFalse(allowed(consent: .denied))
        XCTAssertFalse(allowed(currentPID: 456))
        XCTAssertFalse(allowed(currentPID: nil))
        XCTAssertFalse(allowed(currentBundle: "other.app"))
        XCTAssertFalse(allowed(currentBundle: nil))
        XCTAssertFalse(allowed(originPID: 0, currentPID: 0))
        XCTAssertFalse(allowed(originBundle: "", currentBundle: ""))
        XCTAssertFalse(allowed(own: true))
        XCTAssertFalse(allowed(suppressed: true))
        XCTAssertFalse(allowed(sensitive: true))
    }

    func testParakeetDescriptorIsImmutableHTTPSArtifact() {
        let model = SpeechModelDescriptor.parakeetV3Q4
        XCTAssertEqual(model.downloadURL.scheme, "https")
        XCTAssertTrue(model.downloadURL.path.contains("85ac09ea12fc4b1112fa76810059364bc6adc9de"))
        XCTAssertEqual(model.byteCount, 485_425_504)
        XCTAssertEqual(model.sha256.count, 64)
    }

    func testModelDownloadPolicyRejectsHTTPRedirect() throws {
        XCTAssertTrue(SpeechModelDownloadPolicy.allows(URL(string: "https://models.example.com/model.gguf")))
        XCTAssertFalse(SpeechModelDownloadPolicy.allows(URL(string: "http://models.example.com/model.gguf")))
        XCTAssertNil(SpeechModelDownloadPolicy.redirectedRequest(
            URLRequest(url: try XCTUnwrap(URL(string: "http://cdn.example.com/model.gguf")))
        ))
        XCTAssertNotNil(SpeechModelDownloadPolicy.redirectedRequest(
            URLRequest(url: try XCTUnwrap(URL(string: "https://cdn.example.com/model.gguf")))
        ))
    }

    func testAllParakeetLanguagesAreAvailable() {
        XCTAssertEqual(SpeechLanguage.allCases.count, 25)
        XCTAssertEqual(SpeechLanguage.matching(languageIdentifier: "ru-RU"), .russian)
        XCTAssertEqual(SpeechLanguage.matching(languageIdentifier: "uk_UA"), .ukrainian)
        XCTAssertNil(SpeechLanguage.matching(languageIdentifier: "ja-JP"))
    }

    func testDictationUsesNativePasteForSlackAndBrowsers() {
        let service = TextAccessService()
        XCTAssertTrue(service.shouldPreferClipboardForDictation(bundleID: "com.tinyspeck.slackmacgap"))
        XCTAssertTrue(service.shouldPreferClipboardForDictation(bundleID: "com.google.Chrome"))
        XCTAssertFalse(service.shouldPreferClipboardForDictation(bundleID: "com.apple.Notes"))
    }

    func testGoogleDocsAcceptsPostedDictationPasteWhenAXValueIsStale() {
        XCTAssertTrue(TextAccessService.dictationPasteWasAccepted(
            valueChanged: false,
            caretAdvanced: nil,
            prefersClipboard: true,
            isGoogleDocs: true
        ))
        XCTAssertFalse(TextAccessService.dictationPasteWasAccepted(
            valueChanged: false,
            caretAdvanced: nil,
            prefersClipboard: true,
            isGoogleDocs: false
        ))
        XCTAssertTrue(TextAccessService.dictationPasteWasAccepted(
            valueChanged: nil,
            caretAdvanced: nil,
            prefersClipboard: true,
            isGoogleDocs: false
        ))
    }

    func testBrowserRewritePreservesFormattingWithRichPaste() {
        let service = TextAccessService()
        XCTAssertTrue(service.shouldPreserveBrowserFormattingForRewrite(bundleID: "com.google.Chrome"))
        XCTAssertTrue(service.shouldPreserveBrowserFormattingForRewrite(bundleID: "com.apple.Safari"))
        XCTAssertFalse(service.shouldPreserveBrowserFormattingForRewrite(bundleID: "com.tinyspeck.slackmacgap"))
        XCTAssertFalse(service.shouldPreserveBrowserFormattingForRewrite(bundleID: "com.apple.Notes"))
    }

    func testOfflineSettingsPersistInDefaults() throws {
        let suiteName = "TextoraTests.OfflineDictation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        OfflineDictationSettings.setEnabled(true, defaults: defaults)
        OfflineDictationSettings.setMicrophoneUID("test-microphone", defaults: defaults)

        XCTAssertTrue(OfflineDictationSettings.isEnabled(defaults: defaults))
        XCTAssertEqual(OfflineDictationSettings.microphoneUID(defaults: defaults), "test-microphone")
    }

    @MainActor
    func testDictationHotKeyDefaultsAndPersistsSeparately() throws {
        let suiteName = "TextoraTests.DictationHotKey.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = SelectionAssistantSettings.hotKey(for: .dictate, defaults: defaults)
        XCTAssertEqual(initial.keyCode, 1)
        XCTAssertEqual(initial.modifiers, UInt32(cmdKey | optionKey))
        XCTAssertTrue(initial.isEnabled)

        let changed = TextoraHotKey(keyCode: 2, modifiers: UInt32(controlKey | optionKey), isEnabled: false)
        SelectionAssistantSettings.setHotKey(changed, for: .dictate, defaults: defaults)
        XCTAssertEqual(SelectionAssistantSettings.hotKey(for: .dictate, defaults: defaults), changed)
    }

    func testChecksumVerificationAcceptsExpectedFileAndRejectsCorruption() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextoraTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sample.bin")
        try Data("textora".utf8).write(to: file)

        XCTAssertNoThrow(try SpeechModelManager.verifyFile(
            at: file,
            expectedSize: 7,
            expectedHash: "6ce47b94fbcbecf3d442a9df58946c195a8acd03aff97f225c95c33082645a8d"
        ))
        XCTAssertThrowsError(try SpeechModelManager.verifyFile(
            at: file,
            expectedSize: 7,
            expectedHash: String(repeating: "0", count: 64)
        ))
    }

    func testVerifiedInstallAtomicallyReplacesExistingModel() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextoraInstallTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = directory.appendingPathComponent("model.partial")
        let installed = directory.appendingPathComponent("model.gguf")
        try Data("old".utf8).write(to: installed)
        try Data("textora2".utf8).write(to: staged)

        try SpeechModelManager.installVerifiedFile(
            stagedURL: staged,
            destinationURL: installed,
            expectedSize: 8,
            expectedHash: "fd3f8c15e76922df5b8e22e7bb594a9d5409626ef8c4f8d5861c84d4146aa69c"
        )

        XCTAssertEqual(try Data(contentsOf: installed), Data("textora2".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    func testDictationMicLayoutUsesCaretAndStaysOnScreen() {
        let visible = CGRect(x: 0, y: 0, width: 500, height: 400)
        let frame = DictationMicLayout.frame(
            anchor: CGRect(x: 120, y: 180, width: 2, height: 20),
            fieldFrame: CGRect(x: 80, y: 140, width: 300, height: 100),
            companionFrame: nil,
            visibleFrame: visible
        )

        XCTAssertEqual(frame, CGRect(x: 130, y: 168, width: 44, height: 44))
        XCTAssertTrue(visible.contains(frame))
    }

    func testDictationMicVisibilityPolicyHidesOnlyForDisabledOrHotKeysMode() {
        XCTAssertTrue(DictationMicVisibilityPolicy.shouldRun(
            isEnabled: true,
            accessibilityGranted: true,
            hotKeysOnly: false
        ))
        XCTAssertFalse(DictationMicVisibilityPolicy.shouldRun(
            isEnabled: false,
            accessibilityGranted: true,
            hotKeysOnly: false
        ))
        XCTAssertFalse(DictationMicVisibilityPolicy.shouldRun(
            isEnabled: true,
            accessibilityGranted: false,
            hotKeysOnly: false
        ))
        XCTAssertFalse(DictationMicVisibilityPolicy.shouldRun(
            isEnabled: true,
            accessibilityGranted: true,
            hotKeysOnly: true
        ))
    }

    func testDictationMicExpandsForEveryActiveState() {
        XCTAssertFalse(DictationMicActivityState.idle.isExpanded)
        XCTAssertFalse(DictationMicActivityState.hidden.isExpanded)
        XCTAssertTrue(DictationMicActivityState.preparing.isExpanded)
        XCTAssertTrue(DictationMicActivityState.recording(language: .english).isExpanded)
        XCTAssertTrue(DictationMicActivityState.transcribing.isExpanded)
        XCTAssertTrue(DictationMicActivityState.success.isExpanded)
        XCTAssertTrue(DictationMicActivityState.message("Unavailable", isError: true).isExpanded)
    }

    func testDictationMicLayoutFlipsAtRightEdge() {
        let visible = CGRect(x: 0, y: 0, width: 500, height: 400)
        let frame = DictationMicLayout.frame(
            anchor: CGRect(x: 485, y: 180, width: 2, height: 20),
            fieldFrame: CGRect(x: 80, y: 140, width: 407, height: 100),
            companionFrame: nil,
            visibleFrame: visible
        )

        XCTAssertEqual(frame.minX, 433)
        XCTAssertTrue(visible.contains(frame))
    }

    func testDictationMicLayoutAvoidsFloatingCompanion() {
        let visible = CGRect(x: 0, y: 0, width: 500, height: 400)
        let companion = CGRect(x: 200, y: 170, width: 52, height: 52)
        let frame = DictationMicLayout.frame(
            anchor: companion,
            fieldFrame: CGRect(x: 80, y: 140, width: 320, height: 120),
            companionFrame: companion,
            visibleFrame: visible
        )

        XCTAssertFalse(frame.intersects(companion))
        XCTAssertEqual(frame.minX, companion.maxX + 8)
    }

    func testDraggingExpandedMicPreservesRightAnchoredPosition() {
        let collapsed = DictationMicLayout.collapsedFrame(
            afterDraggingExpandedFrame: CGRect(x: 240, y: 120, width: 332, height: 66),
            collapsedSize: CGSize(width: 84, height: 52),
            visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        XCTAssertEqual(collapsed, CGRect(x: 488, y: 127, width: 84, height: 52))
    }

    func testDraggingExpandedMicAtLeftEdgePreservesLeftAnchor() {
        let collapsed = DictationMicLayout.collapsedFrame(
            afterDraggingExpandedFrame: CGRect(x: 0, y: 120, width: 332, height: 66),
            collapsedSize: CGSize(width: 84, height: 52),
            visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        XCTAssertEqual(collapsed, CGRect(x: 0, y: 127, width: 84, height: 52))
    }

    func testRestoredMicrophoneDockStaysAtDraggedPosition() throws {
        let frame = try XCTUnwrap(DictationMicLayout.clampedDockFrame(
            origin: CGPoint(x: 520, y: 240),
            size: CGSize(width: 84, height: 52),
            visibleFrames: [CGRect(x: 0, y: 0, width: 800, height: 600)]
        ))

        XCTAssertEqual(frame, CGRect(x: 520, y: 240, width: 84, height: 52))
    }

    func testRestoredMicrophoneDockIsClampedAfterDisplayChange() throws {
        let frame = try XCTUnwrap(DictationMicLayout.clampedDockFrame(
            origin: CGPoint(x: 1_545, y: 248),
            size: CGSize(width: 84, height: 52),
            visibleFrames: [CGRect(x: 0, y: 0, width: 1_512, height: 900)]
        ))

        XCTAssertEqual(frame, CGRect(x: 1_428, y: 248, width: 84, height: 52))
    }
}
