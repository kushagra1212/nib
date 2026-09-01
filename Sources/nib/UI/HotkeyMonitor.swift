import AppKit
import Carbon.HIToolbox

/// Registers a system-wide hotkey.
///
/// Uses Carbon's RegisterEventHotKey rather than a CGEventTap: it needs no
/// Accessibility permission, so the hotkey keeps working even before the user
/// has granted anything, and it will not silently stop when macOS disables a
/// slow event tap.
final class HotkeyMonitor {
    struct Combo {
        let keyCode: UInt32
        let modifiers: UInt32
        let label: String

        /// Option-Space. Chosen over Cmd-Space (Spotlight) and Ctrl-Space
        /// (input source switching).
        static let optionSpace = Combo(
            keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), label: "⌥Space"
        )

        /// Fallback if the preferred combo is already taken, commonly by Alfred.
        static let commandShiftG = Combo(
            keyCode: UInt32(kVK_ANSI_G),
            modifiers: UInt32(cmdKey | shiftKey),
            label: "⌘⇧G"
        )

        /// Dictation. Awkward to press and owned by nothing.
        ///
        /// ⌘E was the obvious choice and is a trap: RegisterEventHotKey takes a
        /// combination system-wide, and ⌘E is Eject in the Finder and "Use
        /// Selection for Find" in every standard text view. Dictation is not
        /// worth losing both everywhere.
        static let controlOptionD = Combo(
            keyCode: UInt32(kVK_ANSI_D),
            modifiers: UInt32(controlKey | optionKey),
            label: "⌃⌥D"
        )

        /// Speak the selection. Carried over unchanged from the setup nib
        /// replaces, so the keys people already have in their fingers still
        /// work after the Node server is gone.
        static let controlCommandN = Combo(
            keyCode: UInt32(kVK_ANSI_N),
            modifiers: UInt32(controlKey | cmdKey),
            label: "⌃⌘N"
        )

        /// Stop speaking. Separate from the toggle on purpose: the reason to
        /// reach for it is that something is talking and you want it to stop,
        /// and at that moment a key that might also start speech is wrong.
        static let controlShiftH = Combo(
            keyCode: UInt32(kVK_ANSI_H),
            modifiers: UInt32(controlKey | shiftKey),
            label: "⌃⇧H"
        )
    }

    private var handler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var onFire: (() -> Void)?

    /// Distinguishes this monitor's hotkey from any other nib registers.
    ///
    /// Carbon delivers every hotkey press to every installed handler, so
    /// without an identity to compare against, a second monitor fires for the
    /// first one's key as well -- pressing the panel hotkey would also start a
    /// dictation. The handler now checks this before firing.
    private let identifier: UInt32

    init(identifier: UInt32 = 1) {
        self.identifier = identifier
    }

    private(set) var active: Combo?

    /// Registers the first combo that the system will accept.
    @discardableResult
    func start(preferring combos: [Combo] = [.optionSpace, .commandShiftG],
               onFire: @escaping () -> Void) -> Combo? {
        self.onFire = onFire
        installHandlerIfNeeded()

        for combo in combos {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x6E696220), // 'nib '
                                   id: identifier)
            let status = RegisterEventHotKey(
                combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref
            )
            if status == noErr, let ref {
                hotKey = ref
                active = combo
                return combo
            }
        }
        return nil
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        active = nil
    }

    /// What a handler must return for a press with this id.
    ///
    /// Pulled out of the C callback so it can be tested. Getting it wrong does
    /// not fail visibly: the hotkey registers, the menu shows its combo, and
    /// pressing it does nothing at all.
    static func response(forPressed pressed: UInt32,
                         ours identifier: UInt32) -> OSStatus {
        pressed == identifier ? noErr : OSStatus(eventNotHandledErr)
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                // Not ours means not handled, and the difference matters.
                //
                // Carbon reads noErr as "handled, stop here" and only passes
                // the event to the next handler on eventNotHandledErr. Every
                // monitor installs a handler on the same target, so returning
                // noErr for a key belonging to another monitor swallows it:
                // whichever handler runs first answers for all four hotkeys,
                // and the other three never fire.
                //
                // That is exactly how ⌃⌘N and ⌃⇧H came to register
                // successfully and do nothing.
                let notOurs = OSStatus(eventNotHandledErr)
                guard let userData else { return notOurs }
                let monitor = Unmanaged<HotkeyMonitor>
                    .fromOpaque(userData).takeUnretainedValue()

                // Which key was pressed. Without this every monitor answers
                // for every hotkey.
                var pressed = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &pressed)
                guard status == noErr else { return notOurs }
                guard HotkeyMonitor.response(forPressed: pressed.id,
                                             ours: monitor.identifier) == noErr else {
                    return notOurs
                }

                DispatchQueue.main.async { monitor.onFire?() }
                return noErr
            },
            1, &spec, context, &handler
        )
    }
}
