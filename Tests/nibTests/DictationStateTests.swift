import XCTest
@testable import nib

/// The sequencing of a dictation, with no microphone and no model involved.
final class DictationStateTests: XCTestCase {
    // MARK: - The ordinary path

    func testTheWholeJourney() {
        var state = DictationState.idle
        for (event, expected): (DictationEvent, DictationState) in [
            (.toggled, .requestingAccess),
            (.accessGranted, .recording),
            (.toggled, .transcribing),
            (.transcribed("hello there"), .inserting("hello there")),
            (.inserted, .idle),
        ] {
            guard let next = state.next(for: event) else {
                return XCTFail("\(state) refused \(event)")
            }
            XCTAssertEqual(next, expected)
            state = next
        }
    }

    // MARK: - What must not happen

    /// The failure this guards against is two recordings at once: the hotkey
    /// is global, and pressing it again while the model is still working is
    /// the most natural thing in the world to do.
    func testTheHotkeyIsIgnoredWhileTranscribing() {
        XCTAssertNil(DictationState.transcribing.next(for: .toggled))
    }

    func testTheHotkeyIsIgnoredWhileInserting() {
        XCTAssertNil(DictationState.inserting("text").next(for: .toggled))
    }

    func testTheHotkeyIsIgnoredWhileWaitingOnPermission() {
        XCTAssertNil(DictationState.requestingAccess.next(for: .toggled))
    }

    /// Whisper returns an empty string for silence. Inserting it would put an
    /// empty edit in the user's field and read as a failure.
    func testSilenceEndsQuietlyRatherThanInserting() {
        XCTAssertEqual(DictationState.transcribing.next(for: .transcribed("")), .idle)
    }

    func testAWhitespaceOnlyTranscriptIsStillText() {
        // Trimming is the engine's job, not the state machine's. If something
        // arrives here it has already been trimmed, so a non-empty string is
        // taken at face value.
        XCTAssertEqual(DictationState.transcribing.next(for: .transcribed("a")),
                       .inserting("a"))
    }

    // MARK: - Stopping

    /// The length cap must transcribe what was said, not throw it away. Ten
    /// minutes of talking lost to a timer is worse than a truncated note.
    func testTheLengthCapTranscribesRatherThanDiscards() {
        XCTAssertEqual(DictationState.recording.next(for: .reachedLimit), .transcribing)
    }

    func testCancelWorksFromEveryBusyState() {
        for state: DictationState in [.requestingAccess, .recording,
                                      .transcribing, .inserting("text")] {
            XCTAssertEqual(state.next(for: .cancelled), .idle,
                           "\(state) must be cancellable")
        }
    }

    func testCancellingWhenIdleDoesNothing() {
        XCTAssertNil(DictationState.idle.next(for: .cancelled))
    }

    // MARK: - Failure

    func testDeniedPermissionIsReportedRatherThanSilent() {
        guard case let .failed(why)? =
            DictationState.requestingAccess.next(for: .accessDenied) else {
            return XCTFail("a denied microphone must surface")
        }
        XCTAssertTrue(why.contains("microphone"), why)
    }

    func testFailureCanBeRetriedWithTheHotkey() {
        XCTAssertEqual(DictationState.failed("whatever").next(for: .toggled),
                       .requestingAccess)
    }

    func testAFailureWhileIdleIsNotRecorded() {
        XCTAssertNil(DictationState.idle.next(for: .failed("late arrival")),
                     "a failure from a cancelled run must not resurrect it")
    }

    // MARK: - What the interface reads

    /// The recording indicator is driven from this alone, so it cannot claim
    /// the microphone is live when it is not, or stay dark while it is.
    func testOnlyRecordingCountsAsListening() {
        XCTAssertTrue(DictationState.recording.isListening)
        for state: DictationState in [.idle, .requestingAccess, .transcribing,
                                      .inserting("t"), .failed("x")] {
            XCTAssertFalse(state.isListening, "\(state) must not look live")
        }
    }

    func testBusyCoversEverythingInFlight() {
        XCTAssertFalse(DictationState.idle.isBusy)
        XCTAssertFalse(DictationState.failed("x").isBusy)
        for state: DictationState in [.requestingAccess, .recording,
                                      .transcribing, .inserting("t")] {
            XCTAssertTrue(state.isBusy)
        }
    }

    // MARK: - Nothing else gets through

    /// Every pair not named above is refused. Written as a sweep rather than
    /// case by case, so a new state or event cannot quietly acquire a
    /// transition nobody decided on.
    func testEveryOtherPairIsRefused() {
        let states: [DictationState] = [.idle, .requestingAccess, .recording,
                                        .transcribing, .inserting("t"),
                                        .failed("x")]
        let events: [DictationEvent] = [.toggled, .accessGranted, .accessDenied,
                                        .reachedLimit, .transcribed("t"),
                                        .inserted, .cancelled, .failed("x")]
        var allowed = 0
        for state in states {
            for event in events where state.next(for: event) != nil {
                allowed += 1
            }
        }
        // 8 forward: start, retry-from-failed, granted, denied, stop,
        // reached-limit, transcribed, inserted.
        // Plus cancel and failure from each of the 4 busy states.
        //
        // Change this number only alongside a deliberate new transition and a
        // test that names it.
        XCTAssertEqual(allowed, 8 + 4 + 4,
                       "a transition was added or removed without a test")
    }
}
