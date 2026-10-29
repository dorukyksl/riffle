import XCTest
@testable import Riffle

/// The diagnostic and test modes (`--diag`, `--e2e`, `--diag-windows`…) read with Riffle's permissions, and any local
/// process can start the installed app with them: what they write may name no window and no app, and none of them may
/// save the settings it changes on the way.
final class DiagnosticsPrivacyTests: XCTestCase {
    private let support = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Riffle/Support", isDirectory: true)

    // MARK: - The records

    func testAWindowIsRecordedWithoutItsTitle() throws {
        let window = TrackedWindow(wid: 42, pid: 7, app: nil, element: nil, title: "Payslip — March", isMinimized: true, isFullscreen: false,
                                   frame: CGRect(x: 10, y: 20, width: 800, height: 600), spaceIDs: [3], focusStamp: 9)
        let record = DiagnosticRecord.window(window)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
        XCTAssertFalse(json.contains("Payslip"), json)
        XCTAssertNil(record["title"])
        XCTAssertEqual(record["titleLength"] as? Int, 15)
        XCTAssertEqual(record["app"] as? String, "pid 7")
        XCTAssertEqual(record["wid"] as? CGWindowID, 42)
    }

    func testARowNamesItsAppByBundleIdentifierAndItsTitleByLength() {
        func item(_ kind: SwitcherItem.Kind, title: String, bundleID: String?) -> SwitcherItem {
            SwitcherItem(kind: kind, pid: 7, appName: "Secret Diary", title: title, icon: NSImage(), isMinimized: false, isHidden: false,
                         isFullscreen: false, otherSpaceIndex: nil, frame: .zero, bundleID: bundleID)
        }
        XCTAssertEqual(DiagnosticRecord.row(item(.window(42), title: "Dear diary", bundleID: "com.example.diary")),
                       "com.example.diary #42 titleLength=10")
        XCTAssertEqual(DiagnosticRecord.row(item(.app(7), title: "", bundleID: nil)), "pid 7 without windows titleLength=0")
    }

    func testAnAppIsRecordedByItsBundleIdentifier() {
        let current = NSRunningApplication.current
        let expected = current.bundleIdentifier ?? "pid \(current.processIdentifier)"
        XCTAssertEqual(DiagnosticRecord.app(current), expected)
        XCTAssertEqual(DiagnosticRecord.app(TrackedApp(current), pid: current.processIdentifier), expected)
        XCTAssertEqual(DiagnosticRecord.app(nil as TrackedApp?, pid: 12), "pid 12")
        XCTAssertEqual(DiagnosticRecord.app(nil as NSRunningApplication?), "?")
    }

    func testAFullScreenSpaceStillMakesValidJSON() {
        var topology = SpaceTopology()
        topology.spaces = [SpaceInfo(id: 1, index: 1, displayUUID: "A", isFullscreen: false, desktopNumber: 1),
                           SpaceInfo(id: 2, index: 2, displayUUID: "A", isFullscreen: true, desktopNumber: nil)]
        topology.visibleSpaceIDs = [2]
        let records = topology.spaces.map { DiagnosticRecord.space($0, in: topology) }
        // A nil in there would make the whole report unwritable.
        XCTAssertTrue(JSONSerialization.isValidJSONObject(records))
        XCTAssertEqual(records[0]["desktop"] as? Int, 1)
        XCTAssertTrue(records[1]["desktop"] is NSNull)
        XCTAssertEqual(records.map { $0["visible"] as? Bool }, [false, true])
    }

    // MARK: - The sources

    /// The files that read the user's own windows and apps and write about them.
    private let writers = ["Diagnostics.swift", "EndToEnd.swift", "WindowAudit.swift", "DiagnosticRecord.swift"]

    /// Uses that never leave memory: a title's length, telling the test helper's windows apart, the letters typed into the
    /// panel's search field, and finding the running Riffle's panel by its owner.
    private let inMemory = [".title.count", #".title.hasPrefix("Riffle Test")"#, #".title.contains(""#, #"?.name ?? "a").prefix(3)"#,
                            #"[kCGWindowOwnerName as String] as? String) == "Riffle""#]

    func testNothingWrittenNamesAWindowOrAnApp() throws {
        let personal = try NSRegularExpression(
            pattern: #"\.(name|appName|localizedName|title|displayTitle|windowTitle)\b|kCGWindowName|kCGWindowOwnerName"#)
        var checked = 0
        for name in writers {
            let source = try String(contentsOf: support.appendingPathComponent(name), encoding: .utf8)
            for (index, line) in source.components(separatedBy: "\n").enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//") else { continue }
                checked += 1
                let text = inMemory.reduce(line) { $0.replacingOccurrences(of: $1, with: "") }
                XCTAssertNil(personal.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                             "\(name):\(index + 1) may write a title or an app's name (use DiagnosticRecord): \(code)")
            }
        }
        XCTAssertGreaterThan(checked, 400)
    }

    /// Every mode stops settings from being saved before it touches anything else, so that one cut short leaves the
    /// user's settings as they were.
    func testNoModeSavesSettings() throws {
        let files = try FileManager.default.contentsOfDirectory(at: support, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        // The modes' entry points (`Diagnostics.run`, `EndToEnd.runSpaces`…), not their private helpers.
        let start = try NSRegularExpression(pattern: #"^    static func run\w*\("#, options: .anchorsMatchLines)
        var modes = 0
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in start.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                guard let range = Range(match.range, in: source) else { continue }
                let rest = source[range.upperBound...]
                // Up to the next declaration at its level.
                let end = ["\n    static func ", "\n    private static func ", "\n}"].compactMap { rest.range(of: $0)?.lowerBound }.min()
                let body = rest[..<(end ?? rest.endIndex)]
                let line = source[..<range.lowerBound].components(separatedBy: "\n").count
                let header = "\(file.lastPathComponent):\(line) \(source[range].trimmingCharacters(in: .whitespaces).dropLast())"
                modes += 1
                guard let off = body.range(of: "Prefs.persists = false") else {
                    XCTFail("\(header) can save settings")
                    continue
                }
                if let shared = body.range(of: ".shared") {
                    XCTAssertLessThan(off.lowerBound, shared.lowerBound, "\(header) touches .shared before it stops saving")
                }
            }
        }
        XCTAssertGreaterThanOrEqual(modes, 14)
    }
}
