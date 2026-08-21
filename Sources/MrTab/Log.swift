import Foundation

/// Appends to ~/Library/Logs/MrTab.log.
///
/// An agent app has no console and no window to report into, and the two things most likely to
/// go wrong — Accessibility trust and hot key registration — both fail silently. This makes them
/// visible.
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/MrTab.log")

    private static let queue = DispatchQueue(label: "dev.mrtab.log")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
