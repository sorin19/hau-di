import AVFoundation
import AudioToolbox
import CoreAudio

// MARK: - Input devices (Core Audio)

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioDevices {
    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func inputDevices() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { id in
            guard hasInputStreams(id),
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        inputDevices().first { $0.uid == uid }?.id
    }

    static func defaultInputDeviceName() -> String? {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return stringProperty(id, kAudioObjectPropertyName)
    }
}

// MARK: - Recording

/// Records from the microphone and converts in real time to 16 kHz mono Float32 (the format Whisper requires).
/// A new AVAudioEngine is created for each recording: the microphone format is read fresh,
/// so a device change (headphones, AirPods) can't cause the fatal "format mismatch" exception.
final class AudioRecorder: @unchecked Sendable {
    enum RecorderError: LocalizedError {
        case noInput
        case engine(String)

        var errorDescription: String? {
            switch self {
            case .noInput: return "No active microphone found."
            case .engine(let detail): return "The microphone didn't start: \(detail)"
            }
        }
    }

    static let sampleRate: Double = 16_000

    /// The audio level (0...1), called on the main thread ~30 times a second.
    var onLevel: ((Float) -> Void)?

    private let queue = DispatchQueue(label: "ro.cx.app.hau-di.audio", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var session: CaptureSession?
    private let maxSamples = Int(sampleRate) * 60 * 10 // safety limit: 10 minutes

    func start(deviceUID: String?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.startOnQueue(deviceUID: deviceUID)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Stops and returns all the recorded audio (16 kHz mono).
    func stop() async -> [Float] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[Float], Never>) in
            queue.async {
                continuation.resume(returning: self.stopOnQueue())
            }
        }
    }

    func cancel() {
        queue.async { _ = self.stopOnQueue() }
    }

    private func startOnQueue(deviceUID: String?) throws {
        if engine != nil { return }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let uid = deviceUID, let deviceID = AudioDevices.deviceID(forUID: uid), let unit = input.audioUnit {
            var id = deviceID
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr {
                Log.audio.error("Can't select the microphone \(uid, privacy: .public): \(status)")
            }
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInput }

        let session = CaptureSession(maxSamples: maxSamples) { [weak self] level in
            DispatchQueue.main.async { self?.onLevel?(level) }
        }
        // format: nil = current input format (an explicit format other than the hardware's throws a fatal exception).
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            session.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.engine(error.localizedDescription)
        }
        self.engine = engine
        self.session = session
    }

    private func stopOnQueue() -> [Float] {
        guard let engine else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        let samples = session?.finish() ?? []
        session = nil
        DispatchQueue.main.async { [weak self] in self?.onLevel?(0) }
        return samples
    }
}

/// The state of a single recording. `append` is called serially on the tap's audio thread.
private final class CaptureSession: @unchecked Sendable {
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate,
                                             channels: 1, interleaved: false)!
    private let maxSamples: Int
    private let onLevel: (Float) -> Void
    private let lock = NSLock()
    private var samples: [Float] = []
    private var finished = false
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var lastLevelTime: TimeInterval = 0

    init(maxSamples: Int, onLevel: @escaping (Float) -> Void) {
        self.maxSamples = maxSamples
        self.onLevel = onLevel
        samples.reserveCapacity(Int(AudioRecorder.sampleRate) * 30)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        publishLevel(buffer)

        // The converter is (re)created from the actual format of the incoming buffers.
        let format = buffer.format
        if converter == nil || converterInputFormat != format {
            converter = AVAudioConverter(from: format, to: targetFormat)
            converter?.downmix = true
            converterInputFormat = format
        }
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var delivered = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if delivered {
                inputStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0, let channel = output.floatChannelData?[0] else { return }

        let count = Int(output.frameLength)
        lock.lock()
        if !finished && samples.count < maxSamples {
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
        }
        lock.unlock()
    }

    func finish() -> [Float] {
        lock.lock()
        finished = true
        let result = samples
        samples = []
        lock.unlock()
        return result
    }

    private func publishLevel(_ buffer: AVAudioPCMBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastLevelTime >= 1.0 / 30.0, let channel = buffer.floatChannelData?[0] else { return }
        lastLevelTime = now
        let frames = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<frames {
            let sample = channel[index]
            sum += sample * sample
        }
        let rms = (sum / Float(frames)).squareRoot()
        let decibels = 20 * log10(max(rms, 0.000_01))
        onLevel(max(0, min(1, (decibels + 55) / 50)))
    }
}
