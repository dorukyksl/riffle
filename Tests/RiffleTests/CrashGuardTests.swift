import Foundation
import XCTest

/// The crash guard in a child process (CrashGuardProbe), which hands it a stand-in for the call that switches ⌘⇥ back on
/// and then crashes. The probe's crashes end with _exit(100 + signal) once the handler has done its work, so they leave
/// no crash report; production's own ending is checked by reading the state it leaves. Only
/// `testProductionCrashGoesDownWithItsOwnSignal` really crashes, and only with RIFFLE_REAL_CRASH_TESTS=1 (CI sets it).
final class CrashGuardTests: XCTestCase {
    private struct Ending {
        /// One byte per hot key the stand-in was asked to switch: its id, plus 0x80 for "on".
        let calls: [UInt8]
        /// What the probe wrote to stderr.
        let report: [String]
        let reason: Process.TerminationReason
        let status: Int32
        let seconds: TimeInterval
    }

    private struct ProbeMissing: Error {
        let path: String
    }

    /// ⌘⇥ (1) and ⌘⇧⇥ (2) switched on, once each.
    private let bothSwitchedOn: [UInt8] = [0x81, 0x82]

    private func probe(_ mode: String) throws -> Ending {
        // Built next to the test bundle (the test target depends on it), whichever build system laid them out.
        let url = Bundle(for: CrashGuardTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("CrashGuardProbe")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw ProbeMissing(path: url.path) }
        let process = Process()
        process.executableURL = url
        process.arguments = [mode]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let start = Date()
        try process.run()
        // Both at once: a pipe that fills up while the other is being read would stall the probe.
        var report = Data()
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global().async {
            report = errors.fileHandleForReading.readDataToEndOfFile()
            reading.leave()
        }
        let calls = output.fileHandleForReading.readDataToEndOfFile()
        reading.wait()
        process.waitUntilExit()
        return Ending(calls: [UInt8](calls), report: String(decoding: report, as: UTF8.self).split(separator: "\n").map(String.init),
                      reason: process.terminationReason, status: process.terminationStatus, seconds: Date().timeIntervalSince(start))
    }

    /// The probe in a "terminate" mode: once it's ready, `signals` go to it, each `at` seconds after the first, as long as
    /// it runs. Only ever to this test's own child. `seconds` runs from the first signal to the probe's end.
    private func probe(_ mode: String, sending signals: [(at: TimeInterval, signal: Int32)]) throws -> Ending {
        let url = Bundle(for: CrashGuardTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("CrashGuardProbe")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw ProbeMissing(path: url.path) }
        let process = Process()
        process.executableURL = url
        process.arguments = [mode]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let ended = DispatchSemaphore(value: 0)
        var endedAt = Date.distantFuture
        process.terminationHandler = { _ in
            endedAt = Date()
            ended.signal()
        }
        try process.run()
        var calls = Data(), report = Data()
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global().async {
            calls = output.fileHandleForReading.readDataToEndOfFile()
            reading.leave()
        }
        while !String(decoding: report, as: UTF8.self).contains("ready\n") {
            let chunk = errors.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            report.append(chunk)
        }
        reading.enter()
        DispatchQueue.global().async {
            report.append(errors.fileHandleForReading.readDataToEndOfFile())
            reading.leave()
        }
        // A moment for its dispatch sources to be armed: a signal before that would only be ignored.
        Thread.sleep(forTimeInterval: 0.3)
        let start = Date()
        for (at, signal) in signals {
            Thread.sleep(until: start.addingTimeInterval(at))
            guard process.isRunning else { break }
            kill(process.processIdentifier, signal)
        }
        reading.wait()
        ended.wait()
        return Ending(calls: [UInt8](calls), report: String(decoding: report, as: UTF8.self).split(separator: "\n").map(String.init),
                      reason: process.terminationReason, status: process.terminationStatus, seconds: endedAt.timeIntervalSince(start))
    }

    /// The handler did everything it does in production, then the probe's ending reported which signal it was.
    private func assertHandled(_ ending: Ending, _ signals: Set<Int32>, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(ending.reason, .exit, file: file, line: line)
        XCTAssertTrue(signals.map { 100 + $0 }.contains(ending.status), "ended with \(ending.status)", file: file, line: line)
    }

    func testHandlersAreInstalledOnTheAlternateStack() throws {
        let ending = try probe("installation")
        XCTAssertEqual(ending.reason, .exit)
        XCTAssertEqual(ending.status, 0)
        let signals = Set((ending.report.first { $0.hasPrefix("signals ") } ?? "").split(separator: " ").dropFirst().compactMap { Int32($0) })
        XCTAssertEqual(signals, [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE, SIGSYS])
        XCTAssertTrue(ending.report.contains("altstack yes"))
        XCTAssertTrue(ending.report.contains("exceptions yes"))
    }

    func testProductionResetsTheSignalAndRaisesItAgain() throws {
        // The installed handler called directly with SIGSEGV blocked: ⌘⇥ back on, the alarm armed, SIGSEGV back to its
        // default action and pending, which in a real crash ends the process the moment the handler returns.
        let ending = try probe("production-ending")
        XCTAssertEqual(ending.calls, bothSwitchedOn)
        XCTAssertTrue(ending.report.contains("action default"), "\(ending.report)")
        XCTAssertTrue(ending.report.contains("pending yes"), "\(ending.report)")
        XCTAssertTrue(ending.report.contains("alarm 2") || ending.report.contains("alarm 1"), "\(ending.report)")
        XCTAssertEqual(ending.reason, .exit)
        XCTAssertEqual(ending.status, 0)
    }

    func testBadMemoryAccess() throws {
        let ending = try probe("bad-access")
        XCTAssertEqual(ending.calls, bothSwitchedOn)
        assertHandled(ending, [SIGSEGV, SIGBUS])
    }

    func testSwiftRuntimeTrap() throws {
        let ending = try probe("swift-trap")
        XCTAssertEqual(ending.calls, bothSwitchedOn)
        // A trap is `brk` on Apple silicon (SIGTRAP) and `ud2` on Intel (SIGILL).
        assertHandled(ending, [SIGTRAP, SIGILL])
    }

    func testUncaughtObjectiveCExceptionRestoresOnceThenAborts() throws {
        // The exception handler switches ⌘⇥ back on; abort()'s SIGABRT that follows mustn't call the WindowServer again.
        let ending = try probe("exception")
        XCTAssertEqual(ending.calls, bothSwitchedOn)
        assertHandled(ending, [SIGABRT])
    }

    func testStackOverflowRunsOnTheAlternateStack() throws {
        let ending = try probe("stack-overflow")
        XCTAssertEqual(ending.calls, bothSwitchedOn)
        assertHandled(ending, [SIGSEGV, SIGBUS])
    }

    func testAWindowServerThatNeverAnswersIsCutShortByTheAlarm() throws {
        // SIGALRM ends a process without a crash report.
        let ending = try probe("hang")
        XCTAssertEqual(ending.calls, [0x01])
        XCTAssertEqual(ending.reason, .uncaughtSignal)
        XCTAssertEqual(ending.status, SIGALRM)
        XCTAssertGreaterThanOrEqual(ending.seconds, 1.5)
        XCTAssertLessThan(ending.seconds, 8)
    }

    func testExitWhileOwningRestores() throws {
        let ending = try probe("exit")
        XCTAssertEqual(ending.calls, bothSwitchedOn)
        XCTAssertEqual(ending.reason, .exit)
        XCTAssertEqual(ending.status, 3)
    }

    func testNothingIsTouchedOnceDisarmed() throws {
        let ending = try probe("disarmed")
        XCTAssertEqual(ending.calls, [])
        XCTAssertEqual(ending.reason, .exit)
        XCTAssertEqual(ending.status, 3)
    }

    // MARK: - Quitting signals (the probe's grace period is 0.5 s; the app's is `CrashGuard.terminationGrace`)

    func testAQuittingSignalQuitsTheOrderlyWay() throws {
        // Asked once, the main thread quits with exit(), whose handler gives ⌘⇥ back: the fallback never runs.
        let ending = try probe("terminate", sending: [(0, SIGTERM)])
        XCTAssertEqual(ending.report.filter { $0 == "asked to quit" }.count, 1)
        XCTAssertEqual(ending.reason, .exit)
        XCTAssertEqual(ending.status, 0)
        XCTAssertEqual(ending.calls, bothSwitchedOn)
    }

    func testAStuckMainThreadStillEndsOnceTheGracePeriodIsOver() throws {
        let ending = try probe("terminate-stuck", sending: [(0, SIGTERM)])
        XCTAssertEqual(ending.report.filter { $0 == "asked to quit" }.count, 1)
        XCTAssertEqual(ending.calls, bothSwitchedOn)
        XCTAssertEqual(ending.reason, .exit)
        XCTAssertEqual(ending.status, 128 + SIGTERM)
        XCTAssertGreaterThanOrEqual(ending.seconds, 0.4)
        XCTAssertLessThan(ending.seconds, 2.5)
    }

    func testEveryQuittingSignalIsHandled() throws {
        for signal in [SIGINT, SIGHUP, SIGQUIT] {
            let ending = try probe("terminate-stuck", sending: [(0, signal)])
            XCTAssertEqual(ending.calls, bothSwitchedOn, "signal \(signal)")
            XCTAssertEqual(ending.reason, .exit, "signal \(signal)")
            XCTAssertEqual(ending.status, 128 + signal, "signal \(signal)")
        }
    }

    func testMoreSignalsNeitherAskAgainNorBuyTime() throws {
        // Signals keep coming for 1.2 s, well past the grace period: it still ends half a second after the first one.
        let ending = try probe("terminate-stuck", sending: [(0, SIGINT), (0.2, SIGINT), (0.4, SIGTERM), (0.6, SIGHUP), (0.8, SIGTERM),
                                                            (1.0, SIGINT), (1.2, SIGTERM)])
        XCTAssertEqual(ending.report.filter { $0 == "asked to quit" }.count, 1)
        XCTAssertEqual(ending.calls, bothSwitchedOn)
        XCTAssertEqual(ending.status, 128 + SIGINT)
        XCTAssertLessThan(ending.seconds, 1.0)
    }

    func testAWindowServerThatNeverAnswersDoesNotKeepAStuckAppAlive() throws {
        // After the grace period, giving ⌘⇥ back hangs: the alarm ends the process two seconds later.
        let ending = try probe("terminate-stuck-hang", sending: [(0, SIGTERM)])
        XCTAssertEqual(ending.calls, [0x01])
        XCTAssertEqual(ending.reason, .uncaughtSignal)
        XCTAssertEqual(ending.status, SIGALRM)
        XCTAssertGreaterThanOrEqual(ending.seconds, 1.9)
        XCTAssertLessThan(ending.seconds, 6)
    }

    func testProductionCrashGoesDownWithItsOwnSignal() throws {
        // A real crash leaves a crash report, so it runs only where that's harmless.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RIFFLE_REAL_CRASH_TESTS"] == "1",
                          "set RIFFLE_REAL_CRASH_TESTS=1 to crash for real (CI does)")
        let ending = try probe("production-crash")
        XCTAssertEqual(ending.calls, bothSwitchedOn)
        XCTAssertEqual(ending.reason, .uncaughtSignal)
        XCTAssertTrue([SIGSEGV, SIGBUS].contains(ending.status), "died of signal \(ending.status)")
    }
}
