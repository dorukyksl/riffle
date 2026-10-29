import Cocoa
import XCTest
@testable import Riffle

final class LogTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("riffle-log-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func lines(_ url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func size(_ url: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0 }

    func testTheFileIsMovedAsideWhileRunningAndTwoOldOnesStay() {
        let file = LogFile(folder: folder, limit: 100, kept: 2)
        let line = { (number: Int) in String(format: "line %02d .......", number) }
        for number in 0..<40 { file.append(Data((line(number) + "\n").utf8)) }
        XCTAssertTrue(exists(file.url))
        XCTAssertTrue(exists(file.archive(1)))
        XCTAssertTrue(exists(file.archive(2)))
        XCTAssertFalse(exists(file.archive(3)), "two old files at most")
        for url in [file.url, file.archive(1), file.archive(2)] { XCTAssertLessThan(size(url), 100 + 17, url.lastPathComponent) }
        // Oldest to newest, nothing lost between the files that are kept.
        let kept = lines(file.archive(2)) + lines(file.archive(1)) + lines(file.url)
        XCTAssertEqual(kept, (40 - kept.count..<40).map(line))
        XCTAssertGreaterThan(kept.count, 14)
    }

    func testAWriterFollowsTheFileAnotherOneMovedAside() {
        // Diagnostics runs are separate processes writing the same file.
        let running = LogFile(folder: folder, limit: 1000)
        let other = LogFile(folder: folder, limit: 1000)
        running.append(Data("a\n".utf8))
        other.append(Data("b\n".utf8))
        other.rotate()
        running.append(Data("c\n".utf8))
        other.append(Data("d\n".utf8))
        XCTAssertEqual(lines(running.archive(1)), ["a", "b"])
        XCTAssertEqual(lines(running.url), ["c", "d"])
    }

    func testTheOldFileOfEarlierVersionsBecomesTheFirstOldFile() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let legacy = folder.appendingPathComponent("riffle.old.log")
        try Data("old\n".utf8).write(to: legacy)
        let file = LogFile(folder: folder)
        XCTAssertFalse(exists(legacy))
        XCTAssertEqual(lines(file.archive(1)), ["old"])
        // With old files of its own already, it just goes.
        try Data("older\n".utf8).write(to: legacy)
        _ = LogFile(folder: folder)
        XCTAssertFalse(exists(legacy))
        XCTAssertEqual(lines(file.archive(1)), ["old"])
    }

    func testAppsAreLoggedByTheirBundleIdentifier() {
        XCTAssertEqual(Log.app("com.apple.Safari", pid: 12), "com.apple.Safari")
        XCTAssertEqual(Log.app(nil, pid: 12), "pid 12")
        XCTAssertEqual(Log.app(nil as NSRunningApplication?), "?")
        let current = NSRunningApplication.current
        XCTAssertEqual(Log.app(current), current.bundleIdentifier ?? "pid \(current.processIdentifier)")
    }

    /// No log line in Riffle names an app or a window: names can be personal, titles even more.
    func testNoLogLineCarriesAnAppNameOrATitle() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Riffle", isDirectory: true)
        let personal = try NSRegularExpression(pattern: #"\.(name|appName|localizedName|title|displayTitle|windowTitle)\b"#)
        var checked = 0
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for file in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.split(separator: "\n") where line.contains("Log.info(") || line.contains("Log.warn(") || line.contains("Log.error(") {
                checked += 1
                let text = String(line)
                XCTAssertNil(personal.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                             "\(file.lastPathComponent): \(text.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertGreaterThan(checked, 30)
    }
}
