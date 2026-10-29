import XCTest
@testable import Riffle

/// "The app under the pointer" asks the Dock which icon is there while the shortcut is held: every element it asks must be
/// held to the short timeout first (a timeout covers only the element it's set on), and a Dock that stops answering ends
/// the search at once.
final class DockQuestionTests: XCTestCase {
    private let safari = URL(fileURLWithPath: "/Applications/Safari.app")

    /// A Dock made of numbered elements (0 is the Dock itself), recording every question it's asked.
    private final class FakeDock {
        var elements: [Int: WindowProbe.DockElement<Int>] = [:]
        var hit: Int? = 1
        /// Elements that don't answer in time.
        var silent: Set<Int> = []
        var asked: [String] = []

        var questions: WindowProbe.DockQuestions<Int> {
            WindowProbe.DockQuestions(
                limit: { element, seconds in self.asked.append("limit \(element) \(seconds)") },
                elementAt: { dock, _ in
                    self.asked.append("elementAt \(dock)")
                    return self.silent.contains(dock) ? nil : self.hit
                },
                describe: { element in
                    self.asked.append("describe \(element)")
                    return self.silent.contains(element) ? nil : self.elements[element]
                })
        }

        func url(at point: CGPoint = CGPoint(x: 700, y: 950)) -> URL? {
            WindowProbe.dockItemURL(at: point, in: 0, asking: questions)
        }
    }

    func testEveryElementIsHeldToTheShortTimeoutBeforeItIsAsked() {
        XCTAssertEqual(WindowProbe.dockTimeout, 0.15)
        let dock = FakeDock()
        // The pointer is on the icon's picture; the icon is its parent.
        dock.elements = [1: .init(subrole: "AXImage", url: nil, parent: 2), 2: .init(subrole: "AXApplicationDockItem", url: safari, parent: 3)]
        XCTAssertEqual(dock.url(), safari)
        XCTAssertEqual(dock.asked, ["limit 0 0.15", "elementAt 0", "limit 1 0.15", "describe 1", "limit 2 0.15", "describe 2"])
    }

    func testADockThatStopsAnsweringEndsTheSearchAtOnce() {
        let dock = FakeDock()
        dock.elements = [1: .init(subrole: "AXImage", url: nil, parent: 2), 2: .init(subrole: "AXApplicationDockItem", url: safari, parent: 3)]
        dock.silent = [1]
        XCTAssertNil(dock.url())
        XCTAssertEqual(dock.asked, ["limit 0 0.15", "elementAt 0", "limit 1 0.15", "describe 1"])

        let hung = FakeDock()
        hung.silent = [0]
        XCTAssertNil(hung.url())
        XCTAssertEqual(hung.asked, ["limit 0 0.15", "elementAt 0"])
    }

    func testTheSearchGoesAtMostThreeElementsUp() {
        let dock = FakeDock()
        dock.elements = [1: .init(subrole: "AXImage", url: nil, parent: 2), 2: .init(subrole: "AXGroup", url: nil, parent: 3),
                         3: .init(subrole: "AXList", url: nil, parent: 4),
                         4: .init(subrole: "AXApplicationDockItem", url: safari, parent: nil)]
        XCTAssertNil(dock.url())
        XCTAssertEqual(dock.asked.filter { $0.hasPrefix("describe") }, ["describe 1", "describe 2", "describe 3"])
        XCTAssertEqual(dock.asked.filter { $0.hasPrefix("limit") }, ["limit 0 0.15", "limit 1 0.15", "limit 2 0.15", "limit 3 0.15"])
    }

    func testNoIconNoApp() {
        let empty = FakeDock()
        empty.hit = nil
        XCTAssertNil(empty.url())
        XCTAssertEqual(empty.asked, ["limit 0 0.15", "elementAt 0"])

        // A separator or a folder: no parent to go on with.
        let separator = FakeDock()
        separator.elements = [1: .init(subrole: "AXSeparatorDockItem", url: nil, parent: nil)]
        XCTAssertNil(separator.url())

        // An app's icon that doesn't say where the app is.
        let nameless = FakeDock()
        nameless.elements = [1: .init(subrole: "AXApplicationDockItem", url: nil, parent: 2)]
        XCTAssertNil(nameless.url())
        XCTAssertEqual(nameless.asked.last, "describe 1")
    }
}
