import ApplicationServices
import Foundation

/// Decides whether a focused element should be read at all.
///
/// Separated from the watcher so the rules are testable without a running app,
/// because the cost of getting them wrong is not a missing underline.
enum FieldEligibility {
    /// Roles that hold editable prose.
    static let editableRoles: Set<String> = [
        kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole,
    ]

    /// Subroles that must never be read, whatever their role says.
    ///
    /// A password field is an ordinary AXTextField wearing the secure subrole.
    /// Checking the role alone reads passwords and hands them to the linter,
    /// which is the single worst thing an app that watches your typing can do.
    static let forbiddenSubroles: Set<String> = [
        kAXSecureTextFieldSubrole as String,
    ]

    /// Field names that suggest a secret even when the subrole is absent.
    ///
    /// Web and Electron password inputs frequently expose no subrole at all,
    /// so the label is the only signal left. Deliberately broad: skipping a
    /// field that merely mentions a password costs one missed underline.
    private static let sensitiveHints = [
        "password", "passcode", "passphrase", "secret", "token",
        "api key", "apikey", "private key", "credential", "cvv", "pin",
        "otp", "verification code", "security code", "card number",
    ]

    /// Whether nib may read this element.
    static func mayRead(role: String?, subrole: String?, label: String?) -> Bool {
        guard let role, editableRoles.contains(role) else { return false }
        if let subrole, forbiddenSubroles.contains(subrole) { return false }
        if let label, mentionsSecret(label) { return false }
        return true
    }

    static func mentionsSecret(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return sensitiveHints.contains { lowered.contains($0) }
    }

    /// Reads the labels an element might carry.
    static func label(of element: AXElement) -> String? {
        let candidates = [
            kAXDescriptionAttribute,
            kAXTitleAttribute,
            kAXPlaceholderValueAttribute,
            kAXHelpAttribute,
        ]
        let parts = candidates.compactMap { element.string(for: $0) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
