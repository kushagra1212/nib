import XCTest
@testable import nib

/// Stripping whisper's sound descriptions out of a transcript.
///
/// Dictation types its result straight into whatever field is focused, so
/// anything the model writes that is not a word someone said ends up in a
/// message. A pause before speaking produced "[BLANK_AUDIO][BLANK_AUDIO]" in a
/// chat box.
final class TranscriptCleaningTests: XCTestCase {
    // MARK: - The reported failure

    func testSilenceLeavesNothingBehind() {
        XCTAssertEqual(WhisperEngine.clean("[BLANK_AUDIO]"), "")
        XCTAssertEqual(WhisperEngine.clean("[BLANK_AUDIO][BLANK_AUDIO]"), "")
        XCTAssertEqual(WhisperEngine.clean(" [BLANK_AUDIO] \n"), "")
    }

    /// An empty result is what the state machine already refuses to insert, so
    /// this is what makes a silent dictation do nothing at all.
    func testAnAllMarkerTranscriptIsEmptyNotBlank() {
        XCTAssertTrue(WhisperEngine.clean("[SILENCE] [MUSIC] [INAUDIBLE]").isEmpty)
    }

    // MARK: - Other things whisper narrates

    func testOtherBracketedMarkersGoToo() {
        for marker in ["[SILENCE]", "[MUSIC]", "[NOISE]", "[INAUDIBLE]",
                       "[ Silence ]", "[BLANK _AUDIO]"] {
            XCTAssertEqual(WhisperEngine.clean("hello \(marker) there"),
                           "hello there", marker)
        }
    }

    func testAsterisksGo() {
        XCTAssertEqual(WhisperEngine.clean("well *coughs* anyway"), "well anyway")
    }

    func testParenthesisedSoundsGo() {
        XCTAssertEqual(WhisperEngine.clean("(upbeat music) hello"), "hello")
        XCTAssertEqual(WhisperEngine.clean("hello (laughs)"), "hello")
        XCTAssertEqual(WhisperEngine.clean("(wind blowing) start now"), "start now")
    }

    // MARK: - What must survive

    /// The risk of stripping parentheses: someone dictating an aside. Anything
    /// long, punctuated or numeric is speech, not a sound.
    func testARealAsideInParenthesesSurvives() {
        let spoken = "the total (which we agreed last week, remember) was wrong"
        XCTAssertEqual(WhisperEngine.clean(spoken), spoken)
    }

    func testParenthesesWithNumbersSurvive() {
        let spoken = "call me (555) later"
        XCTAssertEqual(WhisperEngine.clean(spoken), spoken)
    }

    func testOrdinarySpeechIsUntouched() {
        let spoken = "She doesn't like it when he doesn't listen."
        XCTAssertEqual(WhisperEngine.clean(spoken), spoken)
    }

    // MARK: - Tidying after the cut

    /// "Hello [BLANK_AUDIO], there" must not become "Hello , there".
    func testPunctuationDoesNotEndUpStranded() {
        XCTAssertEqual(WhisperEngine.clean("Hello [BLANK_AUDIO], there"),
                       "Hello, there")
        XCTAssertEqual(WhisperEngine.clean("Right [SILENCE]. Next."),
                       "Right. Next.")
    }

    func testInternalWhitespaceCollapses() {
        XCTAssertEqual(WhisperEngine.clean("one   two\n\nthree"), "one two three")
    }

    func testLeadingAndTrailingSpaceGoes() {
        XCTAssertEqual(WhisperEngine.clean("  hello there  "), "hello there")
    }

    func testEmptyInputStaysEmpty() {
        XCTAssertEqual(WhisperEngine.clean(""), "")
        XCTAssertEqual(WhisperEngine.clean("   "), "")
    }
}

/// Refusing to transcribe silence at all.
///
/// Cleaning the output was not enough: with "[BLANK_AUDIO]" stripped, four
/// seconds of a silent file came back as "you" instead -- a plausible word,
/// reported by the model as speech, which is worse than an obvious marker.
final class SilenceDetectionTests: XCTestCase {
    private func tone(amplitude: Float, seconds: Double = 1) -> [Float] {
        let count = Int(AudioSamples.sampleRate * seconds)
        return (0..<count).map { index in
            amplitude * sin(Float(index) * 0.1)
        }
    }

    func testDigitalSilenceIsSilent() {
        XCTAssertTrue(AudioSamples.isSilent(Array(repeating: 0, count: 16_000)))
    }

    /// Measured at -91 dB peak on a silent WAV, far below the threshold.
    func testNearSilenceIsStillSilent() {
        XCTAssertTrue(AudioSamples.isSilent(tone(amplitude: 0.00003)))
    }

    /// Measured at -1.8 dB peak on a spoken sentence.
    func testSpeechIsNotSilent() {
        XCTAssertFalse(AudioSamples.isSilent(tone(amplitude: 0.8)))
    }

    /// The failure that would matter most: discarding someone who spoke
    /// quietly. A mumble well below normal speech must still get through.
    func testQuietSpeechSurvives() {
        XCTAssertFalse(AudioSamples.isSilent(tone(amplitude: 0.02)),
                       "a quiet voice must not be thrown away as silence")
    }

    /// Peak, not average: a sentence with long gaps averages low while its
    /// loudest syllable is unmistakable.
    func testMostlyQuietAudioWithOneLoudMomentIsKept() {
        var samples = Array(repeating: Float(0), count: 16_000)
        samples.replaceSubrange(8_000..<8_100,
                                with: Array(repeating: 0.5, count: 100))
        XCTAssertFalse(AudioSamples.isSilent(samples))
    }

    func testPeakIgnoresSign() {
        XCTAssertEqual(AudioSamples.peak(of: [-0.7, 0.2, -0.1]), 0.7, accuracy: 0.0001)
        XCTAssertEqual(AudioSamples.peak(of: []), 0)
    }

    /// The threshold sits between the two measurements it was chosen from.
    func testTheThresholdIsBetweenSilenceAndSpeech() {
        XCTAssertGreaterThan(AudioSamples.silenceThreshold, 0.00003,
                             "must be above measured digital silence")
        XCTAssertLessThan(AudioSamples.silenceThreshold, 0.01,
                          "must be far below any real speech")
    }
}
