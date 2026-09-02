import AVFoundation
import Foundation

/// Plays the samples, and stops when told.
///
/// `AVAudioEngine` with one player node rather than `AVAudioPlayer`, because
/// the samples are already in memory as floats and writing them to a temporary
/// WAV to play a file back would be slower and leave files behind.
///
/// Nothing is started until there is something to play, and the engine is
/// stopped when playback finishes. An idle audio engine keeps the process
/// awake and shows nib as using the microphone-adjacent audio hardware, which
/// is exactly the always-on behaviour dictation was designed to avoid.
final class SpeechPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private var running = false
    /// Set once per playback, so a stop during a batch cannot also report
    /// finishing when that batch's completion handler runs afterwards.
    private var finished = true
    private var onFinished: (() -> Void)?

    /// What Kokoro produces. Not the output device's rate -- the engine
    /// converts, which is why the format is stated rather than queried.
    private let format: AVAudioFormat

    enum Failure: Error, CustomStringConvertible {
        case noFormat
        case noBuffer
        case cannotStart(String)

        var description: String {
            switch self {
            case .noFormat:
                return "cannot describe 24000 Hz mono audio"
            case .noBuffer:
                return "cannot make a buffer for the samples"
            case .cannotStart(let reason):
                return "the audio engine would not start: \(reason)"
            }
        }
    }

    init() throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate:
                                            Double(KokoroEngine.sampleRate),
                                         channels: 1) else {
            throw Failure.noFormat
        }
        self.format = format

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    var isPlaying: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running && player.isPlaying
    }

    /// Plays samples that are all ready, and calls `whenFinished` on main.
    func play(_ samples: [Float], whenFinished: @escaping () -> Void) throws {
        stop()
        try begin(whenFinished: whenFinished)
        try enqueue(samples, isLast: true)
    }

    /// Opens the device, ready for batches.
    ///
    /// Separate from `enqueue` so playback can start on the first batch while
    /// the rest is still being synthesised. Waiting for all of it first means a
    /// long selection sits silent for as long as it takes to render, which is
    /// over a minute for a few thousand characters.
    func begin(whenFinished: @escaping () -> Void) throws {
        stop()
        lock.lock()
        defer { lock.unlock() }

        do {
            try engine.start()
        } catch {
            throw Failure.cannotStart(error.localizedDescription)
        }
        running = true
        finished = false
        onFinished = whenFinished
        player.play()
    }

    /// Adds one batch to the queue.
    ///
    /// `isLast` is what decides when playback is over. Counting scheduled
    /// buffers would not do: the queue is legitimately empty whenever synthesis
    /// falls behind playback, and treating that as the end would cut the
    /// sentence off mid-word.
    func enqueue(_ samples: [Float], isLast: Bool) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw Failure.noBuffer
        }
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.update(from: base, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)

        lock.lock()
        let live = running
        lock.unlock()
        guard live else { return }

        player.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            guard isLast else { return }
            // Everything hops to main before touching the node again.
            //
            // Stopping from inside the node's own completion handler
            // deadlocks: AVAudioPlayerNode.stop() dispatches synchronously
            // onto the queue that is running this block, and libdispatch traps
            // on the cycle -- EXC_BREAKPOINT in __DISPATCH_WAIT_FOR_QUEUE__,
            // with no message saying what happened.
            DispatchQueue.main.async {
                guard let self else { return }
                let report = self.finish()
                report?()
            }
        }
    }

    /// Stops immediately, dropping whatever has not been played.
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard running else { return }
        player.stop()
        engine.stop()
        player.reset()
        running = false
        finished = true
        onFinished = nil
    }

    /// Tears down and returns the completion to call, or nil if something else
    /// already ended this playback. Returned rather than called so the lock is
    /// not held while the caller runs.
    private func finish() -> (() -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        guard running, !finished else { return nil }
        player.stop()
        engine.stop()
        player.reset()
        running = false
        finished = true
        let report = onFinished
        onFinished = nil
        return report
    }
}
