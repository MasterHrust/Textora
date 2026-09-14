import CryptoKit
import Foundation

enum SpeechModelError: LocalizedError {
    case insecureURL
    case invalidResponse
    case checksumMismatch
    case invalidSize
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .insecureURL: return "The speech model must be downloaded over HTTPS."
        case .invalidResponse: return "The model server returned an invalid response."
        case .checksumMismatch: return "The downloaded model failed its security check. Please retry."
        case .invalidSize: return "The downloaded model has an unexpected size. Please retry."
        case .unavailable(let message): return message
        }
    }
}

enum SpeechModelDownloadPolicy {
    static func allows(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == "https" && url?.host?.isEmpty == false
    }

    static func redirectedRequest(_ request: URLRequest) -> URLRequest? {
        allows(request.url) ? request : nil
    }
}

private final class SpeechModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate {
    var progressHandler: ((Int64, Int64) -> Void)?
    var completionHandler: ((URL?, Error?) -> Void)?
    var stagingURL: URL?

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progressHandler?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let stagingURL else {
            completionHandler?(nil, SpeechModelError.unavailable("Could not prepare the model download."))
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: stagingURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: stagingURL)
            try FileManager.default.moveItem(at: location, to: stagingURL)
            completionHandler?(stagingURL, nil)
        } catch {
            completionHandler?(nil, error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        completionHandler?(nil, error)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(SpeechModelDownloadPolicy.redirectedRequest(newRequest))
    }
}

@MainActor
final class SpeechModelManager: ObservableObject {
    static let shared = SpeechModelManager()

    @Published private(set) var state: SpeechModelState = .notDownloaded
    let descriptor = SpeechModelDescriptor.parakeetV3Q4

    private let delegate = SpeechModelDownloadDelegate()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 60 * 60
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()
    private var task: URLSessionDownloadTask?
    private var completionConsumed = false

    private init() {
        delegate.progressHandler = { [weak self] written, expected in
            Task { @MainActor in self?.updateProgress(written: written, expected: expected) }
        }
        delegate.completionHandler = { [weak self] location, error in
            Task { @MainActor in await self?.downloadFinished(location: location, error: error) }
        }
        refreshState()
    }

    var modelsDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.textora.app", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    var modelURL: URL { modelsDirectory.appendingPathComponent(descriptor.fileName) }
    private var partialURL: URL { modelsDirectory.appendingPathComponent(descriptor.fileName + ".partial") }
    private var resumeDataURL: URL { modelsDirectory.appendingPathComponent(descriptor.fileName + ".resume") }

    func refreshState() {
        if FileManager.default.fileExists(atPath: modelURL.path) {
            verify()
        } else if FileManager.default.fileExists(atPath: resumeDataURL.path) {
            state = .paused(0)
        } else {
            state = .notDownloaded
        }
    }

    func download() {
        guard SpeechModelDownloadPolicy.allows(descriptor.downloadURL) else {
            state = .failed(SpeechModelError.insecureURL.localizedDescription)
            return
        }
        do { try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true) }
        catch { state = .failed(error.localizedDescription); return }

        completionConsumed = false
        delegate.stagingURL = partialURL
        if let resumeData = try? Data(contentsOf: resumeDataURL), !resumeData.isEmpty {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: descriptor.downloadURL)
        }
        try? FileManager.default.removeItem(at: resumeDataURL)
        state = .downloading(state.progress ?? 0)
        task?.resume()
    }

    func pause() {
        guard let task else { return }
        let progress = state.progress ?? 0
        let resumeURL = resumeDataURL
        task.cancel { [weak self] data in
            guard let self else { return }
            if let data { try? data.write(to: resumeURL, options: .atomic) }
            Task { @MainActor in
                self.task = nil
                self.completionConsumed = true
                self.state = .paused(progress)
            }
        }
    }

    func cancel() {
        completionConsumed = true
        task?.cancel()
        task = nil
        try? FileManager.default.removeItem(at: resumeDataURL)
        try? FileManager.default.removeItem(at: partialURL)
        state = .notDownloaded
    }

    func deleteModel() {
        cancel()
        OfflineTranscriptionService.shared.unload()
        try? FileManager.default.removeItem(at: modelURL)
        state = .notDownloaded
    }

    func verify() {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            state = .notDownloaded
            return
        }
        state = .verifying
        let url = modelURL
        let expectedSize = descriptor.byteCount
        let expectedHash = descriptor.sha256
        Task.detached(priority: .utility) {
            do {
                try Self.verifyFile(at: url, expectedSize: expectedSize, expectedHash: expectedHash)
                await MainActor.run { self.state = .ready }
            } catch {
                await MainActor.run { self.state = .failed(error.localizedDescription) }
            }
        }
    }

    private func updateProgress(written: Int64, expected: Int64) {
        let total = expected > 0 ? expected : descriptor.byteCount
        state = .downloading(min(1, max(0, Double(written) / Double(total))))
    }

    private func downloadFinished(location: URL?, error: Error?) async {
        guard !completionConsumed else { return }
        completionConsumed = true
        task = nil
        if let error {
            if (error as NSError).code == NSURLErrorCancelled { return }
            if let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
               !resumeData.isEmpty {
                try? resumeData.write(to: resumeDataURL, options: .atomic)
                state = .paused(state.progress ?? 0)
                return
            }
            state = .failed(error.localizedDescription)
            return
        }
        guard let location else { state = .failed(SpeechModelError.invalidResponse.localizedDescription); return }
        state = .verifying
        do {
            if location.standardizedFileURL != partialURL.standardizedFileURL {
                try? FileManager.default.removeItem(at: partialURL)
                try FileManager.default.moveItem(at: location, to: partialURL)
            }
            let size = descriptor.byteCount
            let hash = descriptor.sha256
            let downloadedPartialURL = partialURL
            let installedModelURL = modelURL
            try await Task.detached(priority: .utility) {
                try Self.installVerifiedFile(
                    stagedURL: downloadedPartialURL,
                    destinationURL: installedModelURL,
                    expectedSize: size,
                    expectedHash: hash
                )
            }.value
            try? FileManager.default.removeItem(at: resumeDataURL)
            state = .ready
        } catch {
            try? FileManager.default.removeItem(at: partialURL)
            state = .failed(error.localizedDescription)
        }
    }

    nonisolated static func verifyFile(at url: URL, expectedSize: Int64, expectedHash: String) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard Int64(values.fileSize ?? -1) == expectedSize else { throw SpeechModelError.invalidSize }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expectedHash.lowercased() else { throw SpeechModelError.checksumMismatch }
    }

    nonisolated static func installVerifiedFile(
        stagedURL: URL,
        destinationURL: URL,
        expectedSize: Int64,
        expectedHash: String
    ) throws {
        try verifyFile(at: stagedURL, expectedSize: expectedSize, expectedHash: expectedHash)
        let manager = FileManager.default
        if manager.fileExists(atPath: destinationURL.path) {
            _ = try manager.replaceItemAt(destinationURL, withItemAt: stagedURL)
        } else {
            try manager.moveItem(at: stagedURL, to: destinationURL)
        }
    }
}
