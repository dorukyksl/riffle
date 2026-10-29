import Carbon
import XCTest
@testable import Riffle

/// HotkeyCenter's bookkeeping, against a stand-in for Carbon: a real registration would take the shortcut system-wide.
final class HotkeyCenterTests: XCTestCase {
    private final class FakeCarbon {
        var handlerInstalls = 0
        var installSucceeds = true
        var registered = [(keyCode: UInt32, modifiers: CarbonModifiers, id: EventHotKeyID)]()
        var unregistered = [EventHotKeyRef]()
        var failures = [(keyCode: UInt32, status: OSStatus)]()
        /// Keystrokes another app already owns.
        var taken = Set<UInt32>()

        var system: HotkeyCenter.System {
            HotkeyCenter.System(
                installHandler: {
                    self.handlerInstalls += 1
                    return self.installSucceeds
                },
                register: { keyCode, modifiers, id in
                    self.registered.append((keyCode, modifiers, id))
                    if self.taken.contains(keyCode) { return (OSStatus(eventHotKeyExistsErr), nil) }
                    return (noErr, OpaquePointer(bitPattern: Int(id.id)))
                },
                unregister: { self.unregistered.append($0) },
                registrationFailed: { keyCode, _, status in self.failures.append((keyCode, status)) })
        }
    }

    func testRegistrationsGetFreshIdsUnderRifflesSignature() {
        let carbon = FakeCarbon()
        let center = HotkeyCenter(system: carbon.system)
        XCTAssertEqual(center.register(keyCode: KeyCodes.tab, modifiers: .option, onPress: {}), noErr)
        XCTAssertEqual(center.register(keyCode: KeyCodes.tab, modifiers: [.option, .shift], onPress: {}), noErr)
        XCTAssertEqual(carbon.registered.map(\.id.id), [1, 2])
        XCTAssertEqual(Set(carbon.registered.map(\.id.signature)), [0x5246_464C])
        XCTAssertEqual(carbon.registered.map(\.modifiers), [.option, [.option, .shift]])
        XCTAssertEqual(center.registrationCount, 2)
    }

    func testTheHandlerIsInstalledOnceAndRetriedIfItFailed() {
        let carbon = FakeCarbon()
        carbon.installSucceeds = false
        let center = HotkeyCenter(system: carbon.system)
        center.register(keyCode: KeyCodes.tab, modifiers: .option, onPress: {})
        XCTAssertEqual(carbon.handlerInstalls, 1)
        carbon.installSucceeds = true
        center.register(keyCode: KeyCodes.space, modifiers: .option, onPress: {})
        center.register(keyCode: KeyCodes.tab, modifiers: .command, onPress: {})
        XCTAssertEqual(carbon.handlerInstalls, 2)
    }

    func testAShortcutAnotherAppOwnsIsReportedAndNotKept() {
        let carbon = FakeCarbon()
        carbon.taken = [KeyCodes.space]
        let center = HotkeyCenter(system: carbon.system)
        var pressed = false
        XCTAssertEqual(center.register(keyCode: KeyCodes.space, modifiers: .option, onPress: { pressed = true }),
                       OSStatus(eventHotKeyExistsErr))
        XCTAssertEqual(center.registrationCount, 0)
        XCTAssertEqual(carbon.failures.map(\.keyCode), [KeyCodes.space])
        XCTAssertEqual(carbon.failures.map(\.status), [OSStatus(eventHotKeyExistsErr)])
        center.dispatch(id: 1, pressed: true)
        XCTAssertFalse(pressed)
    }

    func testPressAndReleaseReachTheirShortcut() {
        let center = HotkeyCenter(system: FakeCarbon().system)
        var events = [String]()
        center.register(keyCode: KeyCodes.tab, modifiers: .option, onPress: { events.append("tab down") }, onRelease: { events.append("tab up") })
        center.register(keyCode: KeyCodes.space, modifiers: .option, onPress: { events.append("space down") })
        center.dispatch(id: 2, pressed: true)
        center.dispatch(id: 2, pressed: false) // no release handler: nothing
        center.dispatch(id: 1, pressed: true)
        center.dispatch(id: 1, pressed: false)
        center.dispatch(id: 99, pressed: true) // not ours
        XCTAssertEqual(events, ["space down", "tab down", "tab up"])
    }

    func testUnregisteringReleasesEveryShortcutAndIdsAreNotReused() {
        let carbon = FakeCarbon()
        let center = HotkeyCenter(system: carbon.system)
        var pressed = 0
        center.register(keyCode: KeyCodes.tab, modifiers: .option, onPress: { pressed += 1 })
        center.register(keyCode: KeyCodes.space, modifiers: .option, onPress: { pressed += 1 })
        center.unregisterAll()
        XCTAssertEqual(Set(carbon.unregistered.map { Int(bitPattern: $0) }), [1, 2])
        XCTAssertEqual(center.registrationCount, 0)
        center.dispatch(id: 1, pressed: true)
        XCTAssertEqual(pressed, 0)
        // A stale event for an old id can't reach a new shortcut.
        center.register(keyCode: KeyCodes.tab, modifiers: .command, onPress: { pressed += 10 })
        XCTAssertEqual(carbon.registered.last?.id.id, 3)
        center.dispatch(id: 1, pressed: true)
        center.dispatch(id: 3, pressed: true)
        XCTAssertEqual(pressed, 10)
    }
}
