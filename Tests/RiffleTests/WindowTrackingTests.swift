import AppKit
import XCTest
@testable import Riffle

// Window tracking: AX concurrency, when to scan, the WindowServer reconcile, native tabs and phantom windows.

final class AXLimiterTests: XCTestCase {
    /// A limiter whose started jobs wait in `started` until the test runs them: no threads, no timing.
    private final class Harness {
        var started = [() -> Void]()
        var log = [String]()
        lazy var limiter = AXLimiter(width: width, execute: { [unowned self] job in self.started.append(job) })
        let width: Int

        init(width: Int) { self.width = width }

        func submit(_ name: String, pid: pid_t, priority: AXLimiter.Priority = .normal, key: String? = nil) -> Bool {
            limiter.submit(pid: pid, priority: priority, key: key) { [unowned self] in self.log.append(name) }
        }

        /// Runs the oldest started job to completion.
        func finishNext() {
            started.removeFirst()()
        }
    }

    func testNeverMoreThanWidthInFlight() {
        let harness = Harness(width: 2)
        for pid in 1...5 { _ = harness.submit("job\(pid)", pid: pid_t(pid)) }
        XCTAssertEqual(harness.started.count, 2)
        XCTAssertEqual(harness.limiter.inFlight, 2)
        XCTAssertEqual(harness.limiter.queued, 3)
        harness.finishNext()
        XCTAssertEqual(harness.limiter.inFlight, 2)
        while !harness.started.isEmpty { harness.finishNext() }
        XCTAssertEqual(harness.log, ["job1", "job2", "job3", "job4", "job5"])
        XCTAssertEqual(harness.limiter.inFlight, 0)
    }

    func testOneCallPerAppAtATimeInOrder() {
        let harness = Harness(width: 4)
        for index in 1...3 { _ = harness.submit("a\(index)", pid: 7) }
        XCTAssertEqual(harness.started.count, 1)
        harness.finishNext()
        XCTAssertEqual(harness.started.count, 1)
        harness.finishNext()
        harness.finishNext()
        XCTAssertEqual(harness.log, ["a1", "a2", "a3"])
    }

    func testAHungAppHoldsOneSlotAndOthersCarryOn() {
        let harness = Harness(width: 3)
        _ = harness.submit("hung", pid: 1)
        let hung = harness.started.removeFirst() // never finishes during this test
        _ = harness.submit("hung again", pid: 1)
        _ = harness.submit("hung once more", pid: 1)
        for pid in 2...6 { _ = harness.submit("app\(pid)", pid: pid_t(pid)) }
        // Two free slots for everyone else; the hung app's other calls wait instead of taking more threads.
        XCTAssertEqual(harness.started.count, 2)
        while !harness.started.isEmpty { harness.finishNext() }
        XCTAssertEqual(harness.log, ["app2", "app3", "app4", "app5", "app6"])
        XCTAssertEqual(harness.limiter.inFlight, 1)
        XCTAssertEqual(harness.limiter.queued, 2)
        hung()
        harness.finishNext()
        harness.finishNext()
        XCTAssertEqual(harness.log.suffix(3), ["hung", "hung again", "hung once more"])
    }

    func testFocusWorkGoesBeforeScans() {
        let harness = Harness(width: 1)
        _ = harness.submit("scan 1", pid: 1)
        _ = harness.submit("scan 2", pid: 2)
        _ = harness.submit("focus", pid: 3, priority: .high)
        while !harness.started.isEmpty { harness.finishNext() }
        XCTAssertEqual(harness.log, ["scan 1", "focus", "scan 2"])
    }

    func testWaitingJobWithTheSameKeyMakesANewOneRedundant() {
        let harness = Harness(width: 1)
        _ = harness.submit("busy", pid: 1)
        XCTAssertTrue(harness.submit("refresh", pid: 2, key: "refresh 9"))
        XCTAssertFalse(harness.submit("refresh again", pid: 2, key: "refresh 9"))
        XCTAssertTrue(harness.submit("other window", pid: 2, key: "refresh 10"))
        harness.finishNext()
        // Running now: a later change needs a read of its own.
        XCTAssertTrue(harness.submit("refresh after", pid: 2, key: "refresh 9"))
        while !harness.started.isEmpty { harness.finishNext() }
        XCTAssertEqual(harness.log, ["busy", "refresh", "other window", "refresh after"])
    }

    func testRealThreadsNeverExceedTheCap() {
        let limiter = AXLimiter(width: 3)
        let lock = NSLock()
        var running = 0
        var most = 0
        var perApp = [pid_t: Int]()
        var mostPerApp = 0
        let group = DispatchGroup()
        for index in 0..<40 {
            let pid = pid_t(index % 6)
            group.enter()
            limiter.submit(pid: pid) {
                lock.lock()
                running += 1
                most = max(most, running)
                perApp[pid, default: 0] += 1
                mostPerApp = max(mostPerApp, perApp[pid]!)
                lock.unlock()
                usleep(500)
                lock.lock()
                running -= 1
                perApp[pid]! -= 1
                lock.unlock()
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertLessThanOrEqual(most, 3)
        XCTAssertEqual(mostPerApp, 1)
    }
}

final class ScanPlannerTests: XCTestCase {
    private let now: TimeInterval = 10_000

    private func state(lastFull: TimeInterval? = 9_990, needs: [pid_t: ScanPlanner.Need] = [:], requested: Bool = false,
                       untracked: Set<pid_t> = [], idle: TimeInterval = 5, locked: Bool = false) -> ScanPlanner.State {
        ScanPlanner.State(now: now, lastFullScan: lastFull, fullScanRequested: requested, needs: needs, untrackedOwners: untracked,
                          idleTime: idle, isLocked: locked)
    }

    private func need(_ reasons: Set<ScanPlanner.Reason>, last: TimeInterval? = nil, failures: Int = 0) -> ScanPlanner.Need {
        ScanPlanner.Need(reasons: reasons, lastAttempt: last, failures: failures)
    }

    func testFreshModelNeedsNoScanOnSummon() {
        XCTAssertEqual(ScanPlanner.plan(state(), trigger: .summon), .none)
        XCTAssertEqual(ScanPlanner.plan(state(needs: [4: need([])]), trigger: .summon), .none)
    }

    func testOnlyAppsThatNeedItAreRead() {
        let needs: [pid_t: ScanPlanner.Need] = [1: need([.unknownWindows]), 2: need([]), 3: need([.launched]), 5: need([.sweeping])]
        XCTAssertEqual(ScanPlanner.plan(state(needs: needs), trigger: .summon), .apps([1, 3, 5]))
        XCTAssertEqual(ScanPlanner.plan(state(needs: [8: need([.changed])]), trigger: .event), .apps([8]))
    }

    func testUntrackedOwnersAreProbed() {
        XCTAssertEqual(ScanPlanner.plan(state(untracked: [42]), trigger: .summon), .apps([42]))
    }

    func testOldOrInvalidatedModelIsReadWhole() {
        XCTAssertEqual(ScanPlanner.plan(state(lastFull: now - ScanPlanner.summonMaxAge - 1), trigger: .summon), .full)
        XCTAssertEqual(ScanPlanner.plan(state(lastFull: nil), trigger: .summon), .full)
        XCTAssertEqual(ScanPlanner.plan(state(lastFull: nil), trigger: .event), .full)
        XCTAssertEqual(ScanPlanner.plan(state(requested: true), trigger: .summon), .full)
        XCTAssertEqual(ScanPlanner.plan(state(requested: true), trigger: .event), .full)
        XCTAssertEqual(ScanPlanner.plan(state(requested: true), trigger: .timer), .full)
    }

    func testEventsDontReadEverythingJustBecauseOfAge() {
        // A Space change on an old model: the safety net and the next summon take care of age.
        XCTAssertEqual(ScanPlanner.plan(state(lastFull: now - 500), trigger: .event), .none)
    }

    func testSafetyNetOnlyWhileSomeoneIsThere() {
        let old = now - ScanPlanner.backgroundMaxAge - 1
        XCTAssertEqual(ScanPlanner.plan(state(lastFull: old, idle: 10), trigger: .timer), .full)
        XCTAssertEqual(ScanPlanner.plan(state(lastFull: old, idle: ScanPlanner.idleCutoff + 1), trigger: .timer), .none)
        XCTAssertEqual(ScanPlanner.plan(state(needs: [3: need([.unknownWindows])], idle: 10), trigger: .timer), .apps([3]))
        XCTAssertEqual(ScanPlanner.plan(state(idle: 10), trigger: .timer), .none)
    }

    func testNothingWhileLocked() {
        for trigger in [ScanPlanner.Trigger.summon, .timer, .event] {
            XCTAssertEqual(ScanPlanner.plan(state(lastFull: nil, needs: [1: need([.launched])], requested: true, locked: true), trigger: trigger), .none)
        }
    }

    func testBusyAppsBackOff() {
        XCTAssertFalse(ScanPlanner.isDue(need([.unresponsive], last: now - 1, failures: 1), now: now))
        XCTAssertTrue(ScanPlanner.isDue(need([.unresponsive], last: now - 4, failures: 1), now: now))
        XCTAssertFalse(ScanPlanner.isDue(need([.unresponsive], last: now - 4, failures: 3), now: now))
        XCTAssertTrue(ScanPlanner.isDue(need([.unresponsive], last: now - 13, failures: 3), now: now))
        // Being busy wins over any other reason: asking again at once would only wait out another timeout.
        XCTAssertFalse(ScanPlanner.isDue(need([.unresponsive, .changed, .unknownWindows], last: now - 1, failures: 1), now: now))
        XCTAssertEqual(ScanPlanner.plan(state(needs: [9: need([.unresponsive], last: now - 1, failures: 2)]), trigger: .summon), .none)
    }

    func testAppsWithoutNotificationsAreReadNowAndThen() {
        XCTAssertTrue(ScanPlanner.isDue(need([.noObserver]), now: now))
        XCTAssertFalse(ScanPlanner.isDue(need([.noObserver], last: now - 1), now: now))
        XCTAssertTrue(ScanPlanner.isDue(need([.noObserver], last: now - 3), now: now))
        // Something else to look at: now.
        XCTAssertTrue(ScanPlanner.isDue(need([.noObserver, .unknownWindows], last: now - 1), now: now))
    }

    func testRetryIntervalDoublesUpToAMinute() {
        XCTAssertEqual(ScanPlanner.retryInterval(failures: 0), 3)
        XCTAssertEqual(ScanPlanner.retryInterval(failures: 1), 3)
        XCTAssertEqual(ScanPlanner.retryInterval(failures: 2), 6)
        XCTAssertEqual(ScanPlanner.retryInterval(failures: 3), 12)
        XCTAssertEqual(ScanPlanner.retryInterval(failures: 20), 60)
    }
}

final class WindowServerReconcileTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let frame = CGRect(x: 100, y: 100, width: 800, height: 600)

    private func describe(_ wid: CGWindowID, pid: pid_t, frame: CGRect? = nil, onScreen: Bool = true, alpha: Double = 1,
                          layer: Int = 0) -> CGWindowDescription {
        CGWindowDescription(wid: wid, pid: pid, layer: layer, bounds: frame ?? self.frame, alpha: alpha, isOnScreen: onScreen, name: nil)
    }

    private func topology(_ windowSpaces: [CGWindowID: [CGSSpaceID]]) -> SpaceTopology {
        var topology = SpaceTopology()
        topology.spaces = [SpaceInfo(id: 1, index: 1, displayUUID: "A", isFullscreen: false),
                           SpaceInfo(id: 2, index: 2, displayUUID: "A", isFullscreen: false)]
        topology.visibleSpaceIDs = [1]
        topology.activeSpaceID = 1
        topology.windowSpaces = windowSpaces
        topology.orderedWindowIDs = windowSpaces.keys.sorted()
        return topology
    }

    private func input(_ topology: SpaceTopology, _ descriptions: [CGWindowDescription], tracked: [WindowServerReconcile.Tracked],
                       examined: [pid_t: [CGWindowID: Bool]] = [:], hidden: Set<pid_t> = []) -> WindowServerReconcile.Input {
        WindowServerReconcile.Input(ownPID: 999, topology: topology,
                                    descriptions: Dictionary(uniqueKeysWithValues: descriptions.map { ($0.wid, $0) }),
                                    displays: [display], tracked: tracked, trackedPIDs: Set(tracked.map(\.pid)).union([5]),
                                    hiddenPIDs: hidden, examined: examined)
    }

    private func tracked(_ wid: CGWindowID, pid: pid_t = 5, minimized: Bool = false) -> WindowServerReconcile.Tracked {
        WindowServerReconcile.Tracked(wid: wid, pid: pid, isMinimized: minimized)
    }

    func testClosedWindowsNobodyAnnouncedAreGone() {
        let outcome = WindowServerReconcile.evaluate(input(topology([10: [1]]), [describe(10, pid: 5)], tracked: [tracked(10), tracked(99)]))
        XCTAssertEqual(outcome.vanished, [99])
    }

    func testWithoutTheSpaceLayoutOnlyClosedWindowsGo() {
        // SkyLight gave nothing: every window would look like it's on no Space. A background tab, a Space change or an
        // unknown window can't be told then; a closed window still can.
        var silent = SpaceTopology()
        silent.orderedWindowIDs = []
        let descriptions = [describe(10, pid: 5), describe(11, pid: 5, onScreen: false), describe(20, pid: 5)]
        let outcome = WindowServerReconcile.evaluate(input(silent, descriptions, tracked: [tracked(10), tracked(11), tracked(99)]))
        XCTAssertEqual(outcome.vanished, [99])
        XCTAssertTrue(outcome.backgroundTabs.isEmpty)
        XCTAssertTrue(outcome.spaces.isEmpty)
        XCTAssertTrue(outcome.appsWithUnknownWindows.isEmpty)
        // Spaces but no windows on any of them: just as unreliable.
        var empty = topology([:])
        empty.orderedWindowIDs = [20]
        XCTAssertFalse(WindowServerReconcile.isLayoutKnown(empty))
        XCTAssertEqual(WindowServerReconcile.evaluate(input(empty, descriptions, tracked: [tracked(10), tracked(11), tracked(99)])),
                       WindowServerReconcile.Outcome(vanished: [99]))
    }

    func testSpacesComeFromTheWindowServer() {
        let outcome = WindowServerReconcile.evaluate(input(topology([10: [2]]), [describe(10, pid: 5), describe(12, pid: 5, onScreen: false)],
                                                           tracked: [tracked(10), tracked(12, minimized: true)]))
        XCTAssertEqual(outcome.spaces, [10: [2]])
        // A minimized window that dropped off the Space lists keeps what it had.
        XCTAssertNil(outcome.spaces[12])
    }

    func testAWindowNobodyAnnouncedGetsItsAppScanned() {
        let outcome = WindowServerReconcile.evaluate(input(topology([10: [1], 20: [1]]), [describe(10, pid: 5), describe(20, pid: 5)],
                                                           tracked: [tracked(10)]))
        XCTAssertEqual(outcome.appsWithUnknownWindows, [5])
        XCTAssertTrue(outcome.untrackedOwners.isEmpty)
    }

    func testUntrackedOwnersAreProbed() {
        let outcome = WindowServerReconcile.evaluate(input(topology([30: [1]]), [describe(30, pid: 77)], tracked: []))
        XCTAssertEqual(outcome.untrackedOwners, [77])
        XCTAssertTrue(outcome.appsWithUnknownWindows.isEmpty)
    }

    func testLookedAtSurfacesWaitUntilTheyComeOnScreen() {
        let spaces = topology([20: [2]])
        let offScreen = [describe(20, pid: 5, onScreen: false)]
        // Settled off screen, still off screen: nothing new.
        XCTAssertTrue(WindowServerReconcile.evaluate(input(spaces, offScreen, tracked: [], examined: [5: [20: false]])).appsWithUnknownWindows.isEmpty)
        // Its Space came on screen: AX lists it now, worth another look.
        let onScreen = [describe(20, pid: 5, onScreen: true)]
        XCTAssertEqual(WindowServerReconcile.evaluate(input(spaces, onScreen, tracked: [], examined: [5: [20: false]])).appsWithUnknownWindows, [5])
        // Settled while on screen: done.
        XCTAssertTrue(WindowServerReconcile.evaluate(input(spaces, onScreen, tracked: [], examined: [5: [20: true]])).appsWithUnknownWindows.isEmpty)
    }

    func testHelperSurfacesNeverTriggerScans() {
        let surfaces = [
            describe(40, pid: 5, frame: CGRect(x: 0, y: 0, width: 60, height: 30)),          // too small to be a window
            describe(41, pid: 5, alpha: 0),                                                    // transparent
            describe(42, pid: 5, frame: CGRect(x: -9000, y: -9000, width: 800, height: 600)), // parked off every display
            describe(43, pid: 5, layer: 25),                                                   // above the normal level
            describe(44, pid: 999),                                                            // Riffle's own
        ]
        let outcome = WindowServerReconcile.evaluate(input(topology([40: [1], 41: [1], 42: [1], 43: [1], 44: [1]]), surfaces, tracked: []))
        XCTAssertTrue(outcome.appsWithUnknownWindows.isEmpty)
        XCTAssertTrue(outcome.untrackedOwners.isEmpty)
    }

    func testSurfacesOnNoSpaceNeverTriggerScans() {
        // Off screen and on no Space (a background tab, a parked helper): AX can never list it, so asking would never end.
        let outcome = WindowServerReconcile.evaluate(input(topology([10: [1]]), [describe(10, pid: 5), describe(50, pid: 5, onScreen: false)],
                                                           tracked: [tracked(10)]))
        XCTAssertTrue(outcome.appsWithUnknownWindows.isEmpty)
    }

    func testBackgroundTabsAreReported() {
        let outcome = WindowServerReconcile.evaluate(input(topology([10: [1]]), [describe(10, pid: 5), describe(11, pid: 5, onScreen: false)],
                                                           tracked: [tracked(10), tracked(11)]))
        XCTAssertEqual(outcome.backgroundTabs, [11])
    }

    func testForgetsSurfacesThatAreGone() {
        let pruned = WindowServerReconcile.pruned([5: [20: true, 21: false], 6: [30: true]], alive: [20])
        XCTAssertEqual(pruned, [5: [20: true]])
    }
}

final class TabGroupTests: XCTestCase {
    private let frame = CGRect(x: 200, y: 120, width: 900, height: 640)

    private func surface(_ wid: CGWindowID, pid: pid_t = 5, frame: CGRect? = nil, onScreen: Bool = false, onSpace: Bool = false,
                         minimized: Bool = false) -> TabGroups.Surface {
        TabGroups.Surface(wid: wid, pid: pid, frame: frame ?? self.frame, isOnScreen: onScreen, isOnSpace: onSpace, isMinimized: minimized)
    }

    func testOneCardPerGroupTheVisibleTab() {
        let visible = surface(1, onScreen: true, onSpace: true)
        XCTAssertEqual(TabGroups.backgroundTabs([visible, surface(2), surface(3)]), [2, 3])
    }

    func testGroupOnAnotherSpace() {
        // Its Space isn't on screen: the visible tab is off screen too, but on a Space.
        XCTAssertEqual(TabGroups.backgroundTabs([surface(1, onSpace: true), surface(2)]), [2])
    }

    func testMinimizedGroupKeepsItsVisibleTab() {
        XCTAssertEqual(TabGroups.backgroundTabs([surface(1, minimized: true), surface(2)]), [2])
    }

    func testWithoutAShownSiblingNothingIsDropped() {
        // The visible tab isn't known yet: dropping this one would leave the group without a card.
        XCTAssertTrue(TabGroups.backgroundTabs([surface(2)]).isEmpty)
        XCTAssertTrue(TabGroups.backgroundTabs([surface(2), surface(3)]).isEmpty)
    }

    func testRealWindowsAreNeverTabs() {
        let visible = surface(1, onScreen: true, onSpace: true)
        // Minimized, on another Space, or on screen: real windows, whatever their frame.
        XCTAssertTrue(TabGroups.backgroundTabs([visible, surface(2, minimized: true)]).isEmpty)
        XCTAssertTrue(TabGroups.backgroundTabs([visible, surface(3, onSpace: true)]).isEmpty)
        XCTAssertTrue(TabGroups.backgroundTabs([visible, surface(4, onScreen: true)]).isEmpty)
    }

    func testOnlySiblingsWithTheSameFrame() {
        let visible = surface(1, onScreen: true, onSpace: true)
        XCTAssertEqual(TabGroups.backgroundTabs([visible, surface(2, frame: frame.offsetBy(dx: 1.5, dy: -1))]), [2])
        XCTAssertTrue(TabGroups.backgroundTabs([visible, surface(3, frame: frame.offsetBy(dx: 40, dy: 0))]).isEmpty)
        XCTAssertTrue(TabGroups.backgroundTabs([visible, surface(4, frame: frame.insetBy(dx: 10, dy: 10))]).isEmpty)
    }

    func testOnlySiblingsOfTheSameApp() {
        XCTAssertTrue(TabGroups.backgroundTabs([surface(1, pid: 5, onScreen: true, onSpace: true), surface(2, pid: 6)]).isEmpty)
    }

    func testHiddenAppsAreLeftAlone() {
        let group = [surface(1, onSpace: true), surface(2)]
        XCTAssertTrue(TabGroups.backgroundTabs(group, hiddenPIDs: [5]).isEmpty)
    }
}

final class PhantomWindowTests: XCTestCase {
    private let element = AXUIElementCreateApplication(getpid())
    private let displays = [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: 1512, y: -200, width: 2560, height: 1440)]

    private func snapshot(subrole: String? = kAXStandardWindowSubrole, title: String = "Doc", main: Bool = false,
                          minimized: Bool = false, fullscreen: Bool = false) -> AXWindowSnapshot {
        AXWindowSnapshot(element: element, wid: 42, role: kAXWindowRole, subrole: subrole, title: title, isMinimized: minimized,
                         isFullscreen: fullscreen, isMain: main, frame: nil)
    }

    private func description(_ bounds: CGRect = CGRect(x: 100, y: 100, width: 800, height: 600), alpha: Double = 1) -> CGWindowDescription {
        CGWindowDescription(wid: 42, pid: 1, layer: 0, bounds: bounds, alpha: alpha, isOnScreen: true, name: nil)
    }

    func testTransparentSurfacesAreNotWindows() {
        XCTAssertFalse(WindowEligibility.admit(snapshot(), description(alpha: 0), displays: displays))
        XCTAssertFalse(WindowEligibility.admit(snapshot(main: true), description(alpha: 0.01), displays: displays))
        XCTAssertTrue(WindowEligibility.admit(snapshot(), description(alpha: 0.6), displays: displays))
    }

    func testZeroSizeSurfacesAreNotWindows() {
        XCTAssertFalse(WindowEligibility.admit(snapshot(), description(CGRect(x: 10, y: 10, width: 0, height: 0)), displays: displays))
        XCTAssertFalse(WindowEligibility.admit(snapshot(main: true), description(CGRect(x: 10, y: 10, width: 1, height: 1)), displays: displays))
        XCTAssertFalse(WindowEligibility.admit(snapshot(), description(CGRect(x: 10, y: 10, width: 900, height: 4)), displays: displays))
    }

    func testSurfacesOffEveryDisplayAreNotWindows() {
        XCTAssertFalse(WindowEligibility.admit(snapshot(), description(CGRect(x: -20_000, y: -20_000, width: 800, height: 600)), displays: displays))
        XCTAssertFalse(WindowEligibility.admit(snapshot(), description(CGRect(x: 0, y: 3000, width: 800, height: 600)), displays: displays))
        // Unknown displays: position isn't held against anything.
        XCTAssertTrue(WindowEligibility.admit(snapshot(), description(CGRect(x: -20_000, y: -20_000, width: 800, height: 600)), displays: []))
    }

    func testRealWindowsStayIn() {
        // Partly off screen, on the second display, small but real.
        XCTAssertTrue(WindowEligibility.admit(snapshot(), description(CGRect(x: -700, y: 40, width: 800, height: 600)), displays: displays))
        XCTAssertTrue(WindowEligibility.admit(snapshot(), description(CGRect(x: 2000, y: -150, width: 800, height: 600)), displays: displays))
        XCTAssertTrue(WindowEligibility.admit(snapshot(), description(CGRect(x: 40, y: 40, width: 240, height: 36)), displays: displays))
        XCTAssertTrue(WindowEligibility.admit(snapshot(subrole: kAXDialogSubrole, title: "Save"), description(), displays: displays))
    }

    func testMinimizedAndFullScreenWindowsAreNeverPhantoms() {
        let parked = description(CGRect(x: -20_000, y: 0, width: 0, height: 0), alpha: 0)
        XCTAssertTrue(WindowEligibility.admit(snapshot(minimized: true), parked, displays: displays))
        XCTAssertTrue(WindowEligibility.admit(snapshot(fullscreen: true), parked, displays: displays))
    }

    func testCandidatesForALookup() {
        XCTAssertTrue(WindowEligibility.isCandidate(description(), ownPID: 999, displays: displays))
        XCTAssertFalse(WindowEligibility.isCandidate(description(), ownPID: 1, displays: displays))
        XCTAssertFalse(WindowEligibility.isCandidate(description(alpha: 0), ownPID: 999, displays: displays))
        XCTAssertFalse(WindowEligibility.isCandidate(description(CGRect(x: 0, y: 0, width: 80, height: 600)), ownPID: 999, displays: displays))
        XCTAssertFalse(WindowEligibility.isCandidate(description(CGRect(x: 9000, y: 0, width: 800, height: 600)), ownPID: 999, displays: displays))
    }
}
