import CTranscribe
import Foundation

enum OfflineTranscriptionError: LocalizedError {
    case emptyAudio
    case modelLoad(String)
    case transcription(String)
    case noSpeech

    var errorDescription: String? {
        switch self {
        case .emptyAudio: return "No audio was recorded."
        case .modelLoad(let value): return "Could not load the offline speech model: \(value)"
        case .transcription(let value): return "Transcription failed: \(value)"
        case .noSpeech: return "No speech detected."
        }
    }
}

final class OfflineTranscriptionService: @unchecked Sendable {
    static let shared = OfflineTranscriptionService()

    private let queue = DispatchQueue(label: "com.textora.offline-transcription", qos: .userInitiated)
    private var session: OpaquePointer?
    private var loadedModelPath: String?
    private var unloadWorkItem: DispatchWorkItem?

    private init() {}

    func transcribe(samples: [Float], modelURL: URL, language: SpeechLanguage) async throws -> String {
        guard !samples.isEmpty else { throw OfflineTranscriptionError.emptyAudio }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { return }
                do {
                    let value = try self.transcribeSynchronously(samples: samples, modelURL: modelURL, language: language)
                    continuation.resume(returning: value)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func unload() {
        queue.async { [weak self] in self?.unloadSynchronously() }
    }

    private func transcribeSynchronously(samples: [Float], modelURL: URL, language: SpeechLanguage) throws -> String {
        unloadWorkItem?.cancel()
        if session == nil || loadedModelPath != modelURL.path {
            unloadSynchronously()
            let requestedBackend: transcribe_backend_request
#if arch(arm64)
            requestedBackend = TRANSCRIBE_BACKEND_METAL
#else
            requestedBackend = TRANSCRIBE_BACKEND_CPU
#endif
            var (status, opened) = openSession(modelURL: modelURL, backend: requestedBackend)
#if arch(arm64)
            if status != TRANSCRIBE_OK {
                (status, opened) = openSession(modelURL: modelURL, backend: TRANSCRIBE_BACKEND_CPU)
            }
#endif
            guard status == TRANSCRIBE_OK, let opened else {
                throw OfflineTranscriptionError.modelLoad(statusDescription(status))
            }
            session = opened
            loadedModelPath = modelURL.path
        }
        guard let session else { throw OfflineTranscriptionError.modelLoad("Unknown model error") }

        var params = transcribe_run_params()
        transcribe_run_params_init(&params)
        let status = language.rawValue.withCString { code in
            params.language = code
            return samples.withUnsafeBufferPointer { buffer in
                transcribe_run(session, buffer.baseAddress, Int32(buffer.count), &params)
            }
        }
        guard status == TRANSCRIBE_OK else {
            throw OfflineTranscriptionError.transcription(statusDescription(status))
        }
        guard let resultPointer = transcribe_full_text(session) else {
            throw OfflineTranscriptionError.noSpeech
        }
        let result = String(cString: resultPointer).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw OfflineTranscriptionError.noSpeech }
        scheduleUnload()
        return result
    }

    private func openSession(
        modelURL: URL,
        backend: transcribe_backend_request
    ) -> (transcribe_status, OpaquePointer?) {
        var loadParams = transcribe_model_load_params()
        transcribe_model_load_params_init(&loadParams)
        loadParams.backend = backend
        var opened: OpaquePointer?
        let status = modelURL.path.withCString {
            transcribe_open($0, &loadParams, nil, &opened)
        }
        return (status, opened)
    }

    private func statusDescription(_ status: transcribe_status) -> String {
        guard let pointer = transcribe_status_string(Int32(bitPattern: status.rawValue)) else {
            return "status \(status.rawValue)"
        }
        return String(cString: pointer)
    }

    private func scheduleUnload() {
        unloadWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.unloadSynchronously() }
        unloadWorkItem = item
        queue.asyncAfter(deadline: .now() + 300, execute: item)
    }

    private func unloadSynchronously() {
        unloadWorkItem?.cancel()
        unloadWorkItem = nil
        if let session { transcribe_session_free(session) }
        session = nil
        loadedModelPath = nil
    }
}
