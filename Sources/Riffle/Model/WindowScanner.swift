import Cocoa

/// Physical facts the WindowServer knows about a window (public CoreGraphics API).
struct CGWindowDescription {
    let wid: CGWindowID
    let pid: pid_t
    let layer: Int
    let bounds: CGRect
    let alpha: Double
    let isOnScreen: Bool
    let name: String?
}

enum WindowServerInfo {
    static func describe(_ wids: [CGWindowID]) -> [CGWindowID: CGWindowDescription] {
        guard !wids.isEmpty else { return [:] }
        let pointers = wids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        let array = pointers.withUnsafeBufferPointer { buffer in
            CFArrayCreate(nil, UnsafeMutablePointer(mutating: buffer.baseAddress), buffer.count, nil)
        }
        guard let array, let list = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] else { return [:] }
        var result = [CGWindowID: CGWindowDescription]()
        for entry in list {
            guard let wid = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { continue }
            var bounds = CGRect.zero
            if let dictionary = entry[kCGWindowBounds as String] as? NSDictionary,
               let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary) {
                bounds = rect
            }
            result[wid] = CGWindowDescription(
                wid: wid,
                pid: pid,
                layer: (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                bounds: bounds,
                alpha: (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                isOnScreen: (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
                name: entry[kCGWindowName as String] as? String
            )
        }
        return result
    }
}

/// Global bounds (top-left origin) of every connected display, awake or asleep. Thread-safe.
enum DisplayBounds {
    static func online() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }
}

/// Decides whether an AX window is somewhere the user would want to switch to. Rules are ordered by
/// authority: panels, palettes and HUDs are out; standard windows, titled dialogs and an app's main window are in.
enum WindowEligibility {
    static let minimumSize = CGSize(width: 100, height: 50)
    /// Narrower or shorter than this, a surface is a helper (the 0×0 and 1×1 windows some frameworks keep around): a
    /// titled window can't get this small.
    static let phantomEdge: CGFloat = 20
    /// Below this the WindowServer draws nothing anyone could see.
    static let minimumAlpha: Double = 0.05

    static func admit(_ snapshot: AXWindowSnapshot, _ description: CGWindowDescription?) -> Bool {
        admit(snapshot, description, displays: DisplayBounds.online())
    }

    static func admit(_ snapshot: AXWindowSnapshot, _ description: CGWindowDescription?, displays: [CGRect]) -> Bool {
        // Unknown to the WindowServer: already closed, or not a real surface.
        guard let description else { return false }
        let subrole = snapshot.subrole
        if subrole == "AXFloatingWindow" || subrole == "AXSystemDialog" || subrole == "AXSystemFloatingWindow" { return false }
        // Above the normal level only the app's main window or a fullscreen window counts.
        guard description.layer == 0 || snapshot.isFullscreen || snapshot.isMain else { return false }
        if isPhantom(snapshot, description, displays: displays) { return false }
        let isSubstantial = description.bounds.width >= minimumSize.width && description.bounds.height >= minimumSize.height
        if snapshot.role == kAXWindowRole && snapshot.isMain { return true }
        if subrole == kAXStandardWindowSubrole { return true }
        if subrole == kAXDialogSubrole { return !snapshot.title.isEmpty }
        if snapshot.role == kAXWindowRole && !snapshot.title.isEmpty && isSubstantial { return true }
        return false
    }

    /// Transparent, (nearly) zero-size, or off every display: a helper surface, not a window. Minimized and full-screen
    /// windows never are (a minimized window isn't drawn where its bounds say).
    static func isPhantom(_ snapshot: AXWindowSnapshot, _ description: CGWindowDescription, displays: [CGRect]) -> Bool {
        guard !snapshot.isMinimized, !snapshot.isFullscreen else { return false }
        return isPhantomSurface(description, displays: displays)
    }

    /// No `displays` means they're unknown: then position isn't held against a surface.
    static func isPhantomSurface(_ description: CGWindowDescription, displays: [CGRect]) -> Bool {
        if description.alpha < minimumAlpha { return true }
        if description.bounds.width < phantomEdge || description.bounds.height < phantomEdge { return true }
        return !displays.isEmpty && !displays.contains { $0.intersects(description.bounds) }
    }

    /// Normal-level, window-sized, visible surfaces of other apps: the only ones worth an AX lookup when AX doesn't
    /// list them itself.
    static func isCandidate(_ description: CGWindowDescription, ownPID: pid_t, displays: [CGRect]) -> Bool {
        description.pid != ownPID && description.layer == 0
            && description.bounds.width >= minimumSize.width && description.bounds.height >= minimumSize.height
            && !isPhantomSurface(description, displays: displays)
    }
}

struct WindowRecord {
    let snapshot: AXWindowSnapshot
    let description: CGWindowDescription
    let spaces: [CGSSpaceID]
    /// Position in the WindowServer's stacking order (0 = top-most on a visible Space).
    let zIndex: Int
}

struct ScanResult {
    var topology: SpaceTopology
    var records: [WindowRecord]
    /// Apps this scan read. Windows of other apps are none of its business.
    var scannedPIDs: Set<pid_t>
    /// Apps that didn't answer completely (busy, an AX error, a window that couldn't be read, no answer before the
    /// deadline): keep what we know.
    var unresponsivePIDs: Set<pid_t>
    var cursors: [pid_t: UInt64]
    var unfindable: [pid_t: Set<CGWindowID>]
    /// Windows missing since the current sweep began at id 0 (only those can be called unfindable when it ends).
    var sweepPasses: [pid_t: Set<CGWindowID>]
    /// Apps not tracked yet that own real windows (menu bar apps, apps that got a Dock icon after launching).
    var newAppPIDs: [pid_t]
    var duration: TimeInterval
    /// Per app that answered (and per untracked owner probed): the candidate surfaces this scan settled (found, or
    /// unfindable after a whole sweep), and whether each was on screen.
    var examined: [pid_t: [CGWindowID: Bool]] = [:]
    /// Per app: candidates still being looked for (its sweep goes on).
    var missing: [pid_t: Set<CGWindowID>] = [:]
}

/// An inventory of switchable windows across every Space, for every app or for a few. Runs off the main thread; the
/// AX work per app goes through `AXLimiter`, so busy apps can't take every thread.
enum WindowScanner {
    struct Target {
        let pid: pid_t
        let element: AXUIElement
        let cursor: UInt64
        var sweepPass: Set<CGWindowID> = []
        /// Not tracked yet: read what AX lists, but no brute-force sweeps until it is.
        var isNew = false
    }

    /// Which untracked owners of window-like surfaces to probe: all of them (a full scan), or the ones asked for.
    enum Probe {
        case all
        case only(Set<pid_t>)
    }

    /// Element ids a brute-force sweep tries: top-level windows have small ones.
    static let sweepRange: UInt64 = 4000
    /// How long a scan waits for its apps. Apps that haven't answered by then keep what the model knows of them.
    static let deadline: TimeInterval = 5

    /// What every app's part of a scan reads from (immutable, shared across threads).
    private struct Context {
        let topology: SpaceTopology
        let descriptions: [CGWindowID: CGWindowDescription]
        let displays: [CGRect]
        let zIndex: [CGWindowID: Int]
        let candidatesByPID: [pid_t: [CGWindowID]]
        let knownElements: [CGWindowID: AXUIElement]
        let unfindable: [pid_t: Set<CGWindowID>]
        let hiddenPIDs: Set<pid_t>
    }

    private struct AppOutcome {
        let pid: pid_t
        var records = [WindowRecord]()
        var failed = false
        var cursor: UInt64 = 0
        var unfindable = Set<CGWindowID>()
        var pass = Set<CGWindowID>()
        var examined = [CGWindowID: Bool]()
        var missing = Set<CGWindowID>()
    }

    /// Collects what the apps report; once closed (the deadline passed), late answers are dropped.
    private final class Collector {
        private let lock = NSLock()
        private var outcomes = [AppOutcome]()
        private var closed = false

        var isClosed: Bool {
            lock.lock()
            defer { lock.unlock() }
            return closed
        }

        func add(_ outcome: AppOutcome) {
            lock.lock()
            if !closed { outcomes.append(outcome) }
            lock.unlock()
        }

        func close() -> [AppOutcome] {
            lock.lock()
            defer { lock.unlock() }
            closed = true
            return outcomes
        }
    }

    static func scan(targets trackedTargets: [Target], knownElements: [CGWindowID: AXUIElement], ownPID: pid_t,
                     trackedPIDs: Set<pid_t>, unfindable: [pid_t: Set<CGWindowID>], probe: Probe = .all,
                     hiddenPIDs: Set<pid_t> = [], limiter: AXLimiter = .shared) -> ScanResult {
        let start = ProcessInfo.processInfo.systemUptime
        let topology = SpaceTopology.read(includeWindows: true)
        let displays = DisplayBounds.online()
        var zIndex = [CGWindowID: Int]()
        for (index, wid) in topology.orderedWindowIDs.enumerated() where zIndex[wid] == nil { zIndex[wid] = index }
        let descriptions = WindowServerInfo.describe(topology.orderedWindowIDs)

        // Normal-level, window-sized, visible surfaces: the only ones worth an AX lookup when AX doesn't list them itself.
        var candidatesByPID = [pid_t: [CGWindowID]]()
        for wid in topology.orderedWindowIDs {
            guard let description = descriptions[wid], WindowEligibility.isCandidate(description, ownPID: ownPID, displays: displays)
            else { continue }
            candidatesByPID[description.pid, default: []].append(wid)
        }

        // Untracked apps are only interesting once they own a real window: menu bar apps, and apps that switched to a
        // Dock icon after launching (no launch notification to catch then).
        var newAppPIDs = [pid_t]()
        var examined = [pid_t: [CGWindowID: Bool]]()
        for pid in candidatesByPID.keys where !trackedPIDs.contains(pid) {
            if case .only(let wanted) = probe, !wanted.contains(pid) { continue }
            guard let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated,
                  running.activationPolicy != .prohibited else {
                // Not an app (or gone): nothing AX could tell, and nothing to ask again about these surfaces.
                examined[pid] = settled(candidatesByPID[pid] ?? [], descriptions)
                continue
            }
            newAppPIDs.append(pid)
        }
        let targets = trackedTargets + newAppPIDs.map { Target(pid: $0, element: AXUIElementCreateApplication($0), cursor: 0, isNew: true) }
        let context = Context(topology: topology, descriptions: descriptions, displays: displays, zIndex: zIndex,
                              candidatesByPID: candidatesByPID, knownElements: knownElements, unfindable: unfindable,
                              hiddenPIDs: hiddenPIDs)

        let collector = Collector()
        let group = DispatchGroup()
        for target in targets {
            group.enter()
            limiter.submit(pid: target.pid) {
                defer { group.leave() }
                guard !collector.isClosed else { return }
                collector.add(scanApp(target, context))
            }
        }
        if group.wait(timeout: .now() + deadline) == .timedOut {
            Log.warn("scan: \(targets.count - collector.close().count) app(s) didn't answer within \(Int(deadline)) s")
        }
        let outcomes = collector.close()

        var records = [WindowRecord]()
        var unresponsive = Set(targets.map(\.pid)).subtracting(outcomes.map(\.pid))
        var cursors = [pid_t: UInt64]()
        var unfindableResult = [pid_t: Set<CGWindowID>]()
        var passes = [pid_t: Set<CGWindowID>]()
        var missing = [pid_t: Set<CGWindowID>]()
        for outcome in outcomes {
            records += outcome.records
            cursors[outcome.pid] = outcome.cursor
            unfindableResult[outcome.pid] = outcome.unfindable
            passes[outcome.pid] = outcome.pass
            if outcome.failed {
                unresponsive.insert(outcome.pid)
            } else {
                examined[outcome.pid] = outcome.examined
                if !outcome.missing.isEmpty { missing[outcome.pid] = outcome.missing }
            }
        }
        return ScanResult(topology: topology, records: records, scannedPIDs: Set(targets.map(\.pid)), unresponsivePIDs: unresponsive,
                          cursors: cursors, unfindable: unfindableResult, sweepPasses: passes,
                          newAppPIDs: newAppPIDs.filter { pid in records.contains { $0.description.pid == pid } },
                          duration: ProcessInfo.processInfo.systemUptime - start, examined: examined, missing: missing)
    }

    /// One app's part of a scan. Runs on an `AXLimiter` slot.
    private static func scanApp(_ target: Target, _ context: Context) -> AppOutcome {
        var outcome = AppOutcome(pid: target.pid)
        var snapshots = [AXWindowSnapshot]()
        var hung = false
        switch AXReader.windows(ofApp: target.element) {
        case .windows(let elements):
            reading: for element in elements {
                // Elements without a window id aren't real windows; one that has an id but can't be read is a
                // window we know nothing about this time.
                guard let wid = element.windowID else { continue }
                switch AXReader.read(element, knownWID: wid) {
                case .window(let snapshot):
                    snapshots.append(snapshot)
                case .busy:
                    // It stopped answering: don't wait out the timeout once more for each of its other windows.
                    outcome.failed = true
                    hung = true
                    break reading
                case .gone:
                    break
                }
            }
        case .unresponsive:
            // Busy: never read as "it has none", and don't wait on it window by window either.
            outcome.failed = true
            hung = true
        case .unsupported:
            outcome.failed = true
        }
        let candidates = context.candidatesByPID[target.pid] ?? []
        var seen = Set(snapshots.map(\.wid))
        var missing = Set<CGWindowID>()
        let skip = context.unfindable[target.pid] ?? []
        if !hung {
            reading: for wid in candidates where !seen.contains(wid) && !skip.contains(wid) {
                switch context.knownElements[wid].map({ AXReader.read($0, knownWID: wid) }) {
                case .window(let snapshot):
                    snapshots.append(snapshot)
                    seen.insert(wid)
                case .busy:
                    // Known but the app didn't answer: unknown this time, not gone; and no more waiting on it.
                    outcome.failed = true
                    break reading
                case .gone, nil:
                    // Never seen, or its element went stale (the app rebuilt its AX tree): look for it again.
                    missing.insert(wid)
                }
            }
        }
        var cursor = target.cursor
        // Popups and helper surfaces the sweep can never match stay ignored while they exist.
        var stillUnfindable = skip.filter { candidates.contains($0) }
        // A window can only be called unfindable if it was missing for a whole sweep, from id 0 to the end.
        var pass = cursor == 0 ? missing : target.sweepPass.intersection(missing)
        if !missing.isEmpty && !outcome.failed && !target.isNew {
            let (found, next) = AXReader.bruteForceWindows(pid: target.pid, wanted: missing, startID: cursor, budget: 0.08,
                                                           limit: sweepRange)
            for (wid, element) in found {
                if let snapshot = AXReader.snapshot(of: element, knownWID: wid) {
                    snapshots.append(snapshot)
                    seen.insert(wid)
                }
            }
            pass.subtract(found.keys)
            missing.subtract(found.keys)
            if next >= sweepRange {
                stillUnfindable.formUnion(pass)
                missing.subtract(pass)
                pass = []
                cursor = 0
            } else {
                cursor = next
            }
        }
        // Minimized windows may not be part of any Space list; describe whatever we still lack.
        let undescribed = snapshots.map(\.wid).filter { context.descriptions[$0] == nil }
        let extra = WindowServerInfo.describe(undescribed)
        for snapshot in snapshots {
            let description = context.descriptions[snapshot.wid] ?? extra[snapshot.wid]
            guard description?.pid == target.pid, WindowEligibility.admit(snapshot, description, displays: context.displays),
                  let description else { continue }
            outcome.records.append(WindowRecord(snapshot: snapshot, description: description,
                                                spaces: context.topology.windowSpaces[snapshot.wid] ?? [],
                                                zIndex: context.zIndex[snapshot.wid] ?? Int.max))
        }
        // A native tab group is one card: its visible tab. The others are kept off screen and off every Space.
        let tabs = TabGroups.backgroundTabs(outcome.records.map { record in
            TabGroups.Surface(wid: record.snapshot.wid, pid: target.pid, frame: record.description.bounds,
                              isOnScreen: record.description.isOnScreen, isOnSpace: !record.spaces.isEmpty,
                              isMinimized: record.snapshot.isMinimized)
        }, hiddenPIDs: context.hiddenPIDs)
        if !tabs.isEmpty { outcome.records.removeAll { tabs.contains($0.snapshot.wid) } }

        outcome.cursor = cursor
        outcome.unfindable = stillUnfindable
        outcome.pass = pass
        // An app seen for the first time isn't swept: unless it turns out to have windows (and is tracked from now on,
        // sweeps and all), what it didn't list needs no second look.
        let settledWIDs = target.isNew && outcome.records.isEmpty ? Set(candidates) : seen.union(stillUnfindable)
        outcome.examined = settled(candidates.filter(settledWIDs.contains), context.descriptions)
        outcome.missing = target.isNew ? [] : missing
        return outcome
    }

    private static func settled(_ wids: [CGWindowID], _ descriptions: [CGWindowID: CGWindowDescription]) -> [CGWindowID: Bool] {
        var result = [CGWindowID: Bool]()
        for wid in wids { result[wid] = descriptions[wid]?.isOnScreen ?? false }
        return result
    }
}
