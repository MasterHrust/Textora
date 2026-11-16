import AppKit
import Carbon
import Network
import WebKit
import XCTest
@testable import Textora

@MainActor
private final class FontTestNavigationDelegate: NSObject, WKNavigationDelegate {
    let loaded: XCTestExpectation
    init(loaded: XCTestExpectation) { self.loaded = loaded }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        XCTFail("Local browser fixture failed: \(error)")
        loaded.fulfill()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        XCTFail("Local browser fixture failed: \(error)")
        loaded.fulfill()
    }
}

final class SecurityAndSettingsTests: XCTestCase {
    func testSummaryShortcutDefaultsAndSavedChoicesSurviveRegistration() throws {
        let suiteName = "TextoraTests.SummaryShortcut.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let suggested = SelectionAssistantSettings.hotKey(for: .summary, defaults: defaults)
        XCTAssertEqual(suggested, TextoraHotKey(keyCode: 1, modifiers: UInt32(controlKey | optionKey | cmdKey), isEnabled: true))
        let custom = TextoraHotKey(keyCode: 32, modifiers: UInt32(cmdKey | shiftKey), isEnabled: false)
        SelectionAssistantSettings.setHotKey(custom, for: .summary, defaults: defaults)
        SelectionAssistantSettings.registerDefaults(defaults: defaults)
        XCTAssertEqual(SelectionAssistantSettings.hotKey(for: .summary, defaults: defaults), custom)
        XCTAssertEqual(TextoraHotKeyAction.rewrite.rawValue, 1)
        XCTAssertEqual(TextoraHotKeyAction.translate.rawValue, 2)
    }

    func testUnseenMainAppLoginItemCanBeRegistered() {
        XCTAssertEqual(LaunchAtLoginManager.state(for: .notFound), .disabled)
    }

    func testCompatibleURLAddsHTTPSAndChatCompletionsPath() {
        let url = AIClient.validatedOpenAICompatibleURL(from: "api.example.com")
        XCTAssertEqual(url?.absoluteString, "https://api.example.com/v1/chat/completions")
    }

    func testCompatibleURLAcceptsLocalHTTPAndRejectsRemoteHTTPAndEmbeddedCredentials() {
        XCTAssertEqual(AIClient.validatedOpenAICompatibleURL(from: "http://localhost:8080")?.absoluteString,
                       "http://localhost:8080/v1/chat/completions")
        XCTAssertNil(AIClient.validatedOpenAICompatibleURL(from: "http://api.example.com"))
        XCTAssertNil(AIClient.validatedOpenAICompatibleURL(from: "https://token@example.com"))
    }

    func testCompatibleModelCatalogUsesConfiguredBasePathAndOptionalToken() throws {
        for (base, expected) in [
            ("http://127.0.0.1:1234", "http://127.0.0.1:1234/v1/models"),
            ("http://localhost:11434/v1/", "http://localhost:11434/v1/models"),
            ("http://[::1]:1234/v1", "http://[::1]:1234/v1/models"),
            ("https://api.example.com/proxy/v1/chat/completions", "https://api.example.com/proxy/v1/models")
        ] {
            let request = try AIClient.compatibleModelsRequest(baseURL: base, apiKey: "")
            XCTAssertEqual(request.url?.absoluteString, expected)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        }
        let authenticated = try AIClient.compatibleModelsRequest(baseURL: "https://api.example.com/v1", apiKey: " token ")
        XCTAssertEqual(authenticated.value(forHTTPHeaderField: "Authorization"), "Bearer token")
        XCTAssertThrowsError(try AIClient.compatibleModelsRequest(baseURL: "http://remote.example.com", apiKey: ""))
    }

    func testCompatibleCatalogKeepsLocalModelIDsAndRejectsMalformedResponses() throws {
        let data = Data(#"{"data":[{"id":"qwen3:8b"},{"id":"llama-local","name":"Llama Local"},{"id":"qwen3:8b"},{"id":" "},{}]}"#.utf8)
        let models = try AIClient.decodeCompatibleModels(data)
        XCTAssertEqual(models.map(\.id), ["llama-local", "qwen3:8b"])
        XCTAssertEqual(models.first?.displayName, "Llama Local")
        XCTAssertEqual(try AIClient.decodeCompatibleModels(Data(#"{"data":[]}"#.utf8)), [])
        XCTAssertThrowsError(try AIClient.decodeCompatibleModels(Data(#"{"error":"unavailable"}"#.utf8)))
    }

    func testLocalHTTPTransportStaysOnTheConfiguredOrigin() throws {
        for base in ["http://localhost:1234", "http://127.0.0.1:1234", "http://[::1]:1234"] {
            let url = try XCTUnwrap(URL(string: base))
            XCTAssertTrue(SecureAITransportPolicy.allows(url))
            let localRequest = URLRequest(url: url.appendingPathComponent("v1/models"))
            XCTAssertNotNil(SecureAITransportPolicy.redirectedRequest(originalURL: url, proposedRequest: localRequest))
            XCTAssertNil(SecureAITransportPolicy.redirectedRequest(originalURL: url,
                proposedRequest: URLRequest(url: try XCTUnwrap(URL(string: "http://remote.example.com/v1/models")))))
        }
        XCTAssertFalse(SecureAITransportPolicy.allows(URL(string: "http://localhost.example.com")))
        XCTAssertFalse(SecureAITransportPolicy.allows(URL(string: "http://192.168.1.2:1234")))
    }

    func testSecureAITransportRejectsHTTPAndCredentialedURLs() throws {
        XCTAssertTrue(SecureAITransportPolicy.allows(URL(string: "https://api.example.com/v1/models")))
        XCTAssertFalse(SecureAITransportPolicy.allows(URL(string: "http://api.example.com/v1/models")))
        XCTAssertFalse(SecureAITransportPolicy.allows(URL(string: "https://token@api.example.com/v1/models")))
    }

    func testSecureAITransportOnlyAllowsSameHostHTTPSRedirects() throws {
        let original = try XCTUnwrap(URL(string: "https://api.example.com/v1/chat/completions"))
        let sameHost = URLRequest(url: try XCTUnwrap(URL(string: "https://api.example.com/v2/chat/completions")))
        let downgraded = URLRequest(url: try XCTUnwrap(URL(string: "http://api.example.com/v2/chat/completions")))
        let otherHost = URLRequest(url: try XCTUnwrap(URL(string: "https://redirect.example.net/v2/chat/completions")))

        XCTAssertNotNil(SecureAITransportPolicy.redirectedRequest(originalURL: original, proposedRequest: sameHost))
        XCTAssertNil(SecureAITransportPolicy.redirectedRequest(originalURL: original, proposedRequest: downgraded))
        XCTAssertNil(SecureAITransportPolicy.redirectedRequest(originalURL: original, proposedRequest: otherHost))
    }

    @MainActor
    func testLocalAndOtherLoadModelsFromUnsavedURLsAndGenerateWithoutTokens() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let listening = expectation(description: "Local compatible server ready")
        listener.stateUpdateHandler = { state in
            if case .ready = state { listening.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            func receiveRequest(_ accumulated: Data) {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                    XCTAssertNil(error)
                    let received = accumulated + (data ?? Data())
                    guard let boundary = received.range(of: Data("\r\n\r\n".utf8)) else {
                        if complete { XCTFail("Incomplete HTTP request"); connection.cancel() }
                        else { receiveRequest(received) }
                        return
                    }
                    let headers = String(decoding: received[..<boundary.lowerBound], as: UTF8.self)
                    let contentLength = headers.components(separatedBy: "\r\n")
                        .first(where: { $0.lowercased().hasPrefix("content-length:") })
                        .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                    guard received.count >= boundary.upperBound + contentLength else {
                        if complete { XCTFail("Incomplete HTTP body"); connection.cancel() }
                        else { receiveRequest(received) }
                        return
                    }
                    let request = String(decoding: received, as: UTF8.self)
                    XCTAssertFalse(headers.lowercased().contains("authorization:"))
                    let body: String
                    if request.hasPrefix("GET /v1/models ") {
                        body = #"{"data":[{"id":"qwen3:8b"},{"id":"llama-local"}]}"#
                    } else {
                        XCTAssertTrue(request.hasPrefix("POST /v1/chat/completions "))
                        if request.contains("Summarize the selected text faithfully") {
                            XCTAssertTrue(request.contains("SOURCE_END"))
                            XCTAssertTrue(request.contains("Russian"))
                            body = #"{"choices":[{"message":{"content":"{\"overview\":\"Обсуждение релиза.\",\"sections\":[]}"}}]}"#
                        } else {
                            body = #"{"choices":[{"message":{"content":"Hello"}}]}"#
                        }
                    }
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            receiveRequest(Data())
        }

        listener.start(queue: .global())
        defer { listener.cancel() }
        await fulfillment(of: [listening], timeout: 3)
        let port = try XCTUnwrap(listener.port)
        let baseURL = "http://127.0.0.1:\(port.rawValue)/v1"
        let defaults = UserDefaults.standard
        let keys = ["provider", "model", AIProvider.other.modelUserDefaultsKey, AIProvider.local.modelUserDefaultsKey,
                    AIClient.openAICompatibleBaseURLUserDefaultsKey, AIClient.localBaseURLUserDefaultsKey]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            for key in keys {
                if let value = previous[key] ?? nil { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        let settings = AppViewModel()
        for provider in [AIProvider.local, .other] {
            settings.provider = provider
            settings.compatibleBaseURL = baseURL
            settings.compatibleToken = ""
            settings.model = ""
            // Let the refresh triggered by changing providers finish first.
            await Task.yield()
            await settings.refreshAvailableModels()
            // A scheduled refresh can supersede the explicit one while it awaits I/O.
            for _ in 0..<100 where settings.isLoadingModels { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(settings.availableModels.map(\.id), ["llama-local", "qwen3:8b"])
            XCTAssertEqual(settings.model, "llama-local")
            XCTAssertTrue(settings.modelCatalogError.isEmpty, settings.modelCatalogError)
            XCTAssertTrue(settings.canLoadModels)
            settings.model = "my-manual-model"
            await settings.refreshAvailableModels()
            XCTAssertEqual(settings.model, "my-manual-model")
            XCTAssertEqual(settings.modelPickerOptions.first?.id, "my-manual-model")

            let baseKey = provider == .local ? AIClient.localBaseURLUserDefaultsKey : AIClient.openAICompatibleBaseURLUserDefaultsKey
            defaults.set(baseURL, forKey: baseKey)
            defaults.set(provider.rawValue, forKey: "provider")
            defaults.set("llama-local", forKey: "model")
            XCTAssertEqual(SelectionAssistantViewModel.providerConfiguration()?.provider, provider)
            let result = try await AIClient().rewriteText(provider: provider, model: "llama-local", apiKey: "", text: "hello", operation: .fixGrammar)
            XCTAssertEqual(result, "Hello")
            let summarySource = String(repeating: "Conversation message. ", count: 500) + "SOURCE_END"
            let summary = try await AIClient().summarize(text: summarySource, options: SummaryOptions(language: .russian))
            XCTAssertEqual(summary.overview, "Обсуждение релиза.")
            settings.compatibleBaseURL = ""
            XCTAssertTrue(settings.availableModels.isEmpty)
            XCTAssertFalse(settings.canLoadModels)
        }
    }

    func testGeminiKeyIsOnlyInHeader() throws {
        let url = try XCTUnwrap(URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000"))
        let request = AIClient.geminiRequest(url: url, apiKey: " secret-key ")

        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "secret-key")
        XCTAssertFalse(try XCTUnwrap(request.url?.absoluteString).contains("secret-key"))
        XCTAssertNil(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { ["key", "api_key", "token"].contains($0.name.lowercased()) }))
    }

    @MainActor
    func testLocalAndHTTPSOtherSettingsPersistIndependently() throws {
        let defaults = UserDefaults.standard
        let keys = ["provider", "model", AIProvider.local.modelUserDefaultsKey, AIProvider.other.modelUserDefaultsKey,
                    AIClient.localBaseURLUserDefaultsKey, AIClient.openAICompatibleBaseURLUserDefaultsKey]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            for key in keys {
                if let value = previous[key] ?? nil { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set("local", forKey: "provider")
        defaults.set("qwen3:8b", forKey: AIProvider.local.modelUserDefaultsKey)
        defaults.set("remote-model", forKey: AIProvider.other.modelUserDefaultsKey)
        defaults.set("http://localhost:1234/v1", forKey: AIClient.localBaseURLUserDefaultsKey)
        defaults.set("https://api.example.com/v1", forKey: AIClient.openAICompatibleBaseURLUserDefaultsKey)
        let settings = AppViewModel()
        XCTAssertEqual(settings.provider, .local)
        XCTAssertEqual(settings.model, "qwen3:8b")
        XCTAssertEqual(settings.compatibleBaseURL, "http://localhost:1234/v1")
        settings.compatibleBaseURL = "http://localhost:11434/v1"
        XCTAssertTrue(settings.saveSettings())

        defaults.set("other", forKey: "provider")
        settings.reloadFromUserDefaults()
        XCTAssertEqual(settings.provider, .other)
        XCTAssertEqual(settings.model, "remote-model")
        XCTAssertEqual(settings.compatibleBaseURL, "https://api.example.com/v1")
        XCTAssertTrue(settings.canLoadModels)
        let request = try AIClient.compatibleModelsRequest(baseURL: settings.compatibleBaseURL, apiKey: "other-token")
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer other-token")

        defaults.set("local", forKey: "provider")
        let reopened = AppViewModel()
        XCTAssertEqual(reopened.model, "qwen3:8b")
        XCTAssertEqual(reopened.compatibleBaseURL, "http://localhost:11434/v1")
    }

    func testRemovedDiagnosticHookDoesNotEvaluatePayload() {
        var didEvaluatePayload = false

        textoraDiagLog("test", {
            didEvaluatePayload = true
            return "private selected text 123"
        }())

        XCTAssertFalse(didEvaluatePayload)
    }

    @MainActor
    func testHotKeyPanelGrowsForLongTextAndStopsAtReadableMaximum() {
        let shortHeight = SelectionToolbarView.hotKeyPanelHeight(
            originalText: "Short source",
            resultText: "Short result"
        )
        let longText = Array(repeating: "A substantially longer sentence for the adaptive preview.", count: 80)
            .joined(separator: " ")
        let longHeight = SelectionToolbarView.hotKeyPanelHeight(
            originalText: longText,
            resultText: longText
        )

        XCTAssertEqual(shortHeight, 268)
        XCTAssertGreaterThan(longHeight, shortHeight)
        XCTAssertLessThanOrEqual(longHeight, 511)
    }

    func testHotKeyResultUsesSameBodyFontSizeAsOriginal() {
        XCTAssertEqual(SelectionToolbarView.hotKeyBodyFontSize, 13.5)
    }

    @MainActor
    func testObjectPasteboardTypesAreRejected() {
        XCTAssertFalse(TextAccessService.containsObjectPasteboardType([
            NSPasteboard.PasteboardType.string.rawValue,
            NSPasteboard.PasteboardType.html.rawValue
        ]))
        XCTAssertTrue(TextAccessService.containsObjectPasteboardType([
            NSPasteboard.PasteboardType.string.rawValue,
            "public.png"
        ]))
        XCTAssertTrue(TextAccessService.containsObjectPasteboardType(["com.adobe.pdf"] ))
        XCTAssertTrue(TextAccessService.containsObjectPasteboardType(["public.file-url"] ))
    }

    @MainActor
    func testRewrittenTextKeepsFormattingOfChangedAndUnchangedRuns() throws {
        let source = NSMutableAttributedString(string: "Plain bad link")
        let emphasis = NSAttributedString.Key("TextoraTestEmphasis")
        source.addAttribute(emphasis, value: true, range: (source.string as NSString).range(of: "bad"))
        let linkRange = (source.string as NSString).range(of: "link")
        source.addAttribute(.link, value: try XCTUnwrap(URL(string: "https://textora.app")), range: linkRange)

        let rewritten = TextAccessService.attributedReplacementPreservingFormatting(
            source: source,
            rewritten: "Plain good link!"
        )

        XCTAssertEqual(rewritten.string, "Plain good link!")
        let goodRange = (rewritten.string as NSString).range(of: "good")
        XCTAssertEqual(rewritten.attribute(emphasis, at: goodRange.location, effectiveRange: nil) as? Bool, true)
        let rewrittenLinkRange = (rewritten.string as NSString).range(of: "link")
        XCTAssertNotNil(rewritten.attribute(.link, at: rewrittenLinkRange.location, effectiveRange: nil))
        XCTAssertNil(rewritten.attribute(.link, at: rewritten.length - 1, effectiveRange: nil))
    }

    @MainActor
    func testInsertedTextInsideFormattedRunInheritsThatFormatting() {
        let source = NSMutableAttributedString(string: "helo")
        let emphasis = NSAttributedString.Key("TextoraTestEmphasis")
        source.addAttribute(emphasis, value: true, range: NSRange(location: 0, length: source.length))

        let rewritten = TextAccessService.attributedReplacementPreservingFormatting(
            source: source,
            rewritten: "hello"
        )

        XCTAssertEqual(rewritten.string, "hello")
        XCTAssertEqual(rewritten.attribute(emphasis, at: 3, effectiveRange: nil) as? Bool, true)
    }

    @MainActor
    func testBrowserPasteKeepsCSSFontSizeAcrossRepeatedCorrections() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let service = TextAccessService()
        let original = "We can also schedule a call with the cc'd people. Thank you"
        let corrected = "We can also schedule a call with the people copied on this email. Thank you."
        // A browser can offer the same selection as CSS pixels and rounded RTF
        // points. Choosing RTF then exporting HTML used to shrink this to 10px.
        let html = "<span style=\"font-family:Arial;font-size:13px\">\(original)</span>"
        let native = NSAttributedString(string: original, attributes: [
            .font: try XCTUnwrap(NSFont(name: "Arial", size: 10))
        ])
        let item = NSPasteboardItem()
        item.setString(original, forType: .string)
        item.setData(Data(html.utf8), forType: .html)
        item.setData(try native.data(from: NSRange(location: 0, length: native.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]), forType: .rtf)
        XCTAssertTrue(pasteboard.writeObjects([item]))

        var current = original
        for replacement in [corrected, original, corrected] {
            let captured = await readRichText(pasteboard, matching: current)
            let source = try XCTUnwrap(captured)
            XCTAssertTrue(service.writeReplacementToPasteboard(replacement, preserving: source, pasteboard: pasteboard))
            XCTAssertEqual(pasteboard.string(forType: .string), replacement)
            let exported = try XCTUnwrap(pasteboard.data(forType: .html))
            let decoded = try NSAttributedString(data: exported, options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ], documentAttributes: nil)
            XCTAssertEqual(decoded.string.trimmingCharacters(in: .whitespacesAndNewlines), replacement)
            decoded.enumerateAttribute(.font, in: NSRange(location: 0, length: (replacement as NSString).length)) { font, _, _ in
                XCTAssertEqual((font as? NSFont)?.pointSize ?? 0, 13, accuracy: 0.01)
                XCTAssertEqual((font as? NSFont)?.familyName, "Arial")
            }
            XCTAssertNil(pasteboard.data(forType: .rtf), "Do not offer a second rich format with different size units")
            current = replacement
        }
    }

    @MainActor
    func testGmailSmallAndRelativeSizesMatchBrowserAfterRepeatedCorrections() async throws {
        let cases: [(String, String, Double)] = [
            ("Gmail small", "<div style='font-family:Arial;font-size:small'>Original text</div>", 13),
            ("Legacy font tag", "<font face='Arial' size='2'>Original text</font>", 13),
            ("Medium", "<div style='font-size:medium'>Original text</div>", 16),
            ("Unstyled", "<div>Original text</div>", 16),
            ("Relative em", "<div style='font-size:1em'>Original text</div>", 16),
            ("Relative percent", "<div style='font-size:100%'>Original text</div>", 16),
            ("Nested relative", "<div style='font-size:20px'><span style='font-size:75%'>Original text</span></div>", 15),
            ("Explicit px", "<div style='font-size:13px'>Original text</div>", 13),
            ("Explicit pt", "<div style='font-size:12pt'>Original text</div>", 16)
        ]
        let service = TextAccessService()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for (name, html, expected) in cases {
            let before = try await browserFontSizes(html)
            XCTAssertFalse(before.isEmpty, name)
            XCTAssertTrue(before.allSatisfy { abs($0 - expected) < 0.05 }, "\(name): \(before)")
            pasteboard.clearContents()
            pasteboard.setString(html, forType: .html)
            var current = "Original text"
            for replacement in ["Corrected text", "Original text", "Corrected text"] {
                let captured = await readRichText(pasteboard, matching: current)
                let source = try XCTUnwrap(captured)
                XCTAssertTrue(service.writeReplacementToPasteboard(replacement, preserving: source, pasteboard: pasteboard))
                let exported = try XCTUnwrap(pasteboard.string(forType: .html))
                let after = try await browserFontSizes(exported, insertingIntoEditor: true)
                XCTAssertFalse(after.isEmpty, name)
                XCTAssertTrue(after.allSatisfy { abs($0 - expected) < 0.05 }, "\(name): before=\(before), after=\(after)")
                current = replacement
            }
        }
    }

    private func readRichText(_ pasteboard: NSPasteboard, matching text: String) async -> TextAccessService.RichTextSelection? {
        // Production imports on SelectionTextWorker while WebKit runs on main.
        await Task.detached { TextAccessService().richTextFromPasteboard(pasteboard, matching: text) }.value
    }

    @MainActor
    private func browserFontSizes(_ html: String, insertingIntoEditor: Bool = false) async throws -> [Double] {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let browser = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 200), configuration: configuration)
        let loaded = expectation(description: "Local HTML loaded")
        let delegate = FontTestNavigationDelegate(loaded: loaded)
        browser.navigationDelegate = delegate
        browser.loadHTMLString(insertingIntoEditor
            ? "<div contenteditable='true' id='editor'>Selected text</div>" : html, baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)
        if insertingIntoEditor {
            let inserted = try await browser.callAsyncJavaScript("""
                const editor = document.getElementById('editor');
                editor.focus();
                const range = document.createRange();
                range.selectNodeContents(editor);
                const selection = getSelection();
                selection.removeAllRanges();
                selection.addRange(range);
                return document.execCommand('insertHTML', false, html);
                """, arguments: ["html": html], in: nil, contentWorld: .page)
            XCTAssertEqual(inserted as? Bool, true)
        }
        // Compare actual CSS sizes in a browser engine, not another AppKit
        // decode, which would reproduce the same incorrect default settings.
        let sizes = try await browser.evaluateJavaScript("""
            (() => {
                const walker = document.createTreeWalker(document.getElementById('editor') || document.body, NodeFilter.SHOW_TEXT);
                const sizes = [];
                while (walker.nextNode()) {
                    const node = walker.currentNode;
                    if (node.parentElement.closest('style,script')) continue;
                    if (node.textContent.trim()) sizes.push(parseFloat(getComputedStyle(node.parentElement).fontSize));
                }
                return sizes;
            })()
            """)
        return try XCTUnwrap(sizes as? [Double])
    }

    @MainActor
    func testHTMLPasteRetainsMixedFontSizesEmphasisAndLinks() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let service = TextAccessService()
        let html = "<span style=\"font-family:Arial;font-size:13px\">Plain </span><b style=\"font-family:Georgia;font-size:24px\">bad</b><span style=\"font-size:13px\"> <a href=\"https://textora.app\"><u>link</u></a></span>"
        pasteboard.setData(Data(html.utf8), forType: .html)
        let captured = await readRichText(pasteboard, matching: "Plain bad link")
        let source = try XCTUnwrap(captured)
        XCTAssertTrue(service.writeReplacementToPasteboard("Plain good link", preserving: source, pasteboard: pasteboard))
        let pastedSizes = try await browserFontSizes(try XCTUnwrap(pasteboard.string(forType: .html)), insertingIntoEditor: true)
        XCTAssertTrue(pastedSizes.contains(13))
        XCTAssertTrue(pastedSizes.contains(24))
        XCTAssertTrue(pastedSizes.allSatisfy { $0 == 13 || $0 == 24 }, "Mixed sizes after paste: \(pastedSizes)")
        let recaptured = await readRichText(pasteboard, matching: "Plain good link")
        let after = try XCTUnwrap(recaptured).text
        let small = try XCTUnwrap(after.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let large = try XCTUnwrap(after.attribute(.font, at: 6, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(small.pointSize, 13, accuracy: 0.01)
        XCTAssertEqual(large.pointSize, 24, accuracy: 0.01)
        XCTAssertEqual(large.familyName, "Georgia")
        XCTAssertTrue(NSFontManager.shared.traits(of: large).contains(.boldFontMask))
        let linkIndex = (after.string as NSString).range(of: "link").location
        XCTAssertEqual(after.attribute(.link, at: linkIndex, effectiveRange: nil) as? URL,
            source.text.attribute(.link, at: (source.text.string as NSString).range(of: "link").location, effectiveRange: nil) as? URL)
        XCTAssertNotNil(after.attribute(.underlineStyle, at: linkIndex, effectiveRange: nil))
    }

    @MainActor
    func testFontFamiliesAndInheritedEditorStylesSurviveRepeatedHTMLRewrites() async throws {
        let cases = [
            "<div>Original text</div>",
            "<span style='font-family:sans-serif;font-size:13px'>Original text</span>",
            "<span style='font-family:Arial,Helvetica,sans-serif;font-size:small'>Original text</span>",
            "<font face='arial, sans-serif' size='2'>Original text</font>",
            "<span style='font-family:serif'>Original text</span>",
            "<span style='font-family:Georgia,serif'>Original text</span>",
            "<span style='font-family:monospace'>Original text</span>",
            "<div style='font-family:Helvetica;font-size:15px'><span>Original text</span></div>",
            "<style>.copy {font-family: Arial, sans-serif; font-size:13px; color:rgb(34,85,136)}</style><div class='copy'>Original text</div>"
        ]
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for html in cases {
            let before = try await browserStylesAfterPaste(html, insert: false)
            XCTAssertFalse(before.isEmpty)
            pasteboard.clearContents()
            pasteboard.setString(html, forType: .html)
            var current = "Original text"
            for replacement in ["Corrected text", "Исправленный текст 🙂", "Original text"] {
                let captured = await readRichText(pasteboard, matching: current)
                let source = try XCTUnwrap(captured, html)
                let prepared = TextAccessService().writeReplacementToPasteboard(replacement, preserving: source, pasteboard: pasteboard)
                _ = try XCTUnwrap(prepared ? true : nil, "\(html); source=\(source.text.string.debugDescription); normalized=\(String(decoding: source.html ?? Data(), as: UTF8.self))")
                let exported = try XCTUnwrap(pasteboard.string(forType: .html))
                let after = try await browserStylesAfterPaste(exported)
                XCTAssertEqual(after.map { $0["family"] }, before.map { $0["family"] }, html + " → " + exported)
                XCTAssertEqual(after.map { $0["size"] }, before.map { $0["size"] }, html)
                XCTAssertEqual(after.map { $0["color"] }, before.map { $0["color"] }, html)
                XCTAssertEqual(after.compactMap { $0["text"] }.joined(), replacement)
                current = replacement
            }
        }
    }

    @MainActor
    func testHTMLRetainsListsParagraphsColorsEmphasisAndLinkTargets() async throws {
        let html = "<div style='font-family:Arial,sans-serif;font-size:15px;color:rgb(34,85,136);text-align:right'><p>Plain <b><i>bad</i></b></p><ul><li><u>Second</u></li><li><a href='https://example.com/path?q=1'>link</a></li></ul></div>"
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(html, forType: .html)
        // Obtain AppKit's list/paragraph serialization, including bullet markers.
        let source = await Task.detached { () -> TextAccessService.RichTextSelection? in
            // Matching uses the actual plain selection supplied by the browser.
            let imported = try? NSAttributedString(data: Data(html.utf8), options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil)
            guard let imported else { return nil }
            return TextAccessService().richTextFromPasteboard(pasteboard, matching: imported.string)
        }.value
        let captured = try XCTUnwrap(source)
        let replacement = captured.text.string.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "bad", with: "good")
        let prepared = TextAccessService().writeReplacementToPasteboard(replacement, preserving: captured, pasteboard: pasteboard)
        _ = try XCTUnwrap(prepared ? true : nil, "List and paragraph formatting must survive a local word correction: \(captured.text.string.debugDescription)")
        let exported = try XCTUnwrap(pasteboard.string(forType: .html))
        XCTAssertTrue(exported.contains("<ul"))
        XCTAssertTrue(exported.contains("<li"))
        XCTAssertTrue(exported.contains("<p"))
        let before = try await browserStylesAfterPaste(html)
        let after = try await browserStylesAfterPaste(exported)
        XCTAssertEqual(before.count, after.count)
        for (old, new) in zip(before, after) {
            for property in ["family", "size", "color", "weight", "italic", "align", "href", "decoration"] {
                XCTAssertEqual(old[property], new[property], property)
            }
        }
        XCTAssertTrue(after.contains { $0["text"]?.contains("good") == true })
    }

    @MainActor
    func testStructuralChangesAndEmbeddedObjectsRequireManualPaste() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for (html, original, replacement) in [
            ("<div>Original text</div>", "Original text", "Original\ntext"),
            ("<div>First</div><div>Second</div>", "First\nSecond", "First Second"),
            ("<div>First</div><div>Second</div>", "First\nSecond", "First Second\n"),
            ("<a href='https://example.com'>link</a>", "link", "link!")
        ] {
            pasteboard.clearContents()
            pasteboard.setString(html, forType: .html)
            let captured = await readRichText(pasteboard, matching: original)
            let source = try XCTUnwrap(captured)
            let changeCount = pasteboard.changeCount
            XCTAssertFalse(TextAccessService().writeReplacementToPasteboard(replacement, preserving: source, pasteboard: pasteboard), html)
            XCTAssertEqual(pasteboard.changeCount, changeCount)
        }
        pasteboard.clearContents()
        pasteboard.setString("<div>Original<img src='https://example.invalid/image.png'></div>", forType: .html)
        let captured = await readRichText(pasteboard, matching: "Original")
        XCTAssertNil(captured)
        XCTAssertFalse(TextAccessService().writeReplacementToPasteboard("Corrected", preserving: captured, pasteboard: pasteboard))
    }

    @MainActor
    func testNativeRichAttachmentsAreNotDiscardedByTextReplacement() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Existing clipboard", forType: .string)
        let original = NSMutableAttributedString(string: "Original ")
        original.append(NSAttributedString(attachment: NSTextAttachment()))
        let source = TextAccessService.RichTextSelection(text: original, pasteboardType: .rtf, documentType: .rtf)
        let changeCount = pasteboard.changeCount
        XCTAssertFalse(TextAccessService().writeReplacementToPasteboard("Corrected", preserving: source, pasteboard: pasteboard))
        XCTAssertEqual(pasteboard.changeCount, changeCount)
    }

    @MainActor
    func testUnreadableRichClipboardIsNeverSilentlyPastedAsPlainText() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for type in [NSPasteboard.PasteboardType.html, .rtf] {
            pasteboard.clearContents()
            pasteboard.setString("Original", forType: .string)
            pasteboard.setData(Data("unsupported rich content".utf8), forType: type)
            let changeCount = pasteboard.changeCount
            XCTAssertFalse(TextAccessService().writeReplacementToPasteboard("Corrected", preserving: nil, pasteboard: pasteboard))
            XCTAssertEqual(pasteboard.changeCount, changeCount)
            XCTAssertEqual(pasteboard.string(forType: .string), "Original")
        }
    }

    @MainActor
    private func browserStylesAfterPaste(_ html: String, insert: Bool = true) async throws -> [[String: String]] {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let browser = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 200), configuration: configuration)
        let loaded = expectation(description: "Formatting fixture loaded")
        let delegate = FontTestNavigationDelegate(loaded: loaded)
        browser.navigationDelegate = delegate
        browser.loadHTMLString("<div contenteditable='true' id='editor' style='font-family:Arial,sans-serif;font-size:16px;color:rgb(20,30,40)'>\(insert ? "Selected text" : html)</div>", baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)
        let result = try await browser.callAsyncJavaScript("""
            const editor = document.getElementById('editor');
            editor.focus();
            const range = document.createRange(); range.selectNodeContents(editor);
            const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range);
            if (insert && !document.execCommand('insertHTML', false, html)) throw new Error('Insertion failed');
            const walker = document.createTreeWalker(editor, NodeFilter.SHOW_TEXT);
            const result = [];
            while (walker.nextNode()) {
                const node = walker.currentNode;
                if (!node.textContent.trim() || node.parentElement.closest('style,script')) continue;
                const element = node.parentElement, style = getComputedStyle(element);
                result.push({text:node.textContent, family:style.fontFamily, size:style.fontSize,
                    color:style.color, weight:style.fontWeight, italic:style.fontStyle,
                    align:style.textAlign, decoration:style.textDecorationLine,
                    href:element.closest('a')?.getAttribute('href') || ''});
            }
            return result;
            """, arguments: ["html": html, "insert": insert], in: nil, contentWorld: .page)
        return try XCTUnwrap(result as? [[String: String]])
    }

    @MainActor
    func testRTFOnlyPasteRetainsPointSizesWithoutSynthesizingHTML() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let service = TextAccessService()
        let original = NSMutableAttributedString(string: "Plain bad", attributes: [
            .font: try XCTUnwrap(NSFont(name: "Arial", size: 10))
        ])
        original.addAttribute(.font, value: try XCTUnwrap(NSFont(name: "Georgia-Bold", size: 18.5)),
            range: NSRange(location: 6, length: 3))
        pasteboard.setData(try original.data(from: NSRange(location: 0, length: original.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]), forType: .rtf)
        // An unrelated HTML representation must not override the valid RTF.
        pasteboard.setString("<span style='font-size:8px'>Other text</span>", forType: .html)
        let captured = await readRichText(pasteboard, matching: original.string)
        let source = try XCTUnwrap(captured)
        XCTAssertTrue(service.writeReplacementToPasteboard("Plain good", preserving: source, pasteboard: pasteboard))
        XCTAssertNil(pasteboard.data(forType: .html))
        let after = try XCTUnwrap(NSAttributedString(rtf: try XCTUnwrap(pasteboard.data(forType: .rtf)), documentAttributes: nil))
        XCTAssertEqual(after.string, "Plain good")
        XCTAssertEqual((after.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? 0, 10, accuracy: 0.01)
        XCTAssertEqual((after.attribute(.font, at: 6, effectiveRange: nil) as? NSFont)?.pointSize ?? 0, 18.5, accuracy: 0.01)
    }

    @MainActor
    func testPlainTextPasteDoesNotInventFontFormatting() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let service = TextAccessService()
        pasteboard.setString("Original", forType: .string)
        let source = await readRichText(pasteboard, matching: "Original")
        XCTAssertNil(source)
        XCTAssertTrue(service.writeReplacementToPasteboard("Corrected", preserving: source, pasteboard: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "Corrected")
        XCTAssertNil(pasteboard.data(forType: .html))
        XCTAssertNil(pasteboard.data(forType: .rtf))
    }

    @MainActor
    func testSavedOptionCommandXSurvivesUpgrade() throws {
        let suiteName = "TextoraTests.HotKeyMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(7, forKey: SelectionAssistantSettings.Keys.rewriteHotKeyCode)
        defaults.set(UInt32(cmdKey | optionKey), forKey: SelectionAssistantSettings.Keys.rewriteHotKeyModifiers)
        defaults.set(true, forKey: SelectionAssistantSettings.Keys.rewriteHotKeyEnabled)

        SelectionAssistantSettings.registerDefaults(defaults: defaults)

        let hotKey = SelectionAssistantSettings.hotKey(for: .rewrite, defaults: defaults)
        XCTAssertEqual(hotKey.keyCode, 7)
        XCTAssertEqual(hotKey.modifiers, UInt32(cmdKey | optionKey))
    }

    @MainActor
    func testFreshInstallUsesSuggestedRewriteAndTranslateHotKeys() throws {
        let suiteName = "TextoraTests.HotKeyDefaults.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        SelectionAssistantSettings.registerDefaults(defaults: defaults)

        let rewrite = SelectionAssistantSettings.hotKey(for: .rewrite, defaults: defaults)
        let translate = SelectionAssistantSettings.hotKey(for: .translate, defaults: defaults)
        XCTAssertEqual(rewrite, TextoraHotKey(
            keyCode: 15,
            modifiers: UInt32(cmdKey | optionKey),
            isEnabled: true
        ))
        XCTAssertEqual(translate, TextoraHotKey(
            keyCode: 17,
            modifiers: UInt32(cmdKey | optionKey),
            isEnabled: true
        ))
        XCTAssertFalse(SelectionAssistantSettings.hotKeysModeEnabled(defaults: defaults))
    }

    @MainActor
    func testLegacyHotKeyOnlyModeMigratesToHotKeysInterface() throws {
        let suiteName = "TextoraTests.HotKeyModeMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(SelectionActivationMode.hotkeyOnly.rawValue, forKey: SelectionAssistantSettings.Keys.activationMode)

        SelectionAssistantSettings.registerDefaults(defaults: defaults)

        XCTAssertTrue(SelectionAssistantSettings.hotKeysModeEnabled(defaults: defaults))
    }

    @MainActor
    func testExplicitHotKeysModeSurvivesSettingsRegistration() throws {
        let suiteName = "TextoraTests.HotKeyModePersistence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: SelectionAssistantSettings.Keys.toolboxEnabled)
        defaults.set(true, forKey: SelectionAssistantSettings.Keys.hotKeysModeEnabled)

        SelectionAssistantSettings.registerDefaults(defaults: defaults)

        XCTAssertTrue(SelectionAssistantSettings.hotKeysModeEnabled(defaults: defaults))
    }

    @MainActor
    func testLegacyToolboxAndFloatingCombinationNormalizesToToolbox() throws {
        let suiteName = "TextoraTests.InterfaceModeNormalization.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: SelectionAssistantSettings.Keys.toolboxEnabled)
        defaults.set(true, forKey: SelectionAssistantSettings.Keys.floatingIconEnabled)
        defaults.removeObject(forKey: SelectionAssistantSettings.Keys.interfaceModeMigration)

        SelectionAssistantSettings.registerDefaults(defaults: defaults)

        XCTAssertTrue(defaults.bool(forKey: SelectionAssistantSettings.Keys.toolboxEnabled))
        XCTAssertFalse(defaults.bool(forKey: SelectionAssistantSettings.Keys.floatingIconEnabled))
        XCTAssertFalse(defaults.bool(forKey: SelectionAssistantSettings.Keys.hotKeysModeEnabled))
    }

    @MainActor
    func testExclusiveInterfaceSelectionRejectsCombinations() throws {
        let suiteName = "TextoraTests.ExclusiveInterfaceMode.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        SelectionAssistantSettings.setInterfaceModes(
            toolbox: false,
            hotKeys: true,
            defaults: defaults
        )

        XCTAssertFalse(defaults.bool(forKey: SelectionAssistantSettings.Keys.toolboxEnabled))
        XCTAssertFalse(defaults.bool(forKey: SelectionAssistantSettings.Keys.floatingIconEnabled))
        XCTAssertTrue(defaults.bool(forKey: SelectionAssistantSettings.Keys.hotKeysModeEnabled))
    }

    @MainActor
    func testAtLeastOneInterfaceModeRemainsEnabled() throws {
        let suiteName = "TextoraTests.InterfaceModeFallback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: SelectionAssistantSettings.Keys.toolboxEnabled)
        defaults.set(false, forKey: SelectionAssistantSettings.Keys.floatingIconEnabled)
        defaults.set(false, forKey: SelectionAssistantSettings.Keys.hotKeysModeEnabled)
        defaults.removeObject(forKey: SelectionAssistantSettings.Keys.interfaceModeMigration)

        SelectionAssistantSettings.registerDefaults(defaults: defaults)

        XCTAssertTrue(defaults.bool(forKey: SelectionAssistantSettings.Keys.toolboxEnabled))
    }

    @MainActor
    func testSavedControlCommandXSurvivesUpgrade() throws {
        let suiteName = "TextoraTests.HotKeyMigrationV2.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(7, forKey: SelectionAssistantSettings.Keys.rewriteHotKeyCode)
        defaults.set(UInt32(cmdKey | controlKey), forKey: SelectionAssistantSettings.Keys.rewriteHotKeyModifiers)
        defaults.set(true, forKey: SelectionAssistantSettings.Keys.rewriteHotKeyDefaultRMigration)

        SelectionAssistantSettings.registerDefaults(defaults: defaults)

        let hotKey = SelectionAssistantSettings.hotKey(for: .rewrite, defaults: defaults)
        XCTAssertEqual(hotKey.keyCode, 7)
        XCTAssertEqual(hotKey.modifiers, UInt32(cmdKey | controlKey))
    }

    @MainActor
    func testCustomRewriteHotKeyIsNotChangedByDefaultMigration() throws {
        let suiteName = "TextoraTests.HotKeyCustom.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(8, forKey: SelectionAssistantSettings.Keys.rewriteHotKeyCode)
        defaults.set(UInt32(cmdKey | controlKey), forKey: SelectionAssistantSettings.Keys.rewriteHotKeyModifiers)

        SelectionAssistantSettings.registerDefaults(defaults: defaults)

        let hotKey = SelectionAssistantSettings.hotKey(for: .rewrite, defaults: defaults)
        XCTAssertEqual(hotKey.keyCode, 8)
        XCTAssertEqual(hotKey.modifiers, UInt32(cmdKey | controlKey))
    }

    func testUpgradePreservesChoicesAcrossRepeatedLaunches() throws {
        let keys = SelectionAssistantSettings.Keys.self
        for hotKeys in [true, false] {
            let suite = "TextoraTests.Upgrade.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let saved: [String: Any] = [
                keys.toolboxEnabled: !hotKeys, keys.hotKeysModeEnabled: hotKeys,
                keys.enabled: false, keys.operation: RewriteOperation.humanize.rawValue,
                keys.translationLanguage: "russian", keys.rewriteHotKeyCode: 7,
                keys.rewriteHotKeyModifiers: UInt32(cmdKey | controlKey), keys.rewriteHotKeyEnabled: false,
                keys.translateHotKeyCode: 8, keys.translateHotKeyEnabled: false,
                keys.dictateHotKeyCode: 9, keys.dictateHotKeyEnabled: false,
                "provider": "other", "model": "user-model", "overlay.smartAI.enabled": false,
                "offlineDictation.enabled": true, "offlineDictation.microphoneUID": "user-microphone"
            ]
            saved.forEach { defaults.set($0.value, forKey: $0.key) }
            for _ in 0..<3 {
                let relaunched = try XCTUnwrap(UserDefaults(suiteName: suite))
                SelectionAssistantSettings.registerDefaults(defaults: relaunched)
                OfflineDictationSettings.registerDefaults(relaunched)
                for (key, expected) in saved {
                    XCTAssertEqual(relaunched.object(forKey: key) as? NSObject, expected as? NSObject, key)
                }
            }
        }
    }

    func testSavedHotKeysWithoutToolboxKeyWinsOverNewDefault() throws {
        let suite = "TextoraTests.PartialUpgrade.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: SelectionAssistantSettings.Keys.hotKeysModeEnabled)
        SelectionAssistantSettings.registerDefaults(defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: SelectionAssistantSettings.Keys.hotKeysModeEnabled))
        XCTAssertFalse(defaults.bool(forKey: SelectionAssistantSettings.Keys.toolboxEnabled))
    }

    func testExplicitToolboxWinsOverStaleLegacyActivation() throws {
        let suite = "TextoraTests.ExplicitMode.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: SelectionAssistantSettings.Keys.toolboxEnabled)
        defaults.set(false, forKey: SelectionAssistantSettings.Keys.hotKeysModeEnabled)
        defaults.set("hotkeyOnly", forKey: SelectionAssistantSettings.Keys.activationMode)
        SelectionAssistantSettings.registerDefaults(defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: SelectionAssistantSettings.Keys.toolboxEnabled))
        XCTAssertFalse(defaults.bool(forKey: SelectionAssistantSettings.Keys.hotKeysModeEnabled))
    }

    func testLegacyTranslationLanguageMigratesWithoutOverwritingCurrentChoice() throws {
        for current in [nil, "greek"] as [String?] {
            let suite = "TextoraTests.LanguageUpgrade.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set("Russian", forKey: "inlineTranslate.lastTargetLanguage")
            if let current { defaults.set(current, forKey: SelectionAssistantSettings.Keys.translationLanguage) }
            SelectionAssistantSettings.registerDefaults(defaults: defaults)
            XCTAssertEqual(SelectionAssistantSettings.translationLanguage(defaults: defaults).rawValue, current ?? "russian")
        }
    }

    @MainActor
    func testSavedModelsIncludingPreviousDefaultsSurviveReload() {
        let defaults = UserDefaults.standard
        let keys = ["provider", "model"] + AIProvider.allCases.map(\.modelUserDefaultsKey)
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            for key in keys {
                if let value = previous[key] ?? nil { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        let choices: [(AIProvider, String)] = [(.openai, AIClient.Defaults.openAIModel),
            (.gemini, "gemini-1.5-pro"), (.claude, "claude-3-5-sonnet-latest"),
            (.other, "custom-https-model"), (.local, "my-local-model")]
        for (provider, model) in choices {
            for legacyOnly in [true, false] {
                defaults.set(provider.rawValue, forKey: "provider")
                defaults.set(model, forKey: "model")
                if legacyOnly { defaults.removeObject(forKey: provider.modelUserDefaultsKey) }
                else { defaults.set(model, forKey: provider.modelUserDefaultsKey) }
                let settings = AppViewModel()
                XCTAssertEqual(settings.model, model)
                settings.reloadFromUserDefaults()
                XCTAssertEqual(settings.model, model)
                XCTAssertEqual(defaults.string(forKey: provider.modelUserDefaultsKey), model)
            }
        }
    }

    @MainActor
    func testStaleSettingsWindowCannotOverwriteNewerChoicesOnSaveOrExit() {
        let defaults = UserDefaults.standard
        let keys = ["model", "provider", SelectionAssistantSettings.Keys.operation,
                    SelectionAssistantSettings.Keys.translationLanguage,
                    SelectionAssistantSettings.Keys.toolboxEnabled,
                    SelectionAssistantSettings.Keys.hotKeysModeEnabled]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            for key in keys {
                if let value = previous[key] ?? nil { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        let stale = AppViewModel()
        defaults.set("newer-model", forKey: "model")
        defaults.set("other", forKey: "provider")
        defaults.set("russian", forKey: SelectionAssistantSettings.Keys.translationLanguage)
        defaults.set(RewriteOperation.humanize.rawValue, forKey: SelectionAssistantSettings.Keys.operation)
        defaults.set(false, forKey: SelectionAssistantSettings.Keys.toolboxEnabled)
        defaults.set(true, forKey: SelectionAssistantSettings.Keys.hotKeysModeEnabled)
        let newer = defaults.dictionaryRepresentation()
        XCTAssertTrue(stale.saveSettings())
        stale.flushPendingSave()
        for key in keys { XCTAssertEqual(defaults.object(forKey: key) as? NSObject, newer[key] as? NSObject, key) }
    }

    @MainActor
    func testSelectionSettingsPersistAcrossViewModels() {
        let defaults = UserDefaults.standard
        let keys = SelectionAssistantSettings.Keys.self
        let modifiedKeys = [
            keys.translationLanguage,
            keys.operation,
            keys.activationMode,
            keys.toolboxEnabled,
            keys.floatingIconEnabled,
            keys.hotKeysModeEnabled,
            keys.hotKeysModeMigration,
            keys.interfaceModeMigration,
            keys.exclusiveInterfaceModeMigration,
            keys.rewriteHotKeyCode,
            keys.rewriteHotKeyModifiers,
            keys.rewriteHotKeyEnabled,
            keys.rewriteHotKeyDefaultRMigration,
            keys.rewriteHotKeyDefaultRMigrationV2
        ]
        let previousValues = Dictionary(uniqueKeysWithValues: modifiedKeys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            for key in modifiedKeys {
                if let value = previousValues[key] ?? nil {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        modifiedKeys.forEach(defaults.removeObject(forKey:))

        defaults.set(TranslationLanguage.russian.rawValue, forKey: keys.translationLanguage)
        SelectionAssistantSettings.setSelectedOperation(.makeProfessional)
        SelectionAssistantSettings.setActivationMode(.hotkeyOnly)
        SelectionAssistantSettings.setHotKeysModeEnabled(true)
        SelectionAssistantSettings.setHotKey(
            TextoraHotKey(keyCode: 8, modifiers: UInt32(cmdKey | controlKey), isEnabled: true),
            for: .rewrite
        )

        let first = SelectionAssistantViewModel()
        let second = SelectionAssistantViewModel()
        XCTAssertEqual(first.translationLanguage, .russian)
        XCTAssertEqual(second.translationLanguage, .russian)
        XCTAssertEqual(first.operation, .makeProfessional)
        XCTAssertEqual(second.operation, .makeProfessional)
        XCTAssertEqual(SelectionAssistantSettings.activationMode(), .hotkeyOnly)
        XCTAssertTrue(SelectionAssistantSettings.hotKeysModeEnabled())
        XCTAssertEqual(SelectionAssistantSettings.hotKey(for: .rewrite).keyCode, 8)
    }
}
