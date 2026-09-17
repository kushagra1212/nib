import Foundation
import ServiceManagement

/// Starting nib when you log in.
///
/// `SMAppService` registers the bundle itself, so there is no helper target and
/// no plist to write into `~/Library/LaunchAgents`. The entry appears in System
/// Settings under General > Login Items, where it can be turned off without
/// coming back here -- which is why the menu reads the live status rather than
/// remembering what it was last told.
enum LoginItem {
    enum State {
        case on
        case off
        /// The user switched it off in System Settings. macOS will not let the
        /// app switch it back on; only they can.
        case blockedBySystemSettings
        case unsupported
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .notRegistered, .notFound: return .off
        case .requiresApproval: return .blockedBySystemSettings
        @unknown default: return .unsupported
        }
    }

    static var isEnabled: Bool { state == .on }

    /// Turns launch-at-login on or off. Returns what went wrong, if anything.
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                // Registering twice throws rather than being a no-op.
                guard SMAppService.mainApp.status != .enabled else { return nil }
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.write("login item set to \(enabled), status now \(state)")
            return nil
        } catch {
            Log.write("login item change failed: \(error)")
            return explain(error)
        }
    }

    /// Opens the pane where a blocked login item can be re-approved.
    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func explain(_ error: Error) -> String {
        // The common failure is not a permission problem: an app in Downloads
        // or a mounted disk image cannot be a login item, and the error alone
        // does not say so.
        let path = Bundle.main.bundleURL.path
        if !path.hasPrefix("/Applications") {
            return "nib is at \(path).\n\n"
                + "macOS only starts apps at login from /Applications. "
                + "Move nib there and try again."
        }
        return (error as NSError).localizedDescription
    }
}
