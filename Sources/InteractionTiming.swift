import Foundation
import os

/// Opt-in timing only; never records selected text, audio, credentials or URLs.
enum InteractionTiming {
    static let enabled = ProcessInfo.processInfo.environment["TEXTORA_PERFORMANCE"] == "1"
    private static let logger = Logger(subsystem: "com.textora.app", category: "interaction-timing")
    static func record(_ name: String, since start: TimeInterval) {
        guard enabled else { return }
        let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
        logger.info("\(name, privacy: .public) durationMs=\(milliseconds) mainThread=\(Thread.isMainThread)")
    }
    static func event(_ name: String, generation: Int) {
        guard enabled else { return }
        logger.info("\(name, privacy: .public) generation=\(generation)")
    }
}

final class InteractionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }
}
