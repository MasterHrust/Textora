import AppKit
import Carbon
import Foundation
import UserNotifications

final class EasySwitchManager {
    static let settingsDidChangeNotification = EasySwitchSettings.settingsDidChangeNotification
    static let replacementDidBeginNotification = Notification.Name("EasySwitch.replacementDidBegin")
    static let replacementDidEndNotification = Notification.Name("EasySwitch.replacementDidEnd")

    private let textService = TextAccessService()
    private let wordBuffer = WordBuffer()
    private let userDictionary = UserDictionary()
    private lazy var decisionEngine = EasySwitchDecisionEngine(userDictionary: userDictionary)
    private lazy var replacementService = ReplacementService(userDictionary: userDictionary)
    private let lock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var enabled = false
    private var settings = EasySwitchSettings.current()
    private var recentCorrectionDirection: EasySwitchDirection?
    private var recentCorrectionDirectionUntil: Date?
    private var notificationAuthorizationRequested = false
    private var suppressInputUntil: Date?

    var isRunning: Bool {
        lock.withLock { eventTap != nil }
    }

    func reloadSettings() {
        settings = EasySwitchSettings.current()
    }

    @discardableResult
    func start() -> Bool {
        reloadSettings()
        lock.lock()
        if eventTap != nil {
            enabled = true
            lock.unlock()
            return true
        }
        enabled = true
        lock.unlock()

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: EasySwitchManager.eventTapCallback,
            userInfo: refcon
        ) else {
            lock.withLock { enabled = false }
            textoraDiagLog("easySwitch", "start failed reason=eventTapCreate")
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            lock.withLock { enabled = false }
            textoraDiagLog("easySwitch", "start failed reason=runLoopSourceCreate")
            return false
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        lock.withLock {
            eventTap = tap
            runLoopSource = source
        }
        textoraDiagLog("easySwitch", "start succeeded")
        return true
    }

    func stop() {
        let state = lock.withLock { () -> (CFMachPort?, CFRunLoopSource?) in
            enabled = false
            wordBuffer.clear()
            let state = (eventTap, runLoopSource)
            eventTap = nil
            runLoopSource = nil
            return state
        }
        if let source = state.1 {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = state.0 {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let service = Unmanaged<EasySwitchManager>.fromOpaque(refcon).takeUnretainedValue()
        return service.handle(type: type, event: event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.withLock {
                if let eventTap {
                    CGEvent.tapEnable(tap: eventTap, enable: true)
                }
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        if isUndoShortcut(keyCode: keyCode, flags: flags) {
            return handleUndo(event: event)
        }
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            lock.withLock { wordBuffer.clear() }
            return Unmanaged.passUnretained(event)
        }

        let shouldIgnore = lock.withLock {
            if let suppressInputUntil, Date() <= suppressInputUntil {
                wordBuffer.clear()
                return true
            }
            suppressInputUntil = nil
            return replacementService.isReplacing || !enabled || !settings.enabled
        }
        guard !shouldIgnore else { return Unmanaged.passUnretained(event) }

        if keyCode == 51 {
            lock.withLock { wordBuffer.backspace() }
            return Unmanaged.passUnretained(event)
        }

        guard let chars = unicodeString(from: event), !chars.isEmpty else {
            return Unmanaged.passUnretained(event)
        }

        let keyboardLayout = EasySwitchInputSource.currentKeyboardLayout()
        if let delimiter = delimiter(
            chars: chars,
            keyCode: keyCode,
            keyboardLayout: keyboardLayout
        ) {
            return handleBoundary(delimiter: delimiter, event: event, keyboardLayout: keyboardLayout)
        }

        if chars.count == 1, let scalar = chars.unicodeScalars.first,
           CharacterSet.letters.contains(scalar) || scalar == "'" {
            lock.withLock { wordBuffer.append(chars) }
            return Unmanaged.passUnretained(event)
        }

        lock.withLock { wordBuffer.clear() }
        return Unmanaged.passUnretained(event)
    }

    private func delimiter(chars: String, keyCode: CGKeyCode, keyboardLayout: EasySwitchKeyboardLayout) -> String? {
        if chars.count == 1, let scalar = chars.unicodeScalars.first {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || ".!?,;:)]}".unicodeScalars.contains(scalar) {
                return chars
            }
        }
        return nil
    }

    private func handleBoundary(
        delimiter: String,
        event: CGEvent,
        keyboardLayout: EasySwitchKeyboardLayout
    ) -> Unmanaged<CGEvent>? {
        guard let boundary = lock.withLock({ wordBuffer.consumeBoundary(delimiter: delimiter) }) else {
            return Unmanaged.passUnretained(event)
        }
        let currentLanguage = language(for: keyboardLayout, preferredDirection: recentDirectionIfStillActive(for: keyboardLayout))
        let decision = decisionEngine.decision(for: boundary.word, currentLanguage: currentLanguage, settings: settings)
        logDecision(decision, delimiter: boundary.delimiter)
        guard decision.action == .replace,
              isSafeToApplyAutomaticCorrection() else {
            return Unmanaged.passUnretained(event)
        }

        if decision.kind == .layout {
            rememberCorrectionDirection(direction(for: decision))
        }
        suppressProgrammaticInput()
        userDictionary.addLearnedCorrection(original: decision.original, replacement: decision.converted)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(name: Self.replacementDidBeginNotification, object: nil)
            self.replacementService.replacePreviousWord(
                original: decision.original,
                replacement: decision.converted,
                delimiter: boundary.delimiter,
                targetKeyboardLayout: self.targetKeyboardLayout(for: decision),
                switchKeyboardLayout: decision.kind == .layout && self.settings.changesKeyboardLayout,
                preferClipboardInsertion: true
            ) { [weak self] in
                self?.lock.withLock {
                    self?.wordBuffer.clear()
                    self?.suppressInputUntil = Date().addingTimeInterval(0.25)
                }
                NotificationCenter.default.post(name: Self.replacementDidEndNotification, object: nil)
                self?.showNotificationIfNeeded(original: decision.original, replacement: decision.converted)
            }
        }
        return nil
    }

    private func handleUndo(event: CGEvent) -> Unmanaged<CGEvent>? {
        let handled = replacementService.undoLastReplacement { }
        if handled {
            lock.withLock { wordBuffer.clear() }
            textoraDiagLog("easySwitch", "undo applied")
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private func isUndoShortcut(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        keyCode == 6 && flags.contains(.maskCommand) && flags.contains(.maskShift)
    }

    private func language(for layout: EasySwitchKeyboardLayout, preferredDirection: EasySwitchDirection?) -> EasySwitchLanguage {
        if let preferredDirection {
            switch preferredDirection {
            case .latinToCyrillic:
                return .english
            case .cyrillicToLatin:
                return .russian
            }
        }
        switch layout {
        case .english:
            return .english
        case .russian:
            return .russian
        case .other:
            return .english
        }
    }

    private func direction(for decision: EasySwitchDecision) -> EasySwitchDirection {
        decision.sourceLanguage == .english ? .latinToCyrillic : .cyrillicToLatin
    }

    private func targetKeyboardLayout(for decision: EasySwitchDecision) -> EasySwitchKeyboardLayout {
        decision.targetLanguage == .english ? .english : .russian
    }

    private func recentDirectionIfStillActive(for layout: EasySwitchKeyboardLayout) -> EasySwitchDirection? {
        guard layout == .other else { return nil }
        return lock.withLock { () -> EasySwitchDirection? in
            guard let direction = recentCorrectionDirection,
                  let until = recentCorrectionDirectionUntil,
                  Date() <= until else {
                recentCorrectionDirection = nil
                recentCorrectionDirectionUntil = nil
                return nil
            }
            return direction
        }
    }

    private func rememberCorrectionDirection(_ direction: EasySwitchDirection) {
        lock.withLock {
            recentCorrectionDirection = direction
            recentCorrectionDirectionUntil = Date().addingTimeInterval(2.2)
        }
    }

    private func suppressProgrammaticInput() {
        lock.withLock {
            wordBuffer.clear()
            suppressInputUntil = Date().addingTimeInterval(0.7)
        }
    }

    private func unicodeString(from event: CGEvent) -> String? {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        chars.withUnsafeMutableBufferPointer { buffer in
            event.keyboardGetUnicodeString(
                maxStringLength: buffer.count,
                actualStringLength: &length,
                unicodeString: buffer.baseAddress
            )
        }
        guard length > 0 else { return nil }
        let scalars = chars.prefix(length).compactMap { UnicodeScalar(Int($0)) }
        return String(String.UnicodeScalarView(scalars))
    }

    private func isSafeToApplyAutomaticCorrection() -> Bool {
        guard textService.hasAccessibilityPermission() else { return false }
        guard textService.hasAllowedFocusedEditableElement() else { return false }
        guard !textService.shouldHardIgnoreCurrentFocusedInput() else { return false }
        return true
    }

    private func showNotificationIfNeeded(original: String, replacement: String) {
        if settings.playSoundOnCorrection {
            NSSound(named: "Pop")?.play()
        }
        guard settings.showCorrectionNotification else { return }
        deliverCorrectionNotification(original: original, replacement: replacement)
    }

    private func deliverCorrectionNotification(original: String, replacement: String) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "EasySwitch"
        content.body = "\(original) -> \(replacement)"

        let request = UNNotificationRequest(
            identifier: "easyswitch-correction-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        center.getNotificationSettings { [weak self] notificationSettings in
            switch notificationSettings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                center.add(request)
            case .notDetermined:
                self?.requestNotificationAuthorization(center: center, request: request)
            case .denied:
                break
            @unknown default:
                break
            }
        }
    }

    private func requestNotificationAuthorization(
        center: UNUserNotificationCenter,
        request: UNNotificationRequest
    ) {
        var shouldRequest = false
        lock.withLock {
            if !notificationAuthorizationRequested {
                notificationAuthorizationRequested = true
                shouldRequest = true
            }
        }
        guard shouldRequest else { return }
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            center.add(request)
        }
    }

    private func logDecision(_ decision: EasySwitchDecision, delimiter: String) {
        let original = settings.privacyMode ? "<redacted>" : textoraDiagPreview(decision.original, limit: 48)
        let converted = settings.privacyMode ? "<redacted>" : textoraDiagPreview(decision.converted, limit: 48)
        textoraDiagLog(
            "easySwitch",
            "original=\(original) converted=\(converted) delimiter=\(settings.privacyMode ? "<redacted>" : textoraDiagPreview(delimiter, limit: 8)) "
            + "originalScore=\(String(format: "%.2f", decision.originalScore)) convertedScore=\(String(format: "%.2f", decision.convertedScore)) "
            + "action=\(decision.action) kind=\(decision.kind) reason=\(decision.reason)"
        )
    }
}

private enum EasySwitchDirection {
    case latinToCyrillic
    case cyrillicToLatin
}
