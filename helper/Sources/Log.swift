import Foundation

/// Logs to stderr and to ~/Library/Logs/Filo/helper.log (the app launches the
/// helper through `open`, so stderr is otherwise invisible).
enum Log {
    static var verbose = false
    private static var handle: FileHandle?
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func setupFile() {
        var url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Filo/helper.log")
        if let override = ProcessInfo.processInfo.environment["FILO_HELPER_LOG"], !override.isEmpty {
            url = URL(fileURLWithPath: override)      // tests write their log next to themselves, not into ~/Library/Logs
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }

    static func info(_ message: String) {
        let line = "[filo-helper \(formatter.string(from: Date()))] " + message + "\n"
        let data = line.data(using: .utf8)!
        FileHandle.standardError.write(data)
        handle?.write(data)
    }

    static func debug(_ message: String) {
        if verbose { info(message) }
    }
}
