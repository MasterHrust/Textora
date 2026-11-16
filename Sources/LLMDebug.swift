import AppKit
import Combine
import Foundation
import SwiftUI

enum LLMDebugRedactor {
    private static let safeHeaders: Set<String> = ["content-type", "content-length", "accept", "anthropic-version"]
    private static let secretNames: Set<String> = [
        "key", "apikey", "xapikey", "xgoogapikey", "authorization", "proxyauthorization",
        "token", "accesstoken", "refreshtoken", "idtoken", "sessiontoken", "xauthtoken",
        "secret", "clientsecret", "password", "passwd", "credential", "credentials",
        "privatekey", "cookie", "setcookie", "signature"
    ]

    private static func isSecretName(_ name: String) -> Bool {
        let normalized = name.lowercased().filter { $0.isLetter || $0.isNumber }
        return secretNames.contains(normalized) || normalized.hasSuffix("apikey")
            || normalized.hasSuffix("password") || normalized.hasSuffix("secret")
    }

    static func secrets(in request: URLRequest) -> [String] {
        var values = headerSecrets(request.allHTTPHeaderFields ?? [:])
        if let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            values += [components.user, components.password, components.fragment].compactMap { $0 }
            values += (components.queryItems ?? []).compactMap(\.value)
        }
        if let data = request.httpBody, let json = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) {
            values += jsonSecrets(json)
        }
        return Array(Set(values.filter { !$0.isEmpty })).sorted { $0.count > $1.count }
    }

    static func headerSecrets(_ headers: [String: String]) -> [String] {
        headers.flatMap { name, value -> [String] in
            guard !safeHeaders.contains(name.lowercased()) else { return [] }
            var values = [value]
            if name.lowercased().contains("authorization") {
                values += value.split(maxSplits: 1, whereSeparator: \.isWhitespace).dropFirst().map(String.init)
            }
            if name.lowercased().contains("cookie") {
                values += value.split(separator: ";").compactMap { field in
                    field.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init)
                }
            }
            return values
        }
    }

    private static func jsonSecrets(_ value: Any, sensitive: Bool = false) -> [String] {
        if sensitive {
            if let string = value as? String { return [string] }
            if let number = value as? NSNumber { return [number.stringValue] }
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.flatMap { name, item -> [String] in
                jsonSecrets(item, sensitive: sensitive || isSecretName(name))
            }
        }
        if let array = value as? [Any] { return array.flatMap { jsonSecrets($0, sensitive: sensitive) } }
        return []
    }

    static func secrets(in data: Data?) -> [String] {
        guard let data, let json = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else { return [] }
        return jsonSecrets(json)
    }

    static func text(_ value: String, secrets: [String]) -> String {
        var knownSecrets = secrets
        if let json = try? JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed) {
            knownSecrets += jsonSecrets(json)
        }
        var variants = Set<String>()
        for secret in knownSecrets where !secret.isEmpty {
            variants.insert(secret)
            variants.insert(secret.replacingOccurrences(of: "/", with: "\\/"))
            if let data = try? JSONEncoder().encode(secret), let encoded = String(data: data, encoding: .utf8) {
                variants.insert(String(encoded.dropFirst().dropLast()))
            }
            for characters in [CharacterSet.alphanumerics,
                               CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~")),
                               CharacterSet.urlQueryAllowed] {
                if let encoded = secret.addingPercentEncoding(withAllowedCharacters: characters) { variants.insert(encoded) }
            }
        }
        var redacted = value
        let pattern = variants.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern).joined(separator: "|")
        if !pattern.isEmpty, let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            redacted = regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "[REDACTED]")
        }
        for pattern in [#"\bsk-[A-Za-z0-9_-]{12,}"#, #"\bAIza[A-Za-z0-9_-]{20,}"#,
                        #"(?i)\bBearer\s+[A-Za-z0-9._~+/=\-]+"#,
                        #"(?i)["']?(?:api[_-]?key|access[_-]?token|client[_-]?secret|password)["']?\s*[=:]\s*["']?[^\s"',;<>]+"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            redacted = regex.stringByReplacingMatches(in: redacted, range: NSRange(redacted.startIndex..., in: redacted),
                                                      withTemplate: "[REDACTED]")
        }
        return redacted
    }

    static func url(_ url: URL?, secrets: [String]) -> String {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "Unavailable URL" }
        components.user = nil
        components.password = nil
        components.fragment = nil
        components.queryItems = components.queryItems?.map { URLQueryItem(name: $0.name, value: "[REDACTED]") }
        return text(components.string ?? "Unavailable URL", secrets: secrets)
    }

    static func headers(_ headers: [String: String], secrets: [String]) -> String {
        headers.keys.sorted().map { name in
            let value = safeHeaders.contains(name.lowercased()) ? text(headers[name] ?? "", secrets: secrets) : "[REDACTED]"
            return text(name, secrets: secrets) + ": " + value
        }.joined(separator: "\n")
    }

    static func body(_ data: Data?, secrets: [String], limit: Int) -> String {
        guard let data, !data.isEmpty else { return "No body" }
        let rendered: String
        if let json = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) {
            let allSecrets = secrets + jsonSecrets(json)
            let sanitized = redactJSON(json, secrets: allSecrets)
            if let encoded = try? JSONSerialization.data(withJSONObject: sanitized, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) {
                rendered = String(decoding: encoded, as: UTF8.self)
            } else { rendered = text(String(decoding: data, as: UTF8.self), secrets: allSecrets) }
        } else { rendered = text(String(decoding: data, as: UTF8.self), secrets: secrets) }
        return limited(rendered, to: limit)
    }

    private static func redactJSON(_ value: Any, secrets: [String]) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, field in
                result[text(field.key, secrets: secrets)] = isSecretName(field.key) ? "[REDACTED]" : redactJSON(field.value, secrets: secrets)
            }
        }
        if let array = value as? [Any] { return array.map { redactJSON($0, secrets: secrets) } }
        if let string = value as? String { return text(string, secrets: secrets) }
        if let number = value as? NSNumber {
            let redacted = text(number.stringValue, secrets: secrets)
            if redacted != number.stringValue { return redacted }
        }
        return value
    }

    static func limited(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n[Truncated]"
    }
}

struct LLMRequestLog: Identifiable {
    let id: UUID
    let date: Date
    let provider: String
    let model: String
    let endpoint: String
    let requestText: String
    let requestBytes: Int
    var responseText = "Waiting for response…"
    var responseBytes = 0
    var statusCode: Int?
    var duration: TimeInterval?
    var error = ""

    var status: String {
        if !error.isEmpty { return error == "Cancelled" ? "Cancelled" : "Failed" }
        if let statusCode { return "HTTP \(statusCode)" }
        return duration == nil ? "Running" : "Completed"
    }
    var copyText: String {
        """
        \(date.formatted(date: .numeric, time: .standard)) · \(provider) · \(model)
        \(status) · \(duration.map { String(format: "%.3f s", $0) } ?? "In progress")
        Request \(requestBytes) bytes · Response \(responseBytes) bytes

        REQUEST
        \(requestText)

        RESPONSE
        \(responseText)
        \(error.isEmpty ? "" : "\nERROR\n" + error)
        """
    }
}

@MainActor
final class LLMDebugLog: ObservableObject {
    static let shared = LLMDebugLog()
    struct Capture: Sendable {
        let id: UUID
        let epoch: Int
        let startedAt: UInt64
        fileprivate let secrets: [String]
    }
    @Published var isEnabled = false {
        didSet { if !isEnabled { clear() } }
    }
    @Published private(set) var entries: [LLMRequestLog] = []
    private var epoch = 0
    private let entryLimit: Int
    private let payloadLimit: Int

    init(entryLimit: Int = 50, payloadLimit: Int = 65_536) {
        self.entryLimit = max(1, entryLimit)
        self.payloadLimit = max(1, payloadLimit)
    }

    func begin(_ request: URLRequest, provider: String) -> Capture? {
        guard isEnabled else { return nil }
        let secrets = LLMDebugRedactor.secrets(in: request)
        let endpoint = LLMDebugRedactor.url(request.url, secrets: secrets)
        let headers = LLMDebugRedactor.headers(request.allHTTPHeaderFields ?? [:], secrets: secrets)
        let body = LLMDebugRedactor.body(request.httpBody, secrets: secrets, limit: payloadLimit)
        let json = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let modelFromPath = request.url.flatMap { url -> String? in
            guard url.path.contains("/models/") else { return nil }
            return url.lastPathComponent.split(separator: ":", maxSplits: 1).first.map(String.init)
        }
        let model = LLMDebugRedactor.text(json?["model"] as? String ?? modelFromPath ?? "Model catalog / provider default", secrets: secrets)
        let capture = Capture(id: UUID(), epoch: epoch, startedAt: DispatchTime.now().uptimeNanoseconds, secrets: secrets)
        let entry = LLMRequestLog(id: capture.id, date: Date(),
            provider: LLMDebugRedactor.text(provider, secrets: secrets),
            model: LLMDebugRedactor.limited(model, to: 300), endpoint: LLMDebugRedactor.limited(endpoint, to: 2048),
            requestText: LLMDebugRedactor.limited("\(request.httpMethod ?? "GET") \(endpoint)\n\(headers)\n\n\(body)", to: payloadLimit),
            requestBytes: request.httpBody?.count ?? 0)
        entries.insert(entry, at: 0)
        entries = Array(entries.prefix(entryLimit))
        return capture
    }

    func finish(_ capture: Capture, data: Data? = nil, response: URLResponse? = nil, error: Error? = nil, endedAt: UInt64) {
        guard isEnabled, capture.epoch == epoch, let index = entries.firstIndex(where: { $0.id == capture.id }) else { return }
        let http = response as? HTTPURLResponse
        let headers = http?.allHeaderFields.reduce(into: [String: String]()) { $0[String(describing: $1.key)] = String(describing: $1.value) } ?? [:]
        let secrets = capture.secrets + LLMDebugRedactor.headerSecrets(headers) + LLMDebugRedactor.secrets(in: data)
        let body = LLMDebugRedactor.body(data, secrets: secrets, limit: payloadLimit)
        let headerText = LLMDebugRedactor.headers(headers, secrets: secrets)
        entries[index].duration = Double(endedAt >= capture.startedAt ? endedAt - capture.startedAt : 0) / 1_000_000_000
        entries[index].statusCode = http?.statusCode
        entries[index].responseBytes = data?.count ?? 0
        entries[index].responseText = LLMDebugRedactor.limited("\(http.map { "HTTP \($0.statusCode)" } ?? "No HTTP response")\n\(headerText)\n\n\(body)", to: payloadLimit)
        if let error {
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            entries[index].error = cancelled ? "Cancelled" : LLMDebugRedactor.limited(LLMDebugRedactor.text(error.localizedDescription, secrets: secrets), to: 4096)
        }
    }

    func clear() {
        epoch += 1
        entries = []
    }
}

struct AdvancedDebugView: View {
    @ObservedObject var log: LLMDebugLog
    @State private var selected: UUID?
    @State private var tab = "request"
    @State private var notice = ""
    private var entry: LLMRequestLog? { log.entries.first { $0.id == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enable LLM request logging", isOn: $log.isEnabled).toggleStyle(.checkbox)
            Text("Keeps the latest 50 requests in memory for this session. Request and response text may contain private content. API keys are redacted. Turning logging off clears the journal.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Timing includes the full non-streaming request, from sending it to receiving the complete response.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(log.entries.count == 1 ? "1 request" : "\(log.entries.count) requests")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(notice).font(.caption).foregroundStyle(.secondary)
                Button("Copy log") { copyLog() }.disabled(entry == nil)
                Button("Clear") { log.clear(); selected = nil; notice = "" }
            }
            List(selection: $selected) {
                ForEach(log.entries) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(row.provider).fontWeight(.semibold)
                            Text(row.model).lineLimit(1)
                            Spacer()
                            Text(row.status).foregroundStyle((row.statusCode ?? 0) >= 400 || !row.error.isEmpty ? Color.red : Color.secondary)
                        }
                        HStack {
                            Text(row.date.formatted(date: .omitted, time: .standard))
                            Text(row.duration.map { String(format: "%.3f s", $0) } ?? "In progress")
                        }.font(.caption).foregroundStyle(.secondary)
                    }.tag(row.id)
                }
            }.frame(height: 145)
            if let entry {
                Text(entry.endpoint).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                Picker("Payload", selection: $tab) {
                    Text("Request").tag("request")
                    Text("Response").tag("response")
                }.pickerStyle(.segmented)
                ScrollView([.vertical, .horizontal]) {
                    Text(tab == "request" ? entry.requestText : entry.responseText + (entry.error.isEmpty ? "" : "\n\n" + entry.error))
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading).padding(10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text(log.isEnabled ? "Run an AI action, then select a request to inspect it." : "Enable logging, then run Rewrite, Translate, Summary or refresh the model list.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: log.entries.map(\.id), initial: true) { _, ids in
            if selected.map({ ids.contains($0) }) != true { selected = ids.first }
        }
        .onChange(of: selected) { _, _ in notice = "" }
    }

    private func copyLog() {
        guard let entry else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        notice = pasteboard.setString(entry.copyText, forType: .string) ? "Copied" : "Could not copy"
    }
}
