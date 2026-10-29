import CoreFoundation
import XCTest
@testable import Riffle

/// The modifier tap's port is shared between its own thread and the main thread. Plain Mach ports stand in for it: a
/// test never makes a real event tap.
final class ModifierTapTests: XCTestCase {
    private func port() throws -> CFMachPort {
        try XCTUnwrap(CFMachPortCreate(kCFAllocatorDefault, { _, _, _, _ in }, nil, nil))
    }

    func testTheTapIsKeptUntilItsRemoved() throws {
        let monitor = ModifierMonitor()
        XCTAssertFalse(monitor.hasEventTap)
        XCTAssertNil(monitor.tapToReenable())
        let tap = try port()
        monitor.adopt(tap)
        XCTAssertTrue(monitor.hasEventTap)
        XCTAssertTrue(monitor.tapToReenable() === tap)
        monitor.removeEventTap()
        XCTAssertFalse(monitor.hasEventTap)
        XCTAssertNil(monitor.tapToReenable(), "a removed tap is never switched back on")
        XCTAssertFalse(CFMachPortIsValid(tap))
        // Nothing left to remove.
        monitor.removeEventTap()
        XCTAssertFalse(monitor.hasEventTap)
    }

    func testATapThatEndsLateLeavesTheOneAfterItAlone() throws {
        let monitor = ModifierMonitor()
        let first = try port(), second = try port()
        monitor.adopt(first)
        monitor.removeEventTap()
        monitor.adopt(second)
        // The first one's thread only now notices its port is gone.
        XCTAssertFalse(monitor.forgetTap(first))
        XCTAssertTrue(monitor.tapToReenable() === second)
        // The second one ending by itself leaves no tap behind, so a new one can be made.
        XCTAssertTrue(monitor.forgetTap(second))
        XCTAssertFalse(monitor.hasEventTap)
        monitor.removeEventTap()
    }

    func testTheTapsThreadCanLookWhileTheMainThreadReplacesIt() throws {
        let monitor = ModifierMonitor()
        let ports = try (0..<500).map { _ in try port() }
        let done = expectation(description: "the tap's thread looked")
        let thread = Thread {
            for _ in 0..<50_000 {
                if let tap = monitor.tapToReenable() { _ = CFMachPortIsValid(tap) }
            }
            done.fulfill()
        }
        thread.start()
        for _ in 0..<20 {
            for tap in ports {
                monitor.adopt(tap)
                monitor.removeEventTap()
            }
        }
        wait(for: [done], timeout: 60)
        XCTAssertFalse(monitor.hasEventTap)
    }
}
