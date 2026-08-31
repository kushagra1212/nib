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
                guard let userData else { return noErr }
                let monitor = Unmanaged<HotkeyMonitor>
                    .fromOpaque(userData).takeUnretainedValue()

                // Which key was pressed. Without this every monitor answers
                // for every hotkey.
                var pressed = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &pressed)
                guard status == noErr, pressed.id == monitor.identifier else {
                    return noErr
                }

                DispatchQueue.main.async { monitor.onFire?() }
                return noErr
            },
            1, &spec, context, &handler
        )
    }
}
