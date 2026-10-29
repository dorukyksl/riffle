import AppKit
import XCTest
@testable import Riffle

final class MissionControlTests: XCTestCase {
    func testTheDockAloneIsNotMissionControl() {
        XCTAssertFalse(MissionControl.isShowing(dockChildren: [.init(role: kAXListRole)]))
        XCTAssertFalse(MissionControl.isShowing(dockChildren: []))
        // A Dock icon's menu.
        XCTAssertFalse(MissionControl.isShowing(dockChildren: [.init(role: kAXListRole), .init(role: kAXMenuRole)]))
    }

    func testMissionControlsViewIsAGroupNextToTheDock() {
        // As the Dock lists it on macOS 26 while Mission Control is up.
        XCTAssertTrue(MissionControl.isShowing(dockChildren: [.init(role: kAXListRole), .init(role: kAXGroupRole, identifier: "mc")]))
        // Whatever the language its title is in: the identifier decides.
        XCTAssertTrue(MissionControl.isShowing(dockChildren: [.init(role: kAXGroupRole, identifier: "mc", title: "调度中心"), .init(role: kAXListRole)]))
    }

    func testOtherGroupsInTheDockAreNotMissionControl() {
        // A folder's stack, a menu or anything else the Dock shows must never keep the switcher away.
        XCTAssertFalse(MissionControl.isShowing(dockChildren: [.init(role: kAXListRole), .init(role: kAXGroupRole)]))
        XCTAssertFalse(MissionControl.isShowing(dockChildren: [.init(role: kAXListRole), .init(role: kAXGroupRole, identifier: "stack")]))
        XCTAssertFalse(MissionControl.isShowing(dockChildren: [.init(role: kAXListRole), .init(role: kAXListRole, identifier: "mc")]))
    }
}
