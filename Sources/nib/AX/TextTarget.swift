import AppKit
import ApplicationServices

/// A piece of text captured from another app, plus what it takes to put it back.
struct TextTarget {
    enum Source {
        /// Read through the Accessibility API; can be written back in place.
        case accessibility(AXElement)
        /// Read by sending Cmd-C; can only be written back by pasting.
        case clipboard
    }

    let text: String
    /// Range within `text` that was selected, or the whole thing if nothing was.
    let range: NSRange
    let source: Source
    /// True when the user had an actual selection, as opposed to us taking the
    /// whole field. Determines whether a rewrite replaces part or all of it.
    let hadSelection: Bool

    var selectedText: String {
        guard let r = Range(range, in: text) else { return text }
        return String(text[r])
    }
}

/// Reads text out of whatever app currently has focus.
enum TextGrabber {
    /// Attributes worth trying, in order, for the focused element's full text.
    private static let valueAttributes = [
        kAXValueAttribute,
        kAXSelectedTextAttribute,
    ]

    static func grab() -> TextTarget? {
        // Checked before anything else: falling through to the clipboard would
        // send Cmd-C to a password field, which is exactly what the AX guard
        // below exists to prevent.
        if focusIsSensitive() { return nil }
        if let target = grabViaAccessibility() { return target }
        return grabViaClipboard()
    }

    /// Whether the focused element is one nib must not read.
    static func focusIsSensitive() -> Bool {
        guard AXAccess.isTrusted, let element = AXElement.focused else { return false }
        if let subrole = element.string(for: kAXSubroleAttribute),
           FieldEligibility.forbiddenSubroles.contains(subrole) {
            return true
        }
        if let label = FieldEligibility.label(of: element) {
            return FieldEligibility.mentionsSecret(label)
        }
        return false
    }

    static func grabViaAccessibility() -> TextTarget? {
        guard AXAccess.isTrusted, let element = AXElement.focused else { return nil }

        // The hotkey path reads whatever holds focus, so it needs the same
        // guard as the live path: never read a password field.
        guard FieldEligibility.mayRead(
            role: element.role,
            subrole: element.string(for: kAXSubroleAttribute),
            label: FieldEligibility.label(of: element)
        ) else { return nil }

        let selected = element.string(for: kAXSelectedTextAttribute) ?? ""
        if !selected.isEmpty {
            // Prefer the full field so a rewrite can see surrounding context,
            // but fall back to the selection alone if the field will not read.
            if let full = element.string(for: kAXValueAttribute),
               let cfRange = element.range(for: kAXSelectedTextRangeAttribute) {
                let range = NSRange(location: cfRange.location, length: cfRange.length)
                if NSMaxRange(range) <= (full as NSString).length {
                    return TextTarget(text: full, range: range,
                                      source: .accessibility(element), hadSelection: true)
                }
            }
            return TextTarget(text: selected,
                              range: NSRange(location: 0, length: (selected as NSString).length),
                              source: .accessibility(element), hadSelection: true)
        }

        for attribute in valueAttributes {
            guard let text = element.string(for: attribute), !text.isEmpty else { continue }
            return TextTarget(text: text,
                              range: NSRange(location: 0, length: (text as NSString).length),
                              source: .accessibility(element), hadSelection: false)
        }
        return nil
    }

    /// Last resort for apps that expose nothing useful over AX: copy the
    /// selection out with a synthetic Cmd-C.
    static func grabViaClipboard() -> TextTarget? {
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount

        Keystroke.send(key: 8, flags: .maskCommand) // 8 == 'c'

        // Give the frontmost app a moment to service the copy.
        let deadline = Date().addingTimeInterval(0.4)
        while pasteboard.changeCount == before, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        guard pasteboard.changeCount != before,
              let text = pasteboard.string(forType: .string), !text.isEmpty
        else { return nil }

        return TextTarget(text: text,
                          range: NSRange(location: 0, length: (text as NSString).length),
                          source: .clipboard, hadSelection: true)
    }
}

/// Writes replacement text back into the app it came from.
enum TextWriter {
    enum Outcome {
        /// Entered as keystrokes, so the app recorded it and Cmd-Z reverts it.
        case typed
        /// Written through AX. Lands, but the app has no undo entry for it.
        case wroteInPlace
        case pasted
        /// Could not write; the text is on the clipboard for the user to paste.
        case copiedToClipboard
    }

    @discardableResult
    static func replace(_ target: TextTarget, with replacement: String) -> Outcome {
        if case .accessibility(let element) = target.source {
            // Select what is being replaced, then type over it. Typing enters
            // the app's undo stack, so Cmd-Z reverts the change; an AX write
            // changes the text without the app noticing and cannot be undone.
            if selectAll(target, on: element) {
                Keystroke.type(replacement)
                if element.string(for: kAXValueAttribute)?.contains(replacement) == true
                    || target.hadSelection {
                    return .typed
                }
            }

            // Fallbacks for apps that ignore synthetic input. These work, but
            // the edit will not appear in the app's undo history.
            if target.hadSelection, element.isSettable(kAXSelectedTextAttribute),
               element.set(kAXSelectedTextAttribute, to: replacement as CFString) {
                return .wroteInPlace
            }
            if !target.hadSelection, element.isSettable(kAXValueAttribute),
               element.set(kAXValueAttribute, to: replacement as CFString) {
                return .wroteInPlace
            }
        }
        return paste(replacement)
    }

    /// Selects the span that is about to be replaced.
    private static func selectAll(_ target: TextTarget, on element: AXElement) -> Bool {
        var range = CFRange(location: target.range.location, length: target.range.length)
        guard let axRange = AXValueCreate(.cfRange, &range) else { return false }
        return element.set(kAXSelectedTextRangeAttribute, to: axRange)
    }

    /// Puts text on the clipboard and sends Cmd-V.
    ///
    /// The previous clipboard contents are restored afterwards, since silently
    /// eating whatever the user had copied is its own small betrayal.
    private static func paste(_ text: String) -> Outcome {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard AXAccess.isTrusted else { return .copiedToClipboard }
        Keystroke.send(key: 9, flags: .maskCommand) // 9 == 'v'

        if let saved {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                pasteboard.clearContents()
                pasteboard.setString(saved, forType: .string)
            }
        }
        return .pasted
    }
}

enum Keystroke {
    /// Types a string into the frontmost app, replacing any selection.
    ///
    /// The fallback for apps that expose text over AX but refuse writes to it,
    /// which includes most Electron fields. Unlike a clipboard paste this does
    /// not disturb what the user had copied.
    static func type(_ string: String) {
        guard !string.isEmpty else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        var utf16 = Array(string.utf16)

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return }

        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// Posts a synthetic key down/up pair to the frontmost app.
    static func send(key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }
}
