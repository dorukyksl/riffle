import AppKit
import XCTest
@testable import Riffle

final class RemoteTokenTests: XCTestCase {
    private func bytes(_ token: RemoteToken) -> [UInt8] {
        [UInt8](token.data as Data)
    }

    func testLayoutIsPidZerosMarkerAndElementIdLittleEndian() {
        let token = RemoteToken(pid: 0x0102_0304, elementID: 0x1122_3344_5566_7788)
        XCTAssertEqual(bytes(token), [
            0x04, 0x03, 0x02, 0x01, // pid
            0x00, 0x00, 0x00, 0x00,
            0x6F, 0x63, 0x6F, 0x63, // 0x636f636f, "coco"
            0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, // element id
        ])
    }

    func testExtremes() {
        XCTAssertEqual(bytes(RemoteToken(pid: 0, elementID: 0)), [0, 0, 0, 0, 0, 0, 0, 0, 0x6F, 0x63, 0x6F, 0x63] + Array(repeating: 0, count: 8))
        let last = bytes(RemoteToken(pid: Int32.max, elementID: UInt64.max))
        XCTAssertEqual(last.count, 20)
        XCTAssertEqual(Array(last[0..<4]), [0xFF, 0xFF, 0xFF, 0x7F])
        XCTAssertEqual(Array(last[12..<20]), Array(repeating: 0xFF, count: 8))
    }
}

final class AXElementKeyTests: XCTestCase {
    func testElementsForTheSameThingAreTheSameKey() {
        // Creating an application element asks nothing of the app and needs no permission.
        let first = AXElementKey(element: AXUIElementCreateApplication(getpid()))
        let again = AXElementKey(element: AXUIElementCreateApplication(getpid()))
        let other = AXElementKey(element: AXUIElementCreateApplication(1))
        XCTAssertEqual(first, again)
        XCTAssertNotEqual(first, other)
        XCTAssertEqual(Set([first, again, other]).count, 2)
    }
}

final class UtilityTests: XCTestCase {
    func testFormatCharactersAreDropped() {
        // Direction marks and isolates, as some apps put around names and titles.
        XCTAssertEqual("\u{200E}Safari\u{200F}".withoutFormatCharacters, "Safari")
        XCTAssertEqual("\u{202B}مرحبا\u{202C}".withoutFormatCharacters, "مرحبا")
        XCTAssertEqual("\u{2068}Report.pdf\u{2069} — Preview".withoutFormatCharacters, "Report.pdf — Preview")
        XCTAssertEqual("\u{FEFF}Notes".withoutFormatCharacters, "Notes")
        // Every embedding, override and isolate, the zero-width space, the word joiner and the soft hyphen.
        let invisible = "a\u{200B}b\u{2060}c\u{FEFF}d\u{00AD}e\u{202A}f\u{202B}g\u{202C}h\u{202D}i\u{202E}j\u{2066}k\u{2067}l\u{2068}m\u{2069}n\u{200E}o\u{200F}p"
        XCTAssertEqual(invisible.withoutFormatCharacters, "abcdefghijklmnop")
    }

    func testJoinersAndTagsHoldEmojiAndWordsTogether() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}" // 👨‍👩‍👧
        let developer = "\u{1F469}\u{1F3FD}\u{200D}\u{1F4BB}" // 👩🏽‍💻
        let scotland = "\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}" // 🏴󠁧󠁢󠁳󠁣󠁴󠁿
        let persian = "\u{0645}\u{06CC}\u{200C}\u{062E}\u{0648}\u{0627}\u{0647}\u{0645}" // می‌خواهم, with a non-joiner
        for text in [family, developer, scotland, persian, "\(family) Family — \(scotland) Glasgow"] {
            XCTAssertEqual(text.withoutFormatCharacters, text)
        }
        XCTAssertEqual(family.withoutFormatCharacters.count, 1)
        XCTAssertEqual(scotland.withoutFormatCharacters.count, 1)
        // Direction marks around a name still go; the emoji in it stays whole.
        XCTAssertEqual("\u{200F}\(developer) Ayşe\u{200E}".withoutFormatCharacters, "\(developer) Ayşe")
    }

    func testOrdinaryTextIsKept() {
        for text in ["Görüntü ayarları", "日本語のタイトル", "שלום", "Café ☕️ — 2 × 3", "", " spaced "] {
            XCTAssertEqual(text.withoutFormatCharacters, text)
        }
    }

    func testWindowNumbersThatAreNoWindowServerId() {
        XCTAssertEqual(NSWindow.cgWindowID(windowNumber: 1), 1)
        XCTAssertEqual(NSWindow.cgWindowID(windowNumber: Int(UInt32.max)), UInt32.max)
        XCTAssertNil(NSWindow.cgWindowID(windowNumber: 0))
        XCTAssertNil(NSWindow.cgWindowID(windowNumber: -1))
        // macOS 26's FrontBoard scenes report numbers past 32 bits.
        XCTAssertNil(NSWindow.cgWindowID(windowNumber: Int(UInt32.max) + 1))
        XCTAssertNil(NSWindow.cgWindowID(windowNumber: 0x1_0000_0002))
    }

    func testSafeSubscript() {
        let numbers = [10, 20, 30]
        XCTAssertEqual(numbers[safe: 0], 10)
        XCTAssertEqual(numbers[safe: 2], 30)
        XCTAssertNil(numbers[safe: 3])
        XCTAssertNil(numbers[safe: -1])
        XCTAssertNil([Int]()[safe: 0])
        // Slices keep their parent's indices.
        let tail = numbers[1...]
        XCTAssertNil(tail[safe: 0])
        XCTAssertEqual(tail[safe: 1], 20)
    }
}
