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

    /// Plays the samples and calls `whenFinished` on the main queue.
    ///
    /// `whenFinished` runs whether playback ended or was stopped, so a caller
    /// returning to idle does not need to handle the two separately.
    func play(_ samples: [Float], whenFinished: @escaping () -> Void) throws {
        stop()

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw Failure.noBuffer
        }
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)

        lock.lock()
        defer { lock.unlock() }

        do {
            try engine.start()
        } catch {
            throw Failure.cannotStart(error.localizedDescription)
        }
        running = true

        player.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            // Everything hops to main before touching the node again.
            //
            // Stopping from inside the node's own completion handler
            // deadlocks: AVAudioPlayerNode.stop() dispatches synchronously
            // onto the queue that is running this block, and libdispatch traps
            // on the cycle -- EXC_BREAKPOINT in __DISPATCH_WAIT_FOR_QUEUE__,
            // with no message saying what happened.
            //
            // .dataPlayedBack would be the exact callback, but it does not fire
            // when the buffer is dropped by a stop(), and a stop that never
            // returns to idle leaves the menu saying "Speaking" forever.
            DispatchQueue.main.async {
                self?.finish()
                whenFinished()
            }
        }
        player.play()
    }

    /// Stops immediately, dropping whatever has not been played.
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard running else { return }
        player.stop()
        engine.stop()
        running = false
    }

    private func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard running else { return }
        player.stop()
        engine.stop()
        running = false
    }
}
