import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

struct SpeechMicrophone: Identifiable, Hashable {
    let id: String
    let name: String
}

enum SpeechAudioRecorderError: LocalizedError {
    case microphoneDenied
    case invalidFormat
    case couldNotStart(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: return "Microphone access is required for offline dictation."
        case .invalidFormat: return "The selected microphone format is not supported."
        case .couldNotStart(let value): return "Could not start recording: \(value)"
        }
    }
}

final class SpeechAudioRecorder {
    static let maximumDuration: TimeInterval = 10 * 60

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private var maximumTimer: DispatchWorkItem?
    private var lastLevelDeliveryNanoseconds: UInt64 = 0
    private(set) var isRecording = false
    var onLevel: ((Float) -> Void)?
    var onMaximumDuration: (() -> Void)?

    static var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestPermission() async -> Bool {
        if authorizationStatus == .authorized { return true }
        if authorizationStatus == .denied || authorizationStatus == .restricted { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func microphones() -> [SpeechMicrophone] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return discovery.devices.map { SpeechMicrophone(id: $0.uniqueID, name: $0.localizedName) }
    }

    func start(microphoneUID: String) throws {
        guard !isRecording else { return }
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()
        lastLevelDeliveryNanoseconds = 0

        let input = engine.inputNode
        if !microphoneUID.isEmpty { Self.selectInputDevice(uid: microphoneUID, for: input.audioUnit) }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw SpeechAudioRecorderError.invalidFormat
        }
        self.converter = converter
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.consume(buffer, converter: converter, outputFormat: outputFormat)
        }
        do {
            engine.prepare()
            try engine.start()
            isRecording = true
        } catch {
            input.removeTap(onBus: 0)
            throw SpeechAudioRecorderError.couldNotStart(error.localizedDescription)
        }

        let timer = DispatchWorkItem { [weak self] in self?.onMaximumDuration?() }
        maximumTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maximumDuration, execute: timer)
    }

    func stop() -> [Float] {
        maximumTimer?.cancel()
        maximumTimer = nil
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        isRecording = false
        lock.lock(); defer { lock.unlock() }
        let value = samples
        samples.removeAll(keepingCapacity: false)
        return value
    }

    func cancel() {
        _ = stop()
    }

    private func consume(_ input: AVAudioPCMBuffer, converter: AVAudioConverter, outputFormat: AVAudioFormat) {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, conversionError == nil,
              let channel = output.floatChannelData?.pointee else { return }
        let count = Int(output.frameLength)
        guard count > 0 else { return }
        let chunk = Array(UnsafeBufferPointer(start: channel, count: count))
        lock.lock(); samples.append(contentsOf: chunk); lock.unlock()
        let peak = chunk.reduce(Float.zero) { max($0, abs($1)) }
        let now = DispatchTime.now().uptimeNanoseconds
        guard lastLevelDeliveryNanoseconds == 0 || now - lastLevelDeliveryNanoseconds >= 33_000_000 else { return }
        lastLevelDeliveryNanoseconds = now
        DispatchQueue.main.async { [weak self] in self?.onLevel?(min(1, peak * 5)) }
    }

    private static func selectInputDevice(uid: String, for audioUnit: AudioUnit?) {
        guard let audioUnit, let deviceID = audioDeviceID(forUID: uid) else { return }
        var mutableID = deviceID
        AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    private static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID: CFString = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            withUnsafeMutablePointer(to: &deviceID) { idPointer in
                var translation = AudioValueTranslation(
                    mInputData: uidPointer,
                    mInputDataSize: UInt32(MemoryLayout<CFString>.size),
                    mOutputData: idPointer,
                    mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                return AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    0,
                    nil,
                    &size,
                    &translation
                )
            }
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }
}
