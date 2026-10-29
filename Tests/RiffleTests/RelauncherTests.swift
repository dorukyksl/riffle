import XCTest
@testable import Riffle

/// Restarting: the new Riffle opens once the old one is gone, and with it the single-instance lock. The script runs here
/// for real, with `touch` standing in for `open` and `sleep` for the old Riffle: nothing is launched.
final class RelauncherTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("riffle-relaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        return process
    }

    func testTheCommandWaitsForThisProcessThenOpensTheApp() {
        let arguments = Relauncher.arguments(opening: "/Applications/Riffle.app", after: 4242)
        XCTAssertEqual(arguments.count, 4)
        XCTAssertEqual(arguments[0], "-c")
        XCTAssertEqual(Array(arguments[2...]), ["/Applications/Riffle.app", "4242"])
        let script = arguments[1]
        XCTAssertTrue(script.contains(#"kill -0 "$1""#), script)
        // At most 100 looks, a tenth of a second apart.
        XCTAssertTrue(script.contains(#"[ "$i" -lt 100 ]"#), script)
        XCTAssertTrue(script.contains("sleep 0.1"), script)
        XCTAssertTrue(script.hasSuffix(#"exec /usr/bin/open "$0""#), script)
        // The app's path is an argument, never part of the script.
        XCTAssertFalse(script.contains("Riffle.app"))
        XCTAssertEqual(Relauncher.arguments(opening: "/A.app", after: 1, patience: 2.5)[1].contains("-lt 25 ]"), true)
    }

    func testTheScriptIsValidShell() throws {
        let check = try run("/bin/sh", ["-n", "-c", Relauncher.arguments(opening: "/Applications/Riffle.app", after: 1)[1]])
        check.waitUntilExit()
        XCTAssertEqual(check.terminationStatus, 0)
    }

    func testTheAppOpensOnlyOnceTheOldProcessHasExited() throws {
        let opened = folder.appendingPathComponent("opened with a space")
        let old = try run("/bin/sleep", ["0.8"])
        let relaunch = try run("/bin/sh", Relauncher.arguments(opening: opened.path, after: old.processIdentifier, opener: "/usr/bin/touch"))
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertTrue(old.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: opened.path), "opened while the old one still ran")
        old.waitUntilExit()
        relaunch.waitUntilExit()
        XCTAssertTrue(FileManager.default.fileExists(atPath: opened.path))
    }

    func testAProcessThatWontQuitIsOnlyWaitedForSoLong() throws {
        let opened = folder.appendingPathComponent("opened")
        let old = try run("/bin/sleep", ["30"])
        defer { old.terminate() }
        let started = Date()
        let relaunch = try run("/bin/sh", Relauncher.arguments(opening: opened.path, after: old.processIdentifier, opener: "/usr/bin/touch",
                                                               patience: 0.3))
        relaunch.waitUntilExit()
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertTrue(old.isRunning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: opened.path))
    }
}
