import Carbon
import XCTest
@testable import Textora

final class OfflineSpeechTests: XCTestCase {
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
