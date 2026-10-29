import XCTest
@testable import Riffle

/// SpaceTopology from fixtures shaped like SkyLight's answers: two displays, the first with a desktop and a full-screen
/// Space (showing the full-screen one), the second with one desktop.
final class SpaceTopologyTests: XCTestCase {
    private func space(_ id: CGSSpaceID, type: Int = 0) -> NSDictionary {
        ["id64": NSNumber(value: id), "type": NSNumber(value: type)]
    }

    private var displays: [NSDictionary] {
        [
            ["Display Identifier": "LEFT", "Current Space": space(11), "Spaces": [space(10), space(11, type: 4)]],
            ["Display Identifier": "RIGHT", "Current Space": space(20), "Spaces": [space(20)]],
        ]
    }

    /// Window 100 is on every Space of the left display and on the right one (an app assigned to all desktops).
    private let windows: [CGSSpaceID: [CGWindowID]] = [10: [101, 100], 11: [102, 100], 20: [100, 103]]

    func testSpacesKeepMissionControlsOrderAndOnlyDesktopsAreNumbered() {
        let topology = SpaceTopology.parse(displays: displays, activeDisplay: "RIGHT", windowIDs: nil)
        // In order across displays, full-screen Spaces included (what sorting by desktop goes by); the desktop numbers
        // skip the full-screen Space and carry on across displays.
        XCTAssertEqual(topology.spaces, [
            SpaceInfo(id: 10, index: 1, displayUUID: "LEFT", isFullscreen: false, desktopNumber: 1),
            SpaceInfo(id: 11, index: 2, displayUUID: "LEFT", isFullscreen: true, desktopNumber: nil),
            SpaceInfo(id: 20, index: 3, displayUUID: "RIGHT", isFullscreen: false, desktopNumber: 2),
        ])
        XCTAssertTrue(topology.hasMultipleSpaces)
        XCTAssertEqual(topology.info(for: 11)?.index, 2)
        XCTAssertNil(topology.info(for: 99))
    }

    /// Desktop 1, Safari in full screen, Desktop 2: Mission Control calls the third Space "Desktop 2", and so must a card.
    func testAFullScreenSpaceDoesNotTakeADesktopNumber() {
        let display: NSDictionary = ["Display Identifier": "MAIN", "Current Space": space(1),
                                     "Spaces": [space(1), space(2, type: 4), space(3), space(4, type: 4), space(5)]]
        let topology = SpaceTopology.parse(displays: [display], activeDisplay: "MAIN", windowIDs: nil)
        XCTAssertEqual(topology.spaces.map(\.desktopNumber), [1, nil, 2, nil, 3])
        XCTAssertEqual(topology.spaces.map(\.index), [1, 2, 3, 4, 5])
        XCTAssertEqual(topology.spaces.map(\.isFullscreen), [false, true, false, true, false])
    }

    func testACardShowsTheNumberOfTheFirstDesktopItsWindowIsOn() {
        let topology = SpaceTopology.parse(displays: displays, activeDisplay: "LEFT", windowIDs: nil)
        XCTAssertEqual(topology.desktopNumber(of: [20]), 2)
        // A full-screen window: no number, its card says full screen instead.
        XCTAssertNil(topology.desktopNumber(of: [11]))
        // On every desktop: the first one that is a desktop.
        XCTAssertEqual(topology.desktopNumber(of: [11, 20, 10]), 2)
        // Spaces nobody listed (gone since the last reading), or none.
        XCTAssertNil(topology.desktopNumber(of: [99]))
        XCTAssertNil(topology.desktopNumber(of: []))
    }

    func testTheActiveSpaceIsTheOneOnTheDisplayWithTheMenuBar() {
        XCTAssertEqual(SpaceTopology.parse(displays: displays, activeDisplay: "RIGHT", windowIDs: nil).activeSpaceID, 20)
        XCTAssertEqual(SpaceTopology.parse(displays: displays, activeDisplay: "LEFT", windowIDs: nil).activeSpaceID, 11)
        // Not known (or not one of these displays): the first display's.
        XCTAssertEqual(SpaceTopology.parse(displays: displays, activeDisplay: nil, windowIDs: nil).activeSpaceID, 11)
        XCTAssertEqual(SpaceTopology.parse(displays: displays, activeDisplay: nil, windowIDs: nil).visibleSpaceIDs, [11, 20])
    }

    func testWindowsOfVisibleSpacesComeFirstEachOnce() {
        let topology = SpaceTopology.parse(displays: displays, activeDisplay: "LEFT") { self.windows[$0] ?? [] }
        XCTAssertEqual(topology.orderedWindowIDs, [102, 100, 103, 101])
        XCTAssertEqual(topology.windowSpaces[100], [11, 20, 10])
        XCTAssertEqual(topology.windowSpaces[101], [10])
    }

    func testWindowsAreOnlyReadWhenAskedFor() {
        let topology = SpaceTopology.parse(displays: displays, activeDisplay: "LEFT", windowIDs: nil)
        XCTAssertTrue(topology.orderedWindowIDs.isEmpty)
        XCTAssertTrue(topology.windowSpaces.isEmpty)
    }

    func testIncompleteAnswersAreReadAsFarAsTheyGo() {
        let odd: [NSDictionary] = [
            // No identifier: "Main". A Space without an id is skipped and doesn't take a number.
            ["Current Space": space(5), "Spaces": [["type": NSNumber(value: 0)] as NSDictionary, space(5)]],
            // No current Space and no list.
            ["Display Identifier": "EMPTY"],
        ]
        let topology = SpaceTopology.parse(displays: odd, activeDisplay: "EMPTY", windowIDs: nil)
        XCTAssertEqual(topology.spaces, [SpaceInfo(id: 5, index: 1, displayUUID: "Main", isFullscreen: false, desktopNumber: 1)])
        XCTAssertEqual(topology.activeSpaceID, 5)
        XCTAssertFalse(topology.hasMultipleSpaces)
        XCTAssertEqual(SpaceTopology.parse(displays: [], activeDisplay: nil, windowIDs: nil).activeSpaceID, 0)
    }
}
