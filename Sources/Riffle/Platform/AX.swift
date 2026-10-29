import Cocoa

let kAXFullScreenAttribute = "AXFullScreen"

extension AXUIElement {
    func value(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    func string(_ attribute: String) -> String? {
        value(attribute) as? String
    }

    func bool(_ attribute: String) -> Bool? {
        guard let value = value(attribute), CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    func element(_ attribute: String) -> AXUIElement? {
        guard let value = value(attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func elements(_ attribute: String) -> [AXUIElement] {
        guard let value = value(attribute), CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    var windowID: CGWindowID? { PrivateAPI.windowID(of: self) }

    func setMessagingTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(self, seconds)
    }

    @discardableResult
    func set(_ attribute: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(self, attribute as CFString, value)
    }

    @discardableResult
    func perform(_ action: String) -> AXError {
        AXUIElementPerformAction(self, action as CFString)
    }

    /// Reads several attributes in a single IPC round trip. Attributes the app could not answer are absent.
    func values(_ attributes: [String]) -> [String: CFTypeRef]? {
        values(attributes, error: nil)
    }

    func values(_ attributes: [String], error: UnsafeMutablePointer<AXError>?) -> [String: CFTypeRef]? {
        var raw: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(self, attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
        error?.pointee = status
        guard status == .success, let array = raw as? [CFTypeRef] else { return nil }
        var result = [String: CFTypeRef]()
        for (index, name) in attributes.enumerated() where index < array.count {
            let value = array[index]
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { continue }
            result[name] = value
        }
        return result
    }
}

/// Lets AX elements live in dictionaries and sets (`CFEqual` / `CFHash` semantics).
struct AXElementKey: Hashable {
    let element: AXUIElement
    static func == (lhs: AXElementKey, rhs: AXElementKey) -> Bool { CFEqual(lhs.element, rhs.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

/// Everything Riffle needs to know about one AX window, read in one round trip.
struct AXWindowSnapshot {
    let element: AXUIElement
    let wid: CGWindowID
    let role: String?
    let subrole: String?
    let title: String
    let isMinimized: Bool
    let isFullscreen: Bool
    let isMain: Bool
    let frame: CGRect?
}

enum AXReader {
    private static let windowAttributes: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXMinimizedAttribute,
        kAXFullScreenAttribute, kAXMainAttribute, kAXPositionAttribute, kAXSizeAttribute,
    ]

    enum Read {
        case window(AXWindowSnapshot)
        /// The app didn't answer in time: nothing can be said about the window.
        case busy
        /// Not (or no longer) a readable window.
        case gone
    }

    static func snapshot(of element: AXUIElement, knownWID: CGWindowID? = nil) -> AXWindowSnapshot? {
        if case .window(let snapshot) = read(element, knownWID: knownWID) { return snapshot }
        return nil
    }

    static func read(_ element: AXUIElement, knownWID: CGWindowID? = nil) -> Read {
        guard let wid = knownWID ?? element.windowID else { return .gone }
        // One round trip normally. If the batch fails as a whole for another reason than a busy app (one attribute the
        // app chokes on), ask one by one and make do with what answers; role and subrole are the minimum.
        var error = AXError.success
        var batch = element.values(windowAttributes, error: &error)
        if batch == nil {
            if error == .cannotComplete { return .busy }
            var single = [String: CFTypeRef]()
            for attribute in windowAttributes {
                var value: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
                if status == .cannotComplete { return .busy }
                if status == .success, let value { single[attribute] = value }
            }
            batch = single[kAXRoleAttribute] == nil && single[kAXSubroleAttribute] == nil ? nil : single
        }
        guard let values = batch else { return .gone }
        func string(_ key: String) -> String? { values[key] as? String }
        func bool(_ key: String) -> Bool {
            guard let value = values[key], CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
            return CFBooleanGetValue((value as! CFBoolean))
        }
        var frame: CGRect?
        if let position = values[kAXPositionAttribute], let size = values[kAXSizeAttribute],
           CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
            var origin = CGPoint.zero
            var extent = CGSize.zero
            if AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent) {
                frame = CGRect(origin: origin, size: extent)
            }
        }
        return .window(AXWindowSnapshot(
            element: element,
            wid: wid,
            role: string(kAXRoleAttribute),
            subrole: string(kAXSubroleAttribute),
            title: string(kAXTitleAttribute) ?? "",
            isMinimized: bool(kAXMinimizedAttribute),
            isFullscreen: bool(kAXFullScreenAttribute),
            isMain: bool(kAXMainAttribute),
            frame: frame
        ))
    }

    enum AppWindowsResult {
        case windows([AXUIElement])
        case unresponsive
        case unsupported
    }

    /// `kAXWindows` only lists the current Space; the focused and main windows are not Space-filtered, so we merge them in.
    static func windows(ofApp app: AXUIElement) -> AppWindowsResult {
        var raw: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            app, [kAXWindowsAttribute, kAXFocusedWindowAttribute, kAXMainWindowAttribute] as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
        switch error {
        case .success: break
        case .cannotComplete: return .unresponsive
        default: return .unsupported
        }
        guard let values = raw as? [CFTypeRef] else { return .windows([]) }
        var result = [AXUIElement]()
        var seen = Set<AXElementKey>()
        func add(_ element: AXUIElement) {
            if seen.insert(AXElementKey(element: element)).inserted { result.append(element) }
        }
        for value in values {
            if CFGetTypeID(value) == CFArrayGetTypeID(), let list = value as? [AXUIElement] {
                list.forEach(add)
            } else if CFGetTypeID(value) == AXUIElementGetTypeID() {
                add(value as! AXUIElement)
            }
        }
        return .windows(result)
    }

    static func focusedWindow(ofApp app: AXUIElement) -> AXUIElement? {
        app.element(kAXFocusedWindowAttribute)
    }

    /// Finds the AX elements of windows `kAXWindows` can't see (other Spaces) by walking element ids with remote
    /// tokens until every wanted window is found or the time budget runs out. Resumable through `startID`.
    static func bruteForceWindows(pid: pid_t, wanted: Set<CGWindowID>, startID: UInt64, budget: TimeInterval, limit: UInt64)
        -> (found: [CGWindowID: AXUIElement], nextID: UInt64) {
        var results = [CGWindowID: AXUIElement]()
        guard !wanted.isEmpty else { return (results, startID) }
        let deadline = ProcessInfo.processInfo.systemUptime + budget
        var candidate = startID
        while candidate < limit {
            // Checked on every probe: one probe into a busy app can take a good part of the budget.
            if ProcessInfo.processInfo.systemUptime > deadline { break }
            let token = RemoteToken(pid: pid, elementID: candidate)
            candidate += 1
            guard let element = PrivateAPI.element(fromRemoteToken: token.data) else { continue }
            element.setMessagingTimeout(0.2)
            // A window's descendants report their window's id too, so insist on the AXWindow root.
            guard let wid = element.windowID, wanted.contains(wid), results[wid] == nil,
                  element.string(kAXRoleAttribute) == kAXWindowRole else { continue }
            results[wid] = element
            if results.count == wanted.count { break }
        }
        return (results, candidate)
    }
}

/// How the accessibility server names an element that lives in another process: 20 little-endian bytes holding the
/// process id, four zero bytes, the marker `0x636f636f`, and the element's 64-bit id.
struct RemoteToken {
    let pid: pid_t
    let elementID: UInt64

    var data: CFData {
        var bytes = [UInt8](repeating: 0, count: 20)
        func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { bytes.replaceSubrange(offset..<offset + MemoryLayout<T>.size, with: $0) }
        }
        put(Int32(pid), at: 0)
        put(UInt32(0x636f636f), at: 8)
        put(elementID, at: 12)
        return Data(bytes) as CFData
    }
}
