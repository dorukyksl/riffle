import Cocoa

typealias CGSConnectionID = UInt32
typealias CGSSpaceID = UInt64

/// The private SkyLight / HIServices calls a window switcher needs on macOS: Spaces, window lists and capture, and
/// moving focus across apps, none of which has a public API.
///
/// Everything is resolved with `dlsym` instead of being linked: if a future macOS drops a symbol, the
/// feature that needs it degrades gracefully instead of Riffle crashing at launch.
enum PrivateAPI {
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT

    private static func resolve<T>(_ name: String, _ type: T.Type) -> T? {
        var pointer: UnsafeMutableRawPointer?
        if let skyLight { pointer = dlsym(skyLight, name) }
        if pointer == nil { pointer = dlsym(defaultHandle, name) }
        guard let pointer else {
            Log.warn("private symbol unavailable: \(name)")
            return nil
        }
        return unsafeBitCast(pointer, to: type)
    }

    // MARK: - Signatures

    private typealias MainConnectionIDFn = @convention(c) () -> CGSConnectionID
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?
    private typealias CopyWindowsWithOptionsAndTagsFn = @convention(c) (
        CGSConnectionID, Int32, CFArray, Int32, UnsafeMutablePointer<Int64>, UnsafeMutablePointer<Int64>
    ) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindowsFn = @convention(c) (CGSConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias CopyActiveMenuBarDisplayIdentifierFn = @convention(c) (CGSConnectionID) -> Unmanaged<CFString>?
    private typealias HWCaptureWindowListFn = @convention(c) (
        CGSConnectionID, UnsafeMutablePointer<CGWindowID>, UInt32, UInt32
    ) -> Unmanaged<CFArray>?
    private typealias SetFrontProcessWithOptionsFn = @convention(c) (
        UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32
    ) -> CGError
    private typealias PostEventRecordToFn = @convention(c) (
        UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>
    ) -> CGError
    private typealias SpaceSetFrontPSNFn = @convention(c) (CGSConnectionID, CGSSpaceID, ProcessSerialNumber) -> CGError
    private typealias SetSymbolicHotKeyEnabledFn = @convention(c) (Int32, Bool) -> CGError
    private typealias IsSymbolicHotKeyEnabledFn = @convention(c) (Int32) -> Bool
    private typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias AXCreateWithRemoteTokenFn = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    private typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    private static let mainConnectionID = resolve("CGSMainConnectionID", MainConnectionIDFn.self)
    private static let copyManagedDisplaySpaces = resolve("CGSCopyManagedDisplaySpaces", CopyManagedDisplaySpacesFn.self)
    private static let copyWindowsWithOptionsAndTags = resolve("CGSCopyWindowsWithOptionsAndTags", CopyWindowsWithOptionsAndTagsFn.self)
    private static let copySpacesForWindows = resolve("CGSCopySpacesForWindows", CopySpacesForWindowsFn.self)
    private static let copyActiveMenuBarDisplayIdentifier = resolve("CGSCopyActiveMenuBarDisplayIdentifier", CopyActiveMenuBarDisplayIdentifierFn.self)
    private static let hwCaptureWindowList = resolve("CGSHWCaptureWindowList", HWCaptureWindowListFn.self)
    private static let setFrontProcessWithOptions = resolve("_SLPSSetFrontProcessWithOptions", SetFrontProcessWithOptionsFn.self)
    private static let postEventRecordTo = resolve("SLPSPostEventRecordTo", PostEventRecordToFn.self)
    private static let spaceSetFrontPSN = resolve("SLSSpaceSetFrontPSN", SpaceSetFrontPSNFn.self)
    private static let setSymbolicHotKeyEnabled = resolve("CGSSetSymbolicHotKeyEnabled", SetSymbolicHotKeyEnabledFn.self)
    private static let isSymbolicHotKeyEnabled = resolve("CGSIsSymbolicHotKeyEnabled", IsSymbolicHotKeyEnabledFn.self)
    private static let axGetWindow = resolve("_AXUIElementGetWindow", AXGetWindowFn.self)
    private static let axCreateWithRemoteToken = resolve("_AXUIElementCreateWithRemoteToken", AXCreateWithRemoteTokenFn.self)
    private static let getProcessForPID = resolve("GetProcessForPID", GetProcessForPIDFn.self)

    /// Our connection to the WindowServer. Every CGS/SLS call needs it.
    static let connection: CGSConnectionID = mainConnectionID?() ?? 0

    // MARK: - Spaces

    /// One dictionary per display: "Display Identifier", "Current Space" and "Spaces" (each with "id64" and "type";
    /// type 4 is a fullscreen Space).
    static func managedDisplaySpaces() -> [NSDictionary] {
        copyManagedDisplaySpaces?(connection)?.takeRetainedValue() as? [NSDictionary] ?? []
    }

    /// Window ids in the given Spaces, top-most first. `includeInvisible` also returns ordered-out windows
    /// (minimized, hidden apps) that still belong to those Spaces.
    static func windowIDs(inSpaces spaces: [CGSSpaceID], includeInvisible: Bool) -> [CGWindowID] {
        guard let fn = copyWindowsWithOptionsAndTags, !spaces.isEmpty else { return [] }
        var setTags: Int64 = 0
        var clearTags: Int64 = 0
        var options: Int32 = 1 << 1 // windows of apps assigned to all Spaces
        if includeInvisible { options |= (1 << 0) | (1 << 2) }
        let spaceNumbers = spaces.map { NSNumber(value: $0) } as CFArray
        let result = fn(connection, 0, spaceNumbers, options, &setTags, &clearTags)?.takeRetainedValue() as? [NSNumber]
        return result?.map { $0.uint32Value } ?? []
    }

    static func spaces(forWindow wid: CGWindowID) -> [CGSSpaceID] {
        guard let fn = copySpacesForWindows else { return [] }
        let ids = [NSNumber(value: wid)] as CFArray
        let result = fn(connection, 7 /* all Spaces */, ids)?.takeRetainedValue() as? [NSNumber]
        return result?.map { $0.uint64Value } ?? []
    }

    /// UUID of the display whose menu bar is active (the one the user is working on).
    static func activeMenuBarDisplayUUID() -> String? {
        copyActiveMenuBarDisplayIdentifier?(connection)?.takeRetainedValue() as String?
    }

    // MARK: - Capture

    /// WindowServer-side screenshot of one window. Unlike ScreenCaptureKit it can also capture minimized
    /// windows, so we use it as a fallback.
    static func captureWindow(_ wid: CGWindowID) -> CGImage? {
        guard let fn = hwCaptureWindowList else { return nil }
        var windowID = wid
        let options: UInt32 = (1 << 11) /* ignore global clip shape */ | (1 << 8) /* best resolution */ | (1 << 19) /* full size */
        let images = fn(connection, &windowID, 1, options)?.takeRetainedValue() as? [CGImage]
        return images?.first
    }

    // MARK: - Focus

    static func processSerialNumber(for pid: pid_t) -> ProcessSerialNumber? {
        guard let fn = getProcessForPID else { return nil }
        var psn = ProcessSerialNumber()
        return fn(pid, &psn) == noErr ? psn : nil
    }

    /// Fronts the process and raises only `wid` (not every window of the app). For a window on another Space,
    /// macOS also switches to that Space. 0x200 marks the switch as user-generated.
    @discardableResult
    static func setFrontProcess(_ psn: inout ProcessSerialNumber, window wid: CGWindowID) -> Bool {
        guard let fn = setFrontProcessWithOptions else { return false }
        return fn(&psn, wid, 0x200) == .success
    }

    /// Makes `wid` the key window of its app by posting a synthetic mouse-down record to the WindowServer.
    /// No public API moves key focus across apps. About the record:
    /// - the buffer is 0x100 bytes although the record is 0xf8: macOS 14.7.4+ reads past the record;
    /// - only the mouse-DOWN is posted, so no control can ever be clicked;
    /// - the click point sits far past the bottom-right of any window, away from content and resize handles.
    static func makeKeyWindow(_ psn: inout ProcessSerialNumber, window wid: CGWindowID) {
        guard let fn = postEventRecordTo else { return }
        var bytes = [UInt8](repeating: 0, count: 0x100)
        bytes[0x04] = 0xF8 // record length
        bytes[0x08] = 0x01 // kCGEventLeftMouseDown
        bytes[0x3A] = 0x10
        var windowID = wid
        var point = CGPoint(x: 300_000, y: 300_000)
        withUnsafeBytes(of: &windowID) { raw in
            for index in 0..<raw.count { bytes[0x3C + index] = raw[index] }
        }
        withUnsafeBytes(of: &point) { raw in
            for index in 0..<raw.count { bytes[0x20 + index] = raw[index] }
        }
        bytes.withUnsafeMutableBufferPointer { buffer in
            _ = fn(&psn, buffer.baseAddress!)
        }
    }

    /// Restores which process a Space considers front. Fronting a window on another Space makes macOS remember
    /// that app as the front one of the Space we left; this undoes that.
    static func setSpaceFrontProcess(_ space: CGSSpaceID, _ psn: ProcessSerialNumber) {
        _ = spaceSetFrontPSN?(connection, space, psn)
    }

    // MARK: - Native ⌘⇥

    enum SymbolicHotKey: Int32 {
        case commandTab = 1
        case commandShiftTab = 2
    }

    /// Note: the enabled state survives our process. Callers must restore it (see NativeCommandTab).
    static func setSymbolicHotKey(_ hotKey: SymbolicHotKey, enabled: Bool) {
        _ = setSymbolicHotKeyEnabled?(hotKey.rawValue, enabled)
    }

    static func isSymbolicHotKeyEnabled(_ hotKey: SymbolicHotKey) -> Bool? {
        isSymbolicHotKeyEnabled?(hotKey.rawValue)
    }

    /// The raw call, for `CrashGuard`: a signal handler can only use what was resolved before it ran.
    static var symbolicHotKeySetter: (@convention(c) (Int32, Bool) -> CGError)? { setSymbolicHotKeyEnabled }

    // MARK: - Accessibility

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let fn = axGetWindow else { return nil }
        var wid: CGWindowID = 0
        return fn(element, &wid) == .success && wid != 0 ? wid : nil
    }

    /// Builds an element from a raw remote token: pid (4 bytes) + 0 (4) + "coco" magic (4) + element id (8).
    /// This is the only way to reach windows that sit on other Spaces, which `kAXWindows` omits.
    static func element(fromRemoteToken token: CFData) -> AXUIElement? {
        axCreateWithRemoteToken?(token)?.takeRetainedValue()
    }
}
