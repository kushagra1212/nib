import Carbon.HIToolbox
import XCTest
@testable import nib

/// Hotkeys coming back after the machine sleeps.
///
/// Reported as "I closed my laptop, logged in again, and nothing works".
/// nib was running, had been for six hours, and was still polling focus the
/// whole time -- so it was awake and still had Accessibility. Every one of
/// ⌥Space, ⌃⌥D, ⌃⌘N and ⌃⇧H was dead. Restarting nib brought all four back
/// immediately, which is what identified the Carbon registration as the thing
/// lost rather than the permission or the key press.
///
/// Focus tracking survived because it is a timer nib owns. The hotkeys did not
/// because they live in the window server, and it does not hand them back.
final class HotkeyWakeTests: XCTestCase {

    /// The keys are re-registered from `active`, so a monitor that never
    /// started has nothing to restore -- and must not quietly take one now.
    func testAMonitorThatNeverStartedRestoresNothing() {
        let monitor = HotkeyMonitor(identifier: 90)
        XCTAssertNil(monitor.active)
        XCTAssertNil(monitor.reregister())
        XCTAssertNil(monitor.active)
    }

    /// Registering, losing it, and getting the same combination back.
    ///
    /// A rare combination so the test cannot collide with a real hotkey on
    /// whatever machine it runs on.
    func testARegisteredKeyComesBackAsItself() throws {
        let monitor = HotkeyMonitor(identifier: 91)
        let obscure = HotkeyMonitor.Combo(
            keyCode: UInt32(kVK_ANSI_8),
            modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey),
            label: "⌃⌥⇧⌘8")

        guard let registered = monitor.start(preferring: [obscure], onFire: {})
        else { throw XCTSkip("the system refused the test combination") }
        XCTAssertEqual(registered.label, obscure.label)

        let restored = monitor.reregister()
        XCTAssertEqual(restored?.label, obscure.label)
        XCTAssertEqual(monitor.active?.label, obscure.label)
        XCTAssertEqual(monitor.active?.keyCode, obscure.keyCode)
        XCTAssertEqual(monitor.active?.modifiers, obscure.modifiers)

        monitor.stop()
    }

    /// Twice in a row. A lid close usually delivers both didWake and
    /// sessionDidBecomeActive, so re-registering happens twice and the second
    /// must not undo the first.
    func testReregisteringTwiceIsHarmless() throws {
        let monitor = HotkeyMonitor(identifier: 92)
        let obscure = HotkeyMonitor.Combo(
            keyCode: UInt32(kVK_ANSI_9),
            modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey),
            label: "⌃⌥⇧⌘9")

        guard monitor.start(preferring: [obscure], onFire: {}) != nil
        else { throw XCTSkip("the system refused the test combination") }

        XCTAssertNotNil(monitor.reregister())
        XCTAssertNotNil(monitor.reregister())
        XCTAssertEqual(monitor.active?.label, obscure.label)

        monitor.stop()
    }

    /// After stopping there is nothing to bring back. Waking must not revive a
    /// hotkey that was deliberately released.
    func testAStoppedMonitorStaysStopped() throws {
        let monitor = HotkeyMonitor(identifier: 93)
        let obscure = HotkeyMonitor.Combo(
            keyCode: UInt32(kVK_ANSI_7),
            modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey),
            label: "⌃⌥⇧⌘7")

        guard monitor.start(preferring: [obscure], onFire: {}) != nil
        else { throw XCTSkip("the system refused the test combination") }
        monitor.stop()

        XCTAssertNil(monitor.reregister())
        XCTAssertNil(monitor.active)
    }

    /// All four keep their own identity through the round trip. Sharing one
    /// would make a single press fire several actions -- the bug fixed earlier
    /// in `HotkeyMonitorTests`, which re-registration must not reintroduce.
    func testTheFourMonitorsKeepTheirOwnIdentifiers() {
        let identifiers: [UInt32] = [1, 2, 3, 4]
        for pressed in identifiers {
            let claimed = identifiers.filter {
                HotkeyMonitor.response(forPressed: pressed, ours: $0) == noErr
            }
            XCTAssertEqual(claimed, [pressed])
        }
    }
}
