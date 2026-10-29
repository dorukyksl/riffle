import Carbon
import Cocoa

/// Global shortcuts through Carbon's `RegisterEventHotKey`: the system matches them before any app sees the
/// keystroke, they keep working while Riffle's own panel is key, and they need no permission at all.
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    struct Failure {
        let description: String
        let status: OSStatus
    }

    /// What it asks of Carbon, replaceable in tests: they must never register a real global shortcut.
    struct System {
        /// Installs the handler every hot key event goes through; true once it's in.
        var installHandler: () -> Bool
        var register: (_ keyCode: UInt32, _ modifiers: CarbonModifiers, _ id: EventHotKeyID) -> (OSStatus, EventHotKeyRef?)
        var unregister: (EventHotKeyRef) -> Void
        var registrationFailed: (_ keyCode: UInt32, _ modifiers: CarbonModifiers, _ status: OSStatus) -> Void
    }

    private struct Binding {
        let reference: EventHotKeyRef
        let onPress: () -> Void
        let onRelease: (() -> Void)?
    }

    private let system: System
    private var handlerInstalled = false
    private var bindings = [UInt32: Binding]()
    /// How many keystrokes are registered right now.
    var registrationCount: Int { bindings.count }
    private var nextID: UInt32 = 1
    private let signature: OSType = 0x5246_464C // "RFFL"

    init(system: System = .carbon) {
        self.system = system
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = system.installHandler()
    }

    /// Returns `noErr`, or e.g. `eventHotKeyExistsErr` when another app already owns the shortcut.
    @discardableResult
    func register(keyCode: UInt32, modifiers: CarbonModifiers, onPress: @escaping () -> Void, onRelease: (() -> Void)? = nil) -> OSStatus {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        let (status, reference) = system.register(keyCode, modifiers, EventHotKeyID(signature: signature, id: id))
        if status == noErr, let reference {
            bindings[id] = Binding(reference: reference, onPress: onPress, onRelease: onRelease)
        } else {
            system.registrationFailed(keyCode, modifiers, status)
        }
        return status
    }

    func unregisterAll() {
        for binding in bindings.values { system.unregister(binding.reference) }
        bindings.removeAll()
    }

    /// A hot key went down or up (from the Carbon handler).
    func dispatch(id: UInt32, pressed: Bool) {
        guard let binding = bindings[id] else { return }
        if pressed { binding.onPress() } else { binding.onRelease?() }
    }
}

extension HotkeyCenter.System {
    static let carbon = HotkeyCenter.System(
        installHandler: {
            var types = [
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
            ]
            var handler: EventHandlerRef?
            let status = InstallEventHandler(GetEventDispatcherTarget(), riffleHotKeyHandler, types.count, &types, nil, &handler)
            if status != noErr { Log.error("InstallEventHandler failed: \(status)") }
            return handler != nil
        },
        register: { keyCode, modifiers, id in
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(keyCode, modifiers.rawValue, id, GetEventDispatcherTarget(), OptionBits(0), &reference)
            return (status, reference)
        },
        unregister: { _ = UnregisterEventHotKey($0) },
        registrationFailed: { keyCode, modifiers, status in
            Log.warn("RegisterEventHotKey \(KeyCodes.shortcutDescription(modifiers: modifiers, keyCode: keyCode)) failed: \(status)")
        }
    )
}

private func riffleHotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return status }
    let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    HotkeyCenter.shared.dispatch(id: hotKeyID.id, pressed: pressed)
    return noErr
}
