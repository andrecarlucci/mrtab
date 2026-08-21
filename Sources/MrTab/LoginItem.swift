import Foundation
import ServiceManagement

/// Launch-at-login, via the modern `SMAppService` API.
///
/// The registration is tied to the bundle at its current path, so an app that is moved has to be
/// re-registered from its new location.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns nil on success, or a message suitable for showing to the user.
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.write("login item \(enabled ? "registered" : "unregistered")")
            return nil
        } catch {
            Log.write("login item \(enabled ? "register" : "unregister") failed: \(error)")
            return error.localizedDescription
        }
    }
}
