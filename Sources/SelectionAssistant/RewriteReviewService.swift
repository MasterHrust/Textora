import Foundation

/// One active review and one replaceable pending review. A slow provider cannot
/// build an unbounded queue as the user changes selections.
actor RewriteReviewService {
    static let shared = RewriteReviewService()
    private struct Request {
        let id: UUID
        let key: String
        let operation: @Sendable () async throws -> [OverlaySuggestion]
        let continuation: CheckedContinuation<[OverlaySuggestion], Error>
    }
    private var active: Request?
    private var pending: Request?
    private var worker: Task<Void, Never>?
    private var cache: [String: (Date, [OverlaySuggestion])] = [:]
    var pendingCount: Int { pending == nil ? 0 : 1 }
    var pendingKey: String? { pending?.key }

    func review(key: String, operation: @escaping @Sendable () async throws -> [OverlaySuggestion]) async throws -> [OverlaySuggestion] {
        try Task.checkCancellation()
        if let (date, result) = cache[key], Date().timeIntervalSince(date) < 300 { return result }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending?.continuation.resume(throwing: CancellationError())
                pending = Request(id: id, key: key, operation: operation, continuation: continuation)
                if active == nil { startPending() }
                else { worker?.cancel() }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        if pending?.id == id {
            pending?.continuation.resume(throwing: CancellationError())
            pending = nil
        }
        if active?.id == id { worker?.cancel() }
    }

    private func startPending() {
        guard active == nil, let request = pending else { return }
        pending = nil
        active = request
        worker = Task {
            do {
                let result = try await request.operation()
                try Task.checkCancellation()
                cache = cache.filter { Date().timeIntervalSince($0.value.0) < 300 }
                if cache.count >= 12, let oldest = cache.min(by: { $0.value.0 < $1.value.0 })?.key {
                    cache.removeValue(forKey: oldest)
                }
                // Retry must ask the provider again for rejected variants.
                if result.allSatisfy({ $0.validationError == nil }) {
                    cache[request.key] = (Date(), result)
                }
                request.continuation.resume(returning: result)
            } catch { request.continuation.resume(throwing: error) }
            active = nil
            worker = nil
            startPending()
        }
    }
}
