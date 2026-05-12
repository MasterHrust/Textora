import AppKit
import Carbon
import Foundation

struct EasySwitchReplacementRecord {
    let original: String
    let replacement: String
    let delimiter: String
    let targetKeyboardLayout: EasySwitchKeyboardLayout
}

final class ReplacementService {
    struct EventSink {
        var postBackspace: () -> Void
        var typeText: (String) -> Bool
        var pasteText: (String) -> Void
        var selectKeyboardLayout: (EasySwitchKeyboardLayout) -> Bool

        static let live = EventSink(
            postBackspace: {
                let source = CGEventSource(stateID: .combinedSessionState)
                let down = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true)
                let up = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false)
                down?.post(tap: .cghidEventTap)
                up?.post(tap: .cghidEventTap)
            },
            typeText: ReplacementService.typeUnicodeString,
            pasteText: ReplacementService.pasteText,
            selectKeyboardLayout: EasySwitchInputSource.selectKeyboardLayout
        )
    }

    private(set) var isReplacing = false
    private var lastReplacement: EasySwitchReplacementRecord?
    private let userDictionary: UserDictionary
    private let eventSink: EventSink

    init(userDictionary: UserDictionary, eventSink: EventSink = .live) {
        self.userDictionary = userDictionary
        self.eventSink = eventSink
    }

    func replacePreviousWord(
        original: String,
        replacement: String,
        delimiter: String,
        targetKeyboardLayout: EasySwitchKeyboardLayout,
        switchKeyboardLayout: Bool,
        completion: @escaping () -> Void
    ) {
        guard !original.isEmpty else {
            completion()
            return
        }
        isReplacing = true
        lastReplacement = EasySwitchReplacementRecord(
            original: original,
            replacement: replacement,
            delimiter: delimiter,
            targetKeyboardLayout: targetKeyboardLayout
        )

        let originalUTF16Length = (original as NSString).length
        for _ in 0..<originalUTF16Length {
            eventSink.postBackspace()
            usleep(2_000)
        }
        let inserted = eventSink.typeText(replacement + delimiter)
        if !inserted {
            eventSink.pasteText(replacement + delimiter)
        }
        if switchKeyboardLayout {
            _ = eventSink.selectKeyboardLayout(targetKeyboardLayout)
        }
        clearReplacingSoon(completion: completion)
    }

    func undoLastReplacement(completion: @escaping () -> Void) -> Bool {
        guard let lastReplacement else { return false }
        isReplacing = true
        let deleteLength = (lastReplacement.replacement + lastReplacement.delimiter as NSString).length
        for _ in 0..<deleteLength {
            eventSink.postBackspace()
            usleep(2_000)
        }
        let restored = lastReplacement.original + lastReplacement.delimiter
        let inserted = eventSink.typeText(restored)
        if !inserted {
            eventSink.pasteText(restored)
        }
        userDictionary.addPersistentIgnore(lastReplacement.original)
        self.lastReplacement = nil
        clearReplacingSoon(completion: completion)
        return true
    }

    private func clearReplacingSoon(completion: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.isReplacing = false
            completion()
        }
    }

    private static func pasteText(_ text: String) {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        triggerPasteShortcut()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            snapshot.restore(to: pasteboard)
        }
    }

    private static func typeUnicodeString(_ text: String) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        guard !units.isEmpty else { return true }

        var index = 0
        while index < units.count {
            let end = min(units.count, index + 32)
            let chunk = Array(units[index..<end])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                return false
            }
            chunk.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            index = end
            usleep(1_500)
        }
        return true
    }

    private static func triggerPasteShortcut() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

struct PasteboardSnapshot {
    struct Item {
        let representations: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    let items: [Item]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = pasteboard.pasteboardItems?.map { item in
            Item(representations: item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            })
        } ?? []
        return PasteboardSnapshot(items: items)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restoredItems = items.map { item -> NSPasteboardItem in
            let pasteboardItem = NSPasteboardItem()
            for representation in item.representations {
                pasteboardItem.setData(representation.data, forType: representation.type)
            }
            return pasteboardItem
        }
        pasteboard.writeObjects(restoredItems)
    }
}
