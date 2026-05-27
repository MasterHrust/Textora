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
        var typePhysicalText: (String) -> Bool
        var pasteText: (String) -> Void
        var selectKeyboardLayout: (EasySwitchKeyboardLayout) -> Bool

        init(
            postBackspace: @escaping () -> Void,
            typeText: @escaping (String) -> Bool,
            typePhysicalText: @escaping (String) -> Bool = { _ in false },
            pasteText: @escaping (String) -> Void,
            selectKeyboardLayout: @escaping (EasySwitchKeyboardLayout) -> Bool
        ) {
            self.postBackspace = postBackspace
            self.typeText = typeText
            self.typePhysicalText = typePhysicalText
            self.pasteText = pasteText
            self.selectKeyboardLayout = selectKeyboardLayout
        }

        static let live = EventSink(
            postBackspace: {
                let source = CGEventSource(stateID: .combinedSessionState)
                let down = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true)
                let up = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false)
                down?.post(tap: .cghidEventTap)
                up?.post(tap: .cghidEventTap)
            },
            typeText: ReplacementService.typeUnicodeString,
            typePhysicalText: ReplacementService.typePhysicalASCIIString,
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
        preferClipboardInsertion: Bool = false,
        typedDelimiterAlreadyPassedThrough: Bool = false,
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

        let textToDelete = typedDelimiterAlreadyPassedThrough ? original + delimiter : original
        let deleteLength = (textToDelete as NSString).length
        for _ in 0..<deleteLength {
            eventSink.postBackspace()
            usleep(2_000)
        }
        if switchKeyboardLayout {
            _ = eventSink.selectKeyboardLayout(targetKeyboardLayout)
            usleep(30_000)
        }
        let insertedText = replacement + delimiter
        if preferClipboardInsertion {
            eventSink.pasteText(insertedText)
        } else if switchKeyboardLayout,
                  let physicalText = Self.physicalReplayText(
                    original: original,
                    replacement: replacement,
                    delimiter: delimiter,
                    targetKeyboardLayout: targetKeyboardLayout
                  ),
                  eventSink.typePhysicalText(physicalText) {
            // Physical replay keeps layout corrections paste-free in Electron composers.
        } else {
            _ = eventSink.typeText(insertedText)
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
        _ = eventSink.typeText(restored)
        userDictionary.addPersistentIgnore(lastReplacement.original)
        self.lastReplacement = nil
        clearReplacingSoon(completion: completion)
        return true
    }

    private func clearReplacingSoon(completion: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
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

    private static func physicalReplayText(
        original: String,
        replacement: String,
        delimiter: String,
        targetKeyboardLayout: EasySwitchKeyboardLayout
    ) -> String? {
        switch targetKeyboardLayout {
        case .russian:
            guard original.unicodeScalars.allSatisfy({ $0.value < 128 }) else { return nil }
            return original + delimiter
        case .english:
            guard replacement.unicodeScalars.allSatisfy({ $0.value < 128 }) else { return nil }
            return replacement + delimiter
        case .other:
            return nil
        }
    }

    private static func typePhysicalASCIIString(_ text: String) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        for scalar in text.unicodeScalars {
            guard let key = physicalKey(for: scalar) else { return false }
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: false) else {
                return false
            }
            down.flags = key.shift ? .maskShift : CGEventFlags()
            up.flags = key.shift ? .maskShift : CGEventFlags()
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(2_000)
        }
        return true
    }

    private static func physicalKey(for scalar: Unicode.Scalar) -> (code: CGKeyCode, shift: Bool)? {
        switch scalar {
        case "a": return (0x00, false)
        case "s": return (0x01, false)
        case "d": return (0x02, false)
        case "f": return (0x03, false)
        case "h": return (0x04, false)
        case "g": return (0x05, false)
        case "z": return (0x06, false)
        case "x": return (0x07, false)
        case "c": return (0x08, false)
        case "v": return (0x09, false)
        case "b": return (0x0B, false)
        case "q": return (0x0C, false)
        case "w": return (0x0D, false)
        case "e": return (0x0E, false)
        case "r": return (0x0F, false)
        case "y": return (0x10, false)
        case "t": return (0x11, false)
        case "1": return (0x12, false)
        case "2": return (0x13, false)
        case "3": return (0x14, false)
        case "4": return (0x15, false)
        case "6": return (0x16, false)
        case "5": return (0x17, false)
        case "=": return (0x18, false)
        case "9": return (0x19, false)
        case "7": return (0x1A, false)
        case "-": return (0x1B, false)
        case "8": return (0x1C, false)
        case "0": return (0x1D, false)
        case "]": return (0x1E, false)
        case "o": return (0x1F, false)
        case "u": return (0x20, false)
        case "[": return (0x21, false)
        case "i": return (0x22, false)
        case "p": return (0x23, false)
        case "l": return (0x25, false)
        case "j": return (0x26, false)
        case "'": return (0x27, false)
        case "k": return (0x28, false)
        case ";": return (0x29, false)
        case "\\": return (0x2A, false)
        case ",": return (0x2B, false)
        case "/": return (0x2C, false)
        case "n": return (0x2D, false)
        case "m": return (0x2E, false)
        case ".": return (0x2F, false)
        case " ": return (0x31, false)
        default:
            let lower = String(scalar).lowercased()
            guard lower != String(scalar),
                  let lowerScalar = lower.unicodeScalars.first,
                  let key = physicalKey(for: lowerScalar) else {
                return nil
            }
            return (key.code, true)
        }
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
