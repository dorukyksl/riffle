import Cocoa
import os

/// Unified logging (visible in Console.app) plus a small rolling file at ~/Library/Logs/Riffle/riffle.log that is easy
/// to read when something misbehaves. Nothing personal goes into either: never a window title, and an app by its bundle
/// identifier, never its name (`Log.app`). That's what lets messages be public in the unified log.
enum Log {
    static var echoToStdout = false

    private static let osLog = Logger(subsystem: "com.dorukyuksel.riffle", category: "riffle")
    private static let queue = DispatchQueue(label: "riffle.log", qos: .utility)
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Riffle", isDirectory: true)
    /// The log being written; the older ones beside it are riffle.1.log and riffle.2.log.
    static var fileURL: URL { folder.appendingPathComponent(LogFile.name + ".log") }
    /// Used on `queue` only.
    private static let file = LogFile(folder: folder)

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func info(_ message: @autoclosure () -> String) { write("INFO", message()) }
    static func warn(_ message: @autoclosure () -> String) { write("WARN", message()) }
    static func error(_ message: @autoclosure () -> String) { write("ERROR", message()) }

    /// An app as the log names it: its bundle identifier (a name can be personal, or in some language), else its pid.
    static func app(_ bundleID: String?, pid: pid_t) -> String {
        bundleID ?? "pid \(pid)"
    }

    static func app(_ running: NSRunningApplication?) -> String {
        running.map { app($0.bundleIdentifier, pid: $0.processIdentifier) } ?? "?"
    }

    private static func write(_ level: String, _ message: String) {
        // Public: no message carries a title or an app's name (see above), and redacted lines would be no use.
        osLog.log("\(level, privacy: .public) \(message, privacy: .public)")
        let now = Date()
        queue.async {
            let line = "\(formatter.string(from: now)) [\(level)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if echoToStdout { FileHandle.standardOutput.write(data) }
            file.append(data)
        }
    }

    /// Blocks until queued lines are written. Used before `exit` in diagnostics mode.
    static func flush() {
        queue.sync {}
    }
}

/// The log file, appended to by every Riffle process (diagnostics runs write to it too) and moved aside once it passes
/// `limit` bytes, while Riffle runs: riffle.log becomes riffle.1.log, that one riffle.2.log, and the oldest goes. Not
/// thread-safe: `Log` uses it from its queue.
final class LogFile {
    static let name = "riffle"

    let folder: URL
    let limit: Int
    /// Old files kept beside the current one.
    let kept: Int
    private var descriptor: Int32 = -1
    /// The file the descriptor writes to: when another process moves it aside, the next line goes to the new one.
    private var openedFile: ino_t = 0

    var url: URL { folder.appendingPathComponent(LogFile.name + ".log") }

    func archive(_ number: Int) -> URL { folder.appendingPathComponent("\(LogFile.name).\(number).log") }

    init(folder: URL, limit: Int = 1_000_000, kept: Int = 2) {
        self.folder = folder
        self.limit = limit
        self.kept = max(1, kept)
        // The one old file of versions before this one becomes the first of the old files.
        let legacy = folder.appendingPathComponent(LogFile.name + ".old.log")
        if FileManager.default.fileExists(atPath: legacy.path) {
            if FileManager.default.fileExists(atPath: archive(1).path) {
                try? FileManager.default.removeItem(at: legacy)
            } else {
                try? FileManager.default.moveItem(at: legacy, to: archive(1))
            }
        }
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    func append(_ data: Data) {
        guard openIfNeeded() else { return }
        _ = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        var info = stat()
        if fstat(descriptor, &info) == 0, Int(info.st_size) >= limit { rotate() }
    }

    /// Moves the current file aside, and the old ones one further; the next line starts a new file.
    func rotate() {
        let files = FileManager.default
        try? files.removeItem(at: archive(kept))
        for number in stride(from: kept - 1, through: 1, by: -1) {
            try? files.moveItem(at: archive(number), to: archive(number + 1))
        }
        try? files.moveItem(at: url, to: archive(1))
        closeFile()
    }

    private func openIfNeeded() -> Bool {
        var onDisk = stat()
        if descriptor >= 0, stat(url.path, &onDisk) == 0, onDisk.st_ino == openedFile { return true }
        closeFile()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // O_APPEND: each line lands at the end, whoever else is writing.
        let opened = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard opened >= 0 else { return false }
        var info = stat()
        fstat(opened, &info)
        descriptor = opened
        openedFile = info.st_ino
        return true
    }

    private func closeFile() {
        if descriptor >= 0 { close(descriptor) }
        descriptor = -1
    }
}
