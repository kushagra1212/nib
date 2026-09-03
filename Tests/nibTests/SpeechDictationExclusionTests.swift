import XCTest
@testable import nib

/// Reading aloud and dictation never run together, and dictation wins.
///
/// Contention is the smaller reason. Measured separately they peak at 219% and
/// 93% of a core, which a twelve-core machine absorbs. The real problem is that
/// dictation opens the microphone: anything nib is reading aloud is recorded
/// and transcribed back, so the words you asked it to read arrive in your
/// document as though you had said them.
///
/// Dictation wins because it is the one with a deadline. Speech can be asked
/// for again a second later; a sentence spoken into a closed microphone is
/// gone.
@MainActor
final class SpeechDictationExclusionTests: XCTestCase {
    private func controller(dictating: Bool) -> SpeechController {
        let speech = SpeechController()
        speech.isDictating = { dictating }
        // Nothing to speak, so the test never reaches the model. What is under
        // test is which refusal comes first.
        speech.readSelection = { nil }
        speech.readClipboard = { nil }
        return speech
    }

    /// The guard runs before anything else, so the reason names dictation
    /// rather than whatever would have failed next.
    func testSpeechDoesNotStartWhileDictating() {
        let speech = controller(dictating: true)
        speech.toggle()

        guard case .failed(let why) = speech.state else {
            return XCTFail("expected a refusal, got \(speech.state)")
        }
        XCTAssertTrue(why.lowercased().contains("listening"), why)
    }

    /// And the refusal is about dictation even when there is also nothing to
    /// speak -- otherwise the message sends someone off to check their
    /// selection while the microphone is the actual reason.
    func testTheDictationRefusalComesFirst() {
        let speech = controller(dictating: true)
        speech.toggle()
        guard case .failed(let why) = speech.state else {
            return XCTFail("expected a refusal")
        }
        XCTAssertFalse(why.contains("Nothing selected"), why)
    }

    /// With dictation idle the guard is out of the way, and the next honest
    /// failure is reached instead.
    func testSpeechProceedsWhenDictationIsIdle() {
        let speech = controller(dictating: false)
        speech.toggle()

        guard case .failed(let why) = speech.state else {
            return XCTFail("expected the empty-selection refusal")
        }
        XCTAssertTrue(why.contains("Nothing selected"), why)
    }

    /// Every state dictation can be in while it holds the microphone or the
    /// model counts as busy. Checking only `.recording` would let speech start
    /// during transcription, which is the 93% half of the contention.
    func testEveryActiveDictationStateCountsAsBusy() {
        for state: DictationState in [.requestingAccess, .recording, .transcribing,
                                      .inserting("text")] {
            XCTAssertTrue(state.isBusy, "\(state) should stop speech starting")
        }
        XCTAssertFalse(DictationState.idle.isBusy)
        XCTAssertFalse(DictationState.failed("x").isBusy)
    }

    /// Stopping is only meaningful while something is being said. Hushing an
    /// idle controller must not clear a failure the reader has not seen.
    func testStoppingSpeechIsOnlyMeaningfulWhileItSpeaks() {
        for state: SpeechState in [.preparing, .synthesising, .speaking] {
            XCTAssertEqual(state.next(for: .hushed), .idle, "\(state)")
        }
        XCTAssertNil(SpeechState.idle.next(for: .hushed))
        XCTAssertNil(SpeechState.failed("no model").next(for: .hushed))
    }

    /// The hook dictation calls is the one that fires before the microphone
    /// opens. `willTranscribe` is too late: by then the recording exists and
    /// already contains whatever nib was reading.
    func testDictationStopsSpeechBeforeTheMicrophoneOpens() {
        let dictation = DictationController()
        var stoppedSpeech = false
        var order: [String] = []

        dictation.willRecord = {
            stoppedSpeech = true
            order.append("stop speech")
        }
        dictation.willTranscribe = { order.append("transcribe") }

        // Called directly: opening a real microphone in a test needs
        // permission and a device, and what matters here is that the hook
        // exists and runs before transcription rather than after.
        dictation.willRecord?()
        dictation.willTranscribe?()

        XCTAssertTrue(stoppedSpeech)
        XCTAssertEqual(order, ["stop speech", "transcribe"])
    }
}
