import AppKit
import XCTest
@testable import Riffle

final class FocusRequestTests: XCTestCase {
    /// Records what a focus request did; `unminimize` can be made to block, like a busy app.
    private final class RecordingDriver: FocusDriver {
        private let lock = NSLock()
        private var steps = [String]()
        var gate: DispatchSemaphore?
        var canFront = true

        var log: [String] {
            lock.lock()
            defer { lock.unlock() }
            return steps
        }

        private func note(_ step: String) {
            lock.lock()
            steps.append(step)
            lock.unlock()
        }

        func unminimize(_ target: WindowActions.FocusTarget) {
            note("unminimize")
            gate?.wait()
        }

        func front(_ target: WindowActions.FocusTarget) -> Bool {
            note("front \(target.pid)")
            return canFront
        }

        func makeKey(_ target: WindowActions.FocusTarget) { note("key") }
        func raise(_ target: WindowActions.FocusTarget) { note("raise") }
        func restoreSpaceFront(space: CGSSpaceID, pid: pid_t) { note("restore \(space) \(pid)") }
    }

    private func target(pid: pid_t = 5, minimized: Bool = false) -> WindowActions.FocusTarget {
        WindowActions.FocusTarget(wid: 42, pid: pid, element: nil, isMinimized: minimized, spaceIDs: [])
    }

    func testStepsInOrder() {
        let generations = FocusGenerations()
        let driver = RecordingDriver()
        var fronted = 0
        let done = FocusSequence.run(target(minimized: true), token: generations.begin(), generations: generations, driver: driver,
                                     origin: .init(space: 3, frontPID: 9), onFronted: { fronted += 1 }, cannotFront: { XCTFail() })
        XCTAssertTrue(done)
        XCTAssertEqual(fronted, 1)
        XCTAssertEqual(driver.log, ["unminimize", "front 5", "key", "raise", "restore 3 9"])
    }

    func testSameAppOnTheOriginSpaceIsNotRestored() {
        let generations = FocusGenerations()
        let driver = RecordingDriver()
        FocusSequence.run(target(), token: generations.begin(), generations: generations, driver: driver,
                          origin: .init(space: 3, frontPID: 5), onFronted: {}, cannotFront: {})
        XCTAssertEqual(driver.log, ["front 5", "key", "raise"])
    }

    func testAnOlderRequestNeverStarts() {
        let generations = FocusGenerations()
        let driver = RecordingDriver()
        let old = generations.begin()
        _ = generations.begin()
        XCTAssertFalse(FocusSequence.run(target(), token: old, generations: generations, driver: driver, origin: nil,
                                         onFronted: { XCTFail() }, cannotFront: { XCTFail() }))
        XCTAssertTrue(driver.log.isEmpty)
    }

    func testAStaleRequestStuckOnABusyAppNeverFrontsIt() {
        let generations = FocusGenerations()
        let driver = RecordingDriver()
        driver.gate = DispatchSemaphore(value: 0)
        let token = generations.begin()
        let finished = expectation(description: "stale request finished")
        var result = true
        DispatchQueue.global().async {
            result = FocusSequence.run(self.target(minimized: true), token: token, generations: generations, driver: driver, origin: nil,
                                       onFronted: {}, cannotFront: {})
            finished.fulfill()
        }
        // While it waits on the busy app, the user picks another window.
        while driver.log.isEmpty { usleep(100) }
        _ = generations.begin()
        driver.gate?.signal()
        wait(for: [finished], timeout: 5)
        XCTAssertFalse(result)
        XCTAssertEqual(driver.log, ["unminimize"])
    }

    func testAppsThatCantBeFrontedTheFastWay() {
        let generations = FocusGenerations()
        let driver = RecordingDriver()
        driver.canFront = false
        var fallback = 0
        XCTAssertFalse(FocusSequence.run(target(), token: generations.begin(), generations: generations, driver: driver, origin: nil,
                                         onFronted: { XCTFail() }, cannotFront: { fallback += 1 }))
        XCTAssertEqual(fallback, 1)
    }

    func testLanesAreOnePerApp() {
        let lanes = ActionLanes(label: "test.lanes", qos: .userInitiated)
        XCTAssertTrue(lanes.queue(for: 5) === lanes.queue(for: 5))
        XCTAssertFalse(lanes.queue(for: 5) === lanes.queue(for: 6))
    }

    func testABusyAppDoesNotHoldUpAnother() {
        let lanes = ActionLanes(label: "test.lanes", qos: .userInitiated)
        let busy = DispatchSemaphore(value: 0)
        lanes.queue(for: 1).async { busy.wait() }
        let other = expectation(description: "another app's request ran")
        lanes.queue(for: 2).async { other.fulfill() }
        wait(for: [other], timeout: 5)
        busy.signal()
    }

    func testLanesOfAppsThatQuitAreLetGo() {
        let lanes = ActionLanes(label: "test.lanes", qos: .userInitiated, limit: 4, isAlive: { $0 >= 100 })
        for pid in 1...4 { _ = lanes.queue(for: pid_t(pid)) }
        XCTAssertEqual(lanes.count, 4)
        _ = lanes.queue(for: 100)
        XCTAssertEqual(lanes.count, 1)
    }

    func testNewerRequestsWin() {
        let generations = FocusGenerations()
        let first = generations.begin()
        XCTAssertTrue(generations.isCurrent(first))
        let second = generations.begin()
        XCTAssertFalse(generations.isCurrent(first))
        XCTAssertTrue(generations.isCurrent(second))
    }
}
