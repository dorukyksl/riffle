import AppKit
import XCTest
@testable import Riffle

/// Settings' key recorders, one at a time, and Riffle's shortcuts back however a recording ends. Against stand-ins for
/// the shortcuts and AppKit: a test must never let go of, or take, a real global shortcut.
final class KeyRecordingTests: XCTestCase {
    private final class Fake {
        var pauses = 0
        var resumes = 0
        /// Event monitors in place, by token.
        var monitors = [Int: (NSEvent) -> NSEvent?]()
        private var lastMonitor = 0
        /// Settings' window, as far as notifications go.
        let settings = NSObject()
        lazy var keyWindow: AnyObject? = settings
        let notifications = NotificationCenter()

        /// The shortcuts are let go exactly while something records.
        var shortcutsAreOff: Bool { pauses > resumes }

        var system: KeyRecording.System {
            KeyRecording.System(
                pauseShortcuts: { self.pauses += 1 },
                resumeShortcuts: { self.resumes += 1 },
                addMonitor: { _, handle in
                    self.lastMonitor += 1
                    self.monitors[self.lastMonitor] = handle
                    return self.lastMonitor
                },
                removeMonitor: { self.monitors[$0 as! Int] = nil },
                keyWindow: { self.keyWindow },
                notifications: notifications)
        }

        func post(_ name: Notification.Name, from object: AnyObject? = nil) {
            notifications.post(name: name, object: object)
        }
    }

    private let fake = Fake()
    private lazy var recording = KeyRecording(system: fake.system)
    private let first = UUID(), second = UUID()

    private func start(_ recorder: UUID, keys: @escaping (NSEvent) -> Void = { _ in }) {
        recording.start(recorder, events: .keyDown) { event in
            keys(event)
            return nil
        }
    }

    func testTheShortcutsAreOffOnlyWhileARecorderRecords() {
        XCTAssertFalse(recording.isRecording)
        start(first)
        XCTAssertEqual(recording.recorder, first)
        XCTAssertTrue(fake.shortcutsAreOff)
        XCTAssertEqual(fake.monitors.count, 1)
        // Esc, a key recorded or a second click: the recorder stops itself.
        recording.stop(first)
        XCTAssertNil(recording.recorder)
        XCTAssertFalse(fake.shortcutsAreOff)
        XCTAssertEqual(fake.resumes, 1)
        XCTAssertTrue(fake.monitors.isEmpty)
    }

    func testStartingAnotherRecorderStopsTheFirst() {
        start(first)
        start(second)
        XCTAssertEqual(recording.recorder, second)
        XCTAssertEqual(fake.monitors.count, 1, "the first one's monitor is gone")
        // Handed over: the shortcuts stayed off, and weren't registered in between.
        XCTAssertEqual(fake.pauses, 1)
        XCTAssertEqual(fake.resumes, 0)
        // The first one going away now changes nothing for the second.
        recording.stop(first)
        XCTAssertEqual(recording.recorder, second)
        XCTAssertTrue(fake.shortcutsAreOff)
        recording.stop(second)
        XCTAssertFalse(fake.shortcutsAreOff)
        XCTAssertEqual(fake.resumes, 1)
    }

    func testARecorderMovingToAnotherKeyKeepsTheShortcutsOff() {
        // The switcher keys' section records each command's key in turn.
        start(first)
        start(first)
        XCTAssertEqual(fake.pauses, 1)
        XCTAssertEqual(fake.resumes, 0)
        XCTAssertEqual(fake.monitors.count, 1)
        recording.stop(first)
        XCTAssertEqual(fake.resumes, 1)
    }

    func testSettingsLosingTheKeyboardEndsTheRecording() {
        start(first)
        // Another window (the switcher, say) giving up the keyboard isn't Settings doing so.
        fake.post(NSWindow.didResignKeyNotification, from: NSObject())
        XCTAssertTrue(recording.isRecording)
        fake.post(NSWindow.didResignKeyNotification, from: fake.settings)
        XCTAssertFalse(recording.isRecording)
        XCTAssertEqual(fake.resumes, 1)
        XCTAssertTrue(fake.monitors.isEmpty)
        // Ended once: the same notification again does nothing more.
        fake.post(NSWindow.didResignKeyNotification, from: fake.settings)
        XCTAssertEqual(fake.resumes, 1)
    }

    func testRiffleLosingTheKeyboardEndsTheRecording() {
        start(first)
        fake.post(NSApplication.didResignActiveNotification)
        XCTAssertFalse(recording.isRecording)
        XCTAssertFalse(fake.shortcutsAreOff)
        // Without a key window to watch, Riffle going to the background still ends it.
        fake.keyWindow = nil
        start(second)
        fake.post(NSWindow.didResignKeyNotification, from: fake.settings)
        XCTAssertTrue(recording.isRecording)
        fake.post(NSApplication.didResignActiveNotification)
        XCTAssertFalse(recording.isRecording)
        XCTAssertEqual(fake.resumes, 2)
    }

    func testARecorderGoingAwayOnlyEndsItsOwnRecording() {
        // Views disappear all the time; one that isn't recording must leave the shortcuts as they are.
        recording.stop(first)
        recording.stop()
        XCTAssertEqual(fake.resumes, 0)
        start(second)
        recording.stop(first)
        XCTAssertTrue(recording.isRecording)
        XCTAssertEqual(fake.resumes, 0)
    }

    func testKeysReachOnlyTheRecorderThatRecords() throws {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                           characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13) else {
            throw XCTSkip("no key event")
        }
        var heard = [String]()
        start(first) { _ in heard.append("first") }
        let firstMonitor = try XCTUnwrap(fake.monitors.values.first)
        start(second) { _ in heard.append("second") }
        let secondMonitor = try XCTUnwrap(fake.monitors.values.first)
        // An event the first monitor was already handed when it was removed goes on to the app untouched.
        XCTAssertTrue(firstMonitor(event) === event)
        XCTAssertNil(secondMonitor(event))
        XCTAssertEqual(heard, ["second"])
    }
}
