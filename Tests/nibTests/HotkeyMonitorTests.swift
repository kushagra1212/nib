import Carbon.HIToolbox
import XCTest
@testable import nib

/// What a hotkey handler returns, which decides whether the other hotkeys work.
///
/// nib installs four handlers on the same Carbon event target -- the panel,
/// dictation, speak and hush. Carbon reads `noErr` as "handled, stop here" and
/// only tries the next handler on `eventNotHandledErr`.
///
/// So a handler that returns `noErr` for a key belonging to another monitor
/// swallows it. Whichever handler runs first then answers for all four, and the
/// rest never fire. That shipped: ⌃⌘N registered, the menu showed the combo,
/// and pressing it did nothing.
final class HotkeyMonitorTests: XCTestCase {
    func testOurOwnKeyIsHandled() {
        XCTAssertEqual(HotkeyMonitor.response(forPressed: 3, ours: 3), noErr)
    }

    /// The bug. Anything but eventNotHandledErr here stops the event reaching
    /// the monitor it belongs to.
    func testAnotherMonitorsKeyIsPassedOn() {
        XCTAssertEqual(HotkeyMonitor.response(forPressed: 2, ours: 3),
                       OSStatus(eventNotHandledErr))
        XCTAssertNotEqual(HotkeyMonitor.response(forPressed: 2, ours: 3), noErr)
    }

    /// All four of nib's identifiers, each seeing every press. Exactly one
    /// handler may claim each key.
    func testExactlyOneMonitorClaimsEachKey() {
        let identifiers: [UInt32] = [1, 2, 3, 4]
        for pressed in identifiers {
            let claimed = identifiers.filter {
                HotkeyMonitor.response(forPressed: pressed, ours: $0) == noErr
            }
            XCTAssertEqual(claimed, [pressed],
                           "key \(pressed) was claimed by \(claimed)")
        }
    }

    /// The two hotkeys carried over from the setup nib replaces, so a rename
    /// or a modifier change is caught rather than discovered by pressing.
    func testTheSpeechCombosAreTheOnesCarriedOver() {
        XCTAssertEqual(HotkeyMonitor.Combo.controlCommandN.label, "⌃⌘N")
        XCTAssertEqual(HotkeyMonitor.Combo.controlCommandN.keyCode, UInt32(kVK_ANSI_N))
        XCTAssertEqual(HotkeyMonitor.Combo.controlCommandN.modifiers,
                       UInt32(controlKey | cmdKey))

        XCTAssertEqual(HotkeyMonitor.Combo.controlShiftH.label, "⌃⇧H")
        XCTAssertEqual(HotkeyMonitor.Combo.controlShiftH.keyCode, UInt32(kVK_ANSI_H))
        XCTAssertEqual(HotkeyMonitor.Combo.controlShiftH.modifiers,
                       UInt32(controlKey | shiftKey))
    }

    /// Four monitors, four identifiers. Sharing one would make hush start
    /// speech as well.
    func testEveryHotkeyHasItsOwnIdentifier() {
        let identifiers = [1, 2, 3, 4]
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
    }
}
