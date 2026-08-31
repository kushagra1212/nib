import AVFoundation

/// Captures microphone audio as 16kHz mono samples.
///
/// Runs only while dictating. The engine is built, started, stopped and torn
/// down per recording rather than kept warm: an idle audio graph is a thread
/// and a hardware wakeup for something the user is not doing, and holding the
/// microphone open is also the thing that would make the recording indicator
/// a lie.
final class AudioRecorder {
    enum Failure: Error, CustomStringConvertible {
        case denied
        case noInputDevice
        case engineFailed(String)
        case conversionFailed(String)

        var description: String {
            switch self {
            case .denied:
                return "nib is not allowed to use the microphone"
            case .noInputDevice:
                return "no microphone is connected"
            case .engineFailed(let why):
                return "could not start recording: \(why)"
            case .conversionFailed(let why):
                return "could not convert the audio: \(why)"
            }
        }
    }

    /// Stops itself at this length.
    ///
    /// A toggle can be forgotten, and held audio grows without bound: ten
    /// minutes at 16kHz mono float is about 38MB, which is the most this may
    /// quietly consume before it stops on its own.
    static let maximumDuration: TimeInterval = 600

    /// Loudness of the most recent buffer, 0...1, for the overlay to draw.
    private(set) var level: Float = 0
    private(set) var isRecording = false

    /// Called on the main thread when the cap is reached, so the controller
    /// can stop and transcribe rather than discard.
    var onReachedLimit: (() -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var captured: [Float] = []
    private let lock = NSLock()

    // MARK: - Permission

    /// Whether the microphone may be used, asking the first time.
    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    static var isAuthorised: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: - Recording

    func start() throws {
        guard !isRecording else { return }
        guard Self.isAuthorised else { throw Failure.denied }

        lock.lock()
        captured.removeAll(keepingCapacity: true)
        lock.unlock()

        let input = engine.inputNode
        let sourceFormat = input.outputFormat(forBus: 0)
        // A rate of zero means the device vanished between the check and here,
        // which happens with USB microphones and Bluetooth headsets.
        guard sourceFormat.sampleRate > 0 else { throw Failure.noInputDevice }

        let target = AudioSamples.whisperFormat
        guard let converter = AVAudioConverter(from: sourceFormat, to: target) else {
            throw Failure.conversionFailed("no converter from \(sourceFormat)")
        }
        self.converter = converter

        // 4096 frames is roughly 85ms at 48kHz: frequent enough that the level
        // meter looks live, large enough not to wake the CPU constantly.
        input.installTap(onBus: 0, bufferSize: 4096, format: sourceFormat) {
            [weak self] buffer, _ in
            self?.append(buffer, using: converter, target: target)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw Failure.engineFailed(error.localizedDescription)
        }
        isRecording = true
    }

    /// Stops and returns everything captured.
    @discardableResult
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        level = 0
        converter = nil

        lock.lock()
        defer { lock.unlock() }
        let samples = captured
        captured = []
        return samples
    }

    /// Stops and throws the audio away.
    func cancel() {
        _ = stop()
    }

    /// Seconds captured so far.
    var elapsed: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return AudioSamples.duration(of: captured)
    }

    // MARK: - The tap

    private func append(_ buffer: AVAudioPCMBuffer,
                        using converter: AVAudioConverter,
                        target: AVAudioFormat) {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target,
                                            frameCapacity: capacity) else { return }

        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil else { return }

        let samples = AudioSamples.samples(from: output)
        guard !samples.isEmpty else { return }

        // Root mean square, not peak: peak jumps to full scale on a single
        // click and makes the meter useless for showing whether speech is
        // being heard.
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        let rms = (sum / Float(samples.count)).squareRoot()
        level = min(1, rms * 8)

        lock.lock()
        captured.append(contentsOf: samples)
        let reachedLimit = AudioSamples.duration(of: captured) >= Self.maximumDuration
        lock.unlock()

        if reachedLimit {
            DispatchQueue.main.async { [weak self] in self?.onReachedLimit?() }
        }
    }
}
