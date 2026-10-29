import XCTest
@testable import Riffle

final class NativeCommandTabTests: XCTestCase {
    /// A Mac whose ⌘⇥ switch and settings outlive the process, and a process that can die between any two steps.
    private final class Mac {
        var enabled = true
        var recorded = false
        var armed = false
        var canTellState = true
        /// Switching ⌘⇥ on doesn't take.
        var refusesToSwitchOn = false
        var steps = [String]()
        /// Steps the process still takes before it dies; nil while it lives on.
        var stepsLeft: Int?

        private func step(_ name: String, _ effect: () -> Void) {
            if let left = stepsLeft {
                guard left > 0 else { return }
                stepsLeft = left - 1
            }
            steps.append(name)
            effect()
        }

        var system: NativeCommandTab.System {
            NativeCommandTab.System(
                recorded: { self.recorded },
                setRecorded: { value in self.step("record \(value)") { self.recorded = value } },
                setEnabled: { value in
                    self.step("enable \(value)") { if !(value && self.refusesToSwitchOn) { self.enabled = value } }
                },
                isEnabled: { self.canTellState ? self.enabled : nil },
                armCrashGuard: { value in self.step("arm \(value)") { self.armed = value } })
        }

        /// The process goes down. Unless it was killed (SIGKILL), an armed crash guard switches ⌘⇥ back on.
        func die(killed: Bool) {
            if armed && !killed { enabled = true }
            armed = false
            stepsLeft = nil
        }
    }

    func testTakingOverWritesTheRecordBeforeSwitchingOff() {
        let mac = Mac()
        let commandTab = NativeCommandTab(system: mac.system)
        commandTab.takeOver()
        XCTAssertEqual(mac.steps, ["record true", "arm true", "enable false"])
        XCTAssertTrue(commandTab.ownsCommandTab)
        XCTAssertFalse(mac.enabled)
    }

    func testGivingBackErasesTheRecordLast() {
        let mac = Mac()
        let commandTab = NativeCommandTab(system: mac.system)
        commandTab.takeOver()
        mac.steps = []
        XCTAssertEqual(commandTab.giveBack(), .switchedOn)
        XCTAssertEqual(mac.steps, ["enable true", "arm false", "record false"])
        XCTAssertFalse(commandTab.ownsCommandTab)
        XCTAssertTrue(mac.enabled)
    }

    func testSomeoneElsesSwitchIsLeftAlone() {
        // Another app, or the user, switched ⌘⇥ off: no record, so neither quitting nor launching touches it.
        let mac = Mac()
        mac.enabled = false
        XCTAssertEqual(NativeCommandTab(system: mac.system).giveBack(), .notOurs)
        XCTAssertEqual(NativeCommandTab(system: mac.system).repairAtLaunch(), .notOurs)
        XCTAssertEqual(mac.steps, ["arm false"])
        XCTAssertFalse(mac.enabled)
    }

    func testDyingAtAnyPointLeavesCommandTabOnAfterTheNextLaunch() {
        for killed in [false, true] {
            for stepsBeforeDeath in 0...3 {
                let mac = Mac()
                mac.stepsLeft = stepsBeforeDeath
                NativeCommandTab(system: mac.system).takeOver()
                mac.die(killed: killed)
                _ = NativeCommandTab(system: mac.system).repairAtLaunch()
                let context = "taking over, died after \(stepsBeforeDeath) steps, killed: \(killed)"
                XCTAssertTrue(mac.enabled, context)
                XCTAssertFalse(mac.recorded, context)
            }
            for stepsBeforeDeath in 0...3 {
                let mac = Mac()
                let running = NativeCommandTab(system: mac.system)
                running.takeOver()
                mac.stepsLeft = stepsBeforeDeath
                running.giveBack()
                mac.die(killed: killed)
                _ = NativeCommandTab(system: mac.system).repairAtLaunch()
                let context = "giving back, died after \(stepsBeforeDeath) steps, killed: \(killed)"
                XCTAssertTrue(mac.enabled, context)
                XCTAssertFalse(mac.recorded, context)
            }
        }
    }

    func testLaunchAfterAKillSwitchesItBackOn() {
        let mac = Mac()
        NativeCommandTab(system: mac.system).takeOver()
        mac.die(killed: true)
        mac.steps = []
        XCTAssertEqual(NativeCommandTab(system: mac.system).repairAtLaunch(), .switchedOn)
        XCTAssertEqual(mac.steps, ["enable true", "record false"])
    }

    func testLaunchAfterTheCrashGuardDidItOnlyForgetsTheRecord() {
        let mac = Mac()
        NativeCommandTab(system: mac.system).takeOver()
        mac.die(killed: false)
        mac.steps = []
        XCTAssertEqual(NativeCommandTab(system: mac.system).repairAtLaunch(), .alreadyOn)
        XCTAssertEqual(mac.steps, ["record false"])
    }

    func testARefusedSwitchKeepsTheRecordForTheNextLaunch() {
        let mac = Mac()
        NativeCommandTab(system: mac.system).takeOver()
        mac.die(killed: true)
        mac.refusesToSwitchOn = true
        XCTAssertEqual(NativeCommandTab(system: mac.system).repairAtLaunch(), .stillOff)
        XCTAssertTrue(mac.recorded)
        mac.refusesToSwitchOn = false
        XCTAssertEqual(NativeCommandTab(system: mac.system).repairAtLaunch(), .switchedOn)
        XCTAssertFalse(mac.recorded)
    }

    func testWhenTheStateCantBeReadTheRepairIsTriedOnce() {
        let mac = Mac()
        NativeCommandTab(system: mac.system).takeOver()
        mac.die(killed: true)
        mac.canTellState = false
        XCTAssertEqual(NativeCommandTab(system: mac.system).repairAtLaunch(), .switchedOn)
        XCTAssertFalse(mac.recorded)
        XCTAssertTrue(mac.enabled)
    }

    func testRepairNeverArmsTheCrashGuard() {
        let mac = Mac()
        NativeCommandTab(system: mac.system).takeOver()
        mac.die(killed: true)
        mac.steps = []
        _ = NativeCommandTab(system: mac.system).repairAtLaunch()
        XCTAssertFalse(mac.steps.contains { $0.hasPrefix("arm") })
    }

    func testLaunchDecisions() {
        for enabled in [true, false, nil] as [Bool?] {
            XCTAssertEqual(NativeCommandTab.launchStep(recorded: false, enabled: enabled), .nothing)
        }
        XCTAssertEqual(NativeCommandTab.launchStep(recorded: true, enabled: true), .forgetRecord)
        XCTAssertEqual(NativeCommandTab.launchStep(recorded: true, enabled: false), .switchBackOn)
        XCTAssertEqual(NativeCommandTab.launchStep(recorded: true, enabled: nil), .switchBackOn)
        XCTAssertTrue(NativeCommandTab.keepsRecord(afterSwitchingOn: false))
        XCTAssertFalse(NativeCommandTab.keepsRecord(afterSwitchingOn: true))
        XCTAssertFalse(NativeCommandTab.keepsRecord(afterSwitchingOn: nil))
    }
}
