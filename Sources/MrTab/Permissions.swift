import AppKit
import ApplicationServices

enum Permissions {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system Accessibility prompt. Returns the trust state at the time of the call.
    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Trust is granted out-of-process, and there is no notification for it, so poll until it lands.
    static func waitForTrust(interval: TimeInterval = 1.0, then handler: @escaping () -> Void) {
        if isTrusted {
            handler()
            return
        }
        Log.write("not trusted yet; polling for Accessibility grant")
        var polls = 0
        let timer = Timer(timeInterval: interval, repeats: true) { timer in
            guard isTrusted else {
                polls += 1
                // A grant that is toggled on but never observed here means TCC is holding a
                // stale entry for a previous build of the binary.
                if polls % 10 == 0 { Log.write("still not trusted after \(polls) polls") }
                return
            }
            timer.invalidate()
            handler()
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}
