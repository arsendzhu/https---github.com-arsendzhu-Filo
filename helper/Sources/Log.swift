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
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Filo")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("helper.log")
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
