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
    }

    private var handler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var onFire: (() -> Void)?

    private(set) var active: Combo?

    /// Registers the first combo that the system will accept.
    @discardableResult
    func start(preferring combos: [Combo] = [.optionSpace, .commandShiftG],
               onFire: @escaping () -> Void) -> Combo? {
        self.onFire = onFire
        installHandlerIfNeeded()

        for combo in combos {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x6E696220), id: 1) // 'nib '
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
            { _, _, userData in
                guard let userData else { return noErr }
                let monitor = Unmanaged<HotkeyMonitor>
                    .fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { monitor.onFire?() }
                return noErr
            },
            1, &spec, context, &handler
        )
    }
}
