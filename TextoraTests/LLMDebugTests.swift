import AppKit
import SwiftUI
import XCTest
@testable import Textora

final class LLMDebugTests: XCTestCase {
    func testFeatureRequestUsesTheSameAddressAndDeveloperCredit() throws {
        let url = try XCTUnwrap(URLComponents(url: AppContact.featureRequestURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(url.scheme, "mailto")
        XCTAssertEqual(url.path, "indepcode@proton.me")
        XCTAssertEqual(url.queryItems?.first(where: { $0.name == "subject" })?.value, "Textora Feature Request")
        XCTAssertEqual(AppContact.developerCredit, "Developed by Roman Shytskou")
    }

    @MainActor
    func testLoggingIsOffByDefaultAndClearAndDisableRejectLateResponses() throws {
        let log = LLMDebugLog()
        let request = URLRequest(url: try XCTUnwrap(URL(string: "http://localhost:1234/v1/models")))
        XCTAssertFalse(log.isEnabled)
        XCTAssertNil(log.begin(request, provider: "Local"))
        log.isEnabled = true
        let old = try XCTUnwrap(log.begin(request, provider: "Local"))
        XCTAssertEqual(log.entries.first?.status, "Running")
        log.clear()
        log.finish(old, data: Data("old".utf8), endedAt: old.startedAt + 1_000_000)
        XCTAssertTrue(log.entries.isEmpty)
        let disabled = try XCTUnwrap(log.begin(request, provider: "Local"))
        log.isEnabled = false
        log.isEnabled = true
        log.finish(disabled, data: Data("old".utf8), endedAt: disabled.startedAt + 1_000_000)
        XCTAssertTrue(log.entries.isEmpty)
    }

    @MainActor
    func testSecretsAreMaskedAcrossURLHeadersJSONResponseErrorAndCopy() throws {
        let log = LLMDebugLog()
        log.isEnabled = true
        let apiKey = "opaque-api-key-987654321/Ab+C="
        let queryKey = "opaque-query-987654321"
        let cookie = "opaque-cookie-987654321"
        let bodyKey = "opaque-body-987654321"
        let responseKey = "opaque-response-987654321"
        let encodedKey = apiKey.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))!
        var components = URLComponents(string: "https://example.com/v1/chat/completions")!
        components.user = "private-user"
        components.password = "private-password"
        components.queryItems = [URLQueryItem(name: "api_key", value: queryKey)]
        components.fragment = "private-fragment"
        var request = URLRequest(url: try XCTUnwrap(components.url))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("session=\(cookie)", forHTTPHeaderField: "Cookie")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "my-local-model", "credentials": ["custom": bodyKey],
            "messages": [["role": "user", "content": "\(apiKey) \(encodedKey) \(bodyKey)"]]
        ])
        let originalBody = request.httpBody
        let capture = try XCTUnwrap(log.begin(request, provider: "Other"))
        let data = try JSONSerialization.data(withJSONObject: [
            "credentials": ["nested": [responseKey]],
            "echo": "\(apiKey) \(queryKey) \(cookie) \(bodyKey) \(responseKey) \(encodedKey)",
            "usage": ["completion_tokens": 18]
        ])
        let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: "HTTP/1.1",
            headerFields: ["Set-Cookie": "session=\(cookie)", "Content-Type": "application/json"]))
        log.finish(capture, data: data, response: response,
            error: NSError(domain: "LLM", code: 1, userInfo: [NSLocalizedDescriptionKey: "Rejected \(apiKey) \(responseKey)"]),
            endedAt: capture.startedAt + 2_500_000_000)
        let entry = try XCTUnwrap(log.entries.first)
        for secret in [apiKey, encodedKey, queryKey, cookie, bodyKey, responseKey, "private-user", "private-password", "private-fragment"] {
            XCTAssertFalse(entry.copyText.contains(secret), secret)
        }
        XCTAssertTrue(entry.requestText.contains("application/json"))
        XCTAssertTrue(entry.responseText.contains("completion_tokens"))
        XCTAssertTrue(entry.copyText.contains("[REDACTED]"))
        XCTAssertEqual(entry.model, "my-local-model")
        XCTAssertEqual(entry.statusCode, 401)
        XCTAssertEqual(entry.duration, 2.5)
        XCTAssertEqual(request.httpBody, originalBody)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(apiKey)")
    }

    func testNestedCredentialCollectionsAndEscapedKeysAreRedactedBeforeTruncation() throws {
        let secret = "opaque/secret-987654321"
        let data = Data(#"{"credentials":{"custom":"opaque/secret-987654321"},"api_key":["another-secret-987654321"],"echo":"opaque\/secret-987654321 another-secret-987654321"}"#.utf8)
        let redacted = LLMDebugRedactor.body(data, secrets: [], limit: 10_000)
        XCTAssertFalse(redacted.contains(secret))
        XCTAssertFalse(redacted.contains("another-secret-987654321"))
        let plaintext = Data((String(repeating: "X", count: 20) + secret + " tail").utf8)
        let truncated = LLMDebugRedactor.body(plaintext, secrets: [secret], limit: 25)
        XCTAssertFalse(truncated.contains("opaque"))
        XCTAssertTrue(truncated.contains("[Truncated]"))
        let colliding = try JSONSerialization.data(withJSONObject: ["first-secret": "a", "second-secret": "b"])
        XCTAssertNoThrow(LLMDebugRedactor.body(colliding, secrets: ["first-secret", "second-secret"], limit: 100))
        XCTAssertEqual(LLMDebugRedactor.text("secret", secrets: ["secret", "E", "D", "A", "R", "T", "C"]), "[REDACTED]")
        let embedded = #"config {"api_key":"custom-secret-123", "password":"password-123"}"#
        let sanitized = LLMDebugRedactor.text(embedded, secrets: [])
        XCTAssertFalse(sanitized.contains("custom-secret-123"))
        XCTAssertFalse(sanitized.contains("password-123"))
        let nested = #"{"credentials":["opaque-nested-123"],"echo":"opaque-nested-123"}"#
        XCTAssertFalse(LLMDebugRedactor.text(nested, secrets: []).contains("opaque-nested-123"))
        for payload in [#"{"api_key":"12345678","echo":12345678}"#,
                        #"{"api_key":12345678,"nested":{"echo":12345678},"usage":42}"#,
                        #"{"echo":12345678}"#] {
            let sanitized = LLMDebugRedactor.body(Data(payload.utf8), secrets: ["12345678"], limit: 10_000)
            XCTAssertFalse(sanitized.contains("12345678"))
            XCTAssertTrue(sanitized.contains("[REDACTED]"))
        }
    }

    @MainActor
    func testConcurrentLogsAreBoundedAndCancellationIsRecorded() throws {
        let log = LLMDebugLog(entryLimit: 2, payloadLimit: 100)
        log.isEnabled = true
        var request = URLRequest(url: URL(string: "http://localhost:1234/v1/chat/completions")!)
        request.httpBody = Data(String(repeating: "A", count: 1000).utf8)
        let evicted = try XCTUnwrap(log.begin(request, provider: "Local"))
        let cancelled = try XCTUnwrap(log.begin(request, provider: "Local"))
        let latest = try XCTUnwrap(log.begin(request, provider: "Local"))
        log.finish(evicted, data: Data("evicted".utf8), endedAt: evicted.startedAt + 1)
        log.finish(latest, data: Data("ok".utf8), endedAt: latest.startedAt + 1)
        log.finish(cancelled, error: URLError(.cancelled), endedAt: cancelled.startedAt + 1)
        XCTAssertEqual(log.entries.count, 2)
        XCTAssertEqual(log.entries.first(where: { $0.id == cancelled.id })?.status, "Cancelled")
        XCTAssertFalse(log.entries.contains(where: { $0.id == evicted.id }))
        XCTAssertTrue(log.entries.allSatisfy { $0.requestText.contains("[Truncated]") })
    }

    @MainActor
    func testChangingProviderBeforeAutosaveKeepsAllEditedTokensAndRetriesFailures() throws {
        let defaults = UserDefaults.standard
        let keys = ["provider", "model", AIClient.localBaseURLUserDefaultsKey, AIClient.openAICompatibleBaseURLUserDefaultsKey]
            + AIProvider.allCases.map(\.modelUserDefaultsKey)
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            for key in keys {
                if let value = previous[key] ?? nil { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        let model = AppViewModel()
        model.localBaseURL = ""
        model.customOpenAIBaseURL = ""
        model.provider = .local
        model.localToken = "edited-local-token"
        model.provider = .other
        model.customToken = "edited-other-token"
        var writes: [String: String] = [:]
        XCTAssertFalse(model.saveSettings { account, value in
            if account == KeychainHelper.customTokenAccount { return .failure(.verificationFailed) }
            writes[account] = value
            return .success(())
        })
        XCTAssertTrue(model.saveSettings { account, value in
            writes[account] = value
            return .success(())
        })
        XCTAssertEqual(writes[KeychainHelper.localTokenAccount], "edited-local-token")
        XCTAssertEqual(writes[KeychainHelper.customTokenAccount], "edited-other-token")
        var repeated = 0
        XCTAssertTrue(model.saveSettings { _, _ in repeated += 1; return .success(()) })
        XCTAssertEqual(repeated, 0)
    }

    @MainActor
    func testAdvancedDebugNavigationPersistsWithoutChangingProviderSettings() throws {
        let name = "TextoraTests.DebugNavigation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("local", forKey: "provider")
        let navigation = SettingsNavigation(defaults: defaults)
        navigation.open(.advancedDebug)
        XCTAssertEqual(SettingsNavigation(defaults: defaults).section, .advancedDebug)
        XCTAssertEqual(defaults.string(forKey: "provider"), "local")
    }
}
