import AppKit
import XCTest
@testable import Riffle

final class ThumbnailQueueTests: XCTestCase {
    private func request(_ wid: CGWindowID) -> ThumbnailService.Request {
        ThumbnailService.Request(wid: wid, frame: CGRect(x: 0, y: 0, width: 800, height: 600), isMinimized: false)
    }

    private func drain(_ queue: inout CaptureQueue, running: Int = 0, runningBackground: Int = 0) -> [CGWindowID] {
        var order = [CGWindowID]()
        while let (next, _) = queue.next(running: running, runningBackground: runningBackground) { order.append(next.wid) }
        return order
    }

    func testCardsOnScreenGoBeforeWarming() {
        var queue = CaptureQueue(limit: 3)
        queue.add([request(1), request(2), request(3)], priority: .background)
        queue.add([request(10), request(11)], priority: .interactive)
        XCTAssertEqual(drain(&queue), [10, 11, 1, 2, 3])
    }

    func testNewestRequestsFirstAndNoDuplicates() {
        var queue = CaptureQueue(limit: 3)
        queue.add([request(1), request(2)], priority: .interactive)
        // The selection moved: the new selected card first, the rest in the order given.
        queue.add([request(2), request(3), request(2)], priority: .interactive)
        XCTAssertEqual(drain(&queue), [2, 3, 1])
    }

    func testWarmingDoesNotDemoteACardOnScreen() {
        var queue = CaptureQueue(limit: 3)
        queue.add([request(1)], priority: .interactive)
        queue.add([request(1), request(2)], priority: .background)
        let first = queue.next(running: 0, runningBackground: 0)
        XCTAssertEqual(first?.0.wid, 1)
        XCTAssertEqual(first?.1, .interactive)
        XCTAssertEqual(queue.next(running: 1, runningBackground: 0)?.1, .background)
    }

    func testWarmingNeverTakesTheLastSlot() {
        var queue = CaptureQueue(limit: 3)
        queue.add([request(1), request(2), request(3)], priority: .background)
        XCTAssertNotNil(queue.next(running: 1, runningBackground: 1))
        XCTAssertNil(queue.next(running: 2, runningBackground: 2))
        // A card on screen still gets that slot.
        queue.add([request(9)], priority: .interactive)
        XCTAssertEqual(queue.next(running: 2, runningBackground: 2)?.0.wid, 9)
        XCTAssertNil(queue.next(running: 3, runningBackground: 2))
    }

    func testLargeCaptureMatchesTheScreen() {
        let retina = (frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: CGFloat(2))
        let external = (frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), scale: CGFloat(1))
        // On a Retina display: twice its size in points.
        XCTAssertEqual(ThumbnailService.largeCaptureSize(frame: CGRect(x: 100, y: 100, width: 800, height: 600), screens: [retina, external], maxSide: 3000),
                       CGSize(width: 1600, height: 1200))
        // On a standard display: its size, not double.
        XCTAssertEqual(ThumbnailService.largeCaptureSize(frame: CGRect(x: 1600, y: 100, width: 1200, height: 800), screens: [retina, external], maxSide: 3000),
                       CGSize(width: 1200, height: 800))
        // Bigger than its screen: never more pixels than the screen has.
        let huge = ThumbnailService.largeCaptureSize(frame: CGRect(x: 0, y: 0, width: 3024, height: 1964), screens: [retina], maxSide: 10_000)
        XCTAssertEqual(huge, CGSize(width: 3024, height: 1964))
        // Spanning two screens: sized for the one it is mostly on.
        let spanning = ThumbnailService.largeCaptureSize(frame: CGRect(x: 1000, y: 0, width: 2000, height: 900), screens: [retina, external], maxSide: 10_000)
        XCTAssertEqual(spanning, CGSize(width: 2000, height: 900))
        // And never past the caller's limit, keeping the shape.
        let limited = ThumbnailService.largeCaptureSize(frame: CGRect(x: 0, y: 0, width: 1500, height: 900), screens: [retina], maxSide: 1000)
        XCTAssertEqual(limited.width, 1000)
        XCTAssertEqual(limited.height, 600)
    }

    func testCaptureBatchReportsBursts() {
        var batch = CaptureBatch()
        batch.begin(at: 100)
        for _ in 0..<3 { batch.record(0.02) }
        XCTAssertNil(batch.finish(at: 100.1))
        batch.begin(at: 200)
        for _ in 0..<6 { batch.record(0.03) }
        let summary = batch.finish(at: 200.12)
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.contains("6 captured in 120 ms") ?? false, summary ?? "")
    }
}
