import CoreGraphics
import Foundation

/// Decides how much of the window inventory has to be read again over accessibility. AX notifications keep the model
/// current between scans, so the normal answer is "nothing" or "these few apps"; a full scan (every app at once) is
/// for a model that is old or was invalidated (wake, unlock, displays changed). Pure: the store feeds it facts.
enum ScanPlanner {
    enum Trigger: Equatable {
        /// The switcher was just summoned (its rows are already on screen; a scan only folds in differences).
        case summon
        /// The periodic safety net.
        case timer
        /// Something happened (a Space change, a notification asking for a look).
        case event
    }

    enum Plan: Equatable {
        case none
        /// Read only these apps (tracked ones, or untracked owners of window-like surfaces to probe).
        case apps(Set<pid_t>)
        case full
    }

    enum Reason: Hashable {
        /// Just launched: its windows arrive over the first seconds.
        case launched
        /// A notification said something changed that only a scan can sort out (an element destroyed while its window lives on).
        case changed
        /// The WindowServer shows window-like surfaces of this app the model doesn't know.
        case unknownWindows
        /// A sweep for its windows on other Spaces is under way.
        case sweeping
        /// Its last scan didn't get answers (busy, hung, or no AX support).
        case unresponsive
        /// It sends no window notifications: only scans keep it current.
        case noObserver
    }

    struct Need: Equatable {
        var reasons = Set<Reason>()
        /// When it was last scanned (attempted).
        var lastAttempt: TimeInterval?
        /// Scans in a row that got no answer.
        var failures = 0
    }

    struct State {
        var now: TimeInterval
        /// When the last full scan that completed had started.
        var lastFullScan: TimeInterval?
        /// The whole model was invalidated since (wake, unlock, display change, an explicit request).
        var fullScanRequested = false
        var needs = [pid_t: Need]()
        /// Apps not tracked yet that own window-like surfaces no scan has looked at.
        var untrackedOwners = Set<pid_t>()
        /// Seconds since the last keyboard or mouse input.
        var idleTime: TimeInterval = 0
        var isLocked = false
    }

    /// A summon reads everything again only past this age; the safety net keeps the model younger while you work.
    static let summonMaxAge: TimeInterval = 120
    static let backgroundMaxAge: TimeInterval = 90
    /// Nobody at the Mac: the safety net doesn't wake every app for nothing.
    static let idleCutoff: TimeInterval = 300
    static let retryBase: TimeInterval = 3
    static let retryCap: TimeInterval = 60

    static func plan(_ state: State, trigger: Trigger) -> Plan {
        // Locked: apps don't let accessibility read their windows, a scan would see none.
        guard !state.isLocked else { return .none }
        let age = state.lastFullScan.map { state.now - $0 } ?? .infinity
        switch trigger {
        case .summon:
            if state.fullScanRequested || age >= summonMaxAge { return .full }
        case .timer:
            guard state.idleTime < idleCutoff else { return .none }
            if state.fullScanRequested || age >= backgroundMaxAge { return .full }
        case .event:
            if state.fullScanRequested || state.lastFullScan == nil { return .full }
        }
        let due = Set(state.needs.filter { isDue($0.value, now: state.now) }.keys).union(state.untrackedOwners)
        return due.isEmpty ? .none : .apps(due)
    }

    static func isDue(_ need: Need, now: TimeInterval) -> Bool {
        guard !need.reasons.isEmpty else { return false }
        // A busy app costs a slot for a whole timeout, and an app without notifications only needs an occasional look:
        // both wait out their backoff. Everything else is worth reading now.
        guard need.reasons.contains(.unresponsive) || need.reasons == [.noObserver] else { return true }
        guard let last = need.lastAttempt else { return true }
        return now - last >= retryInterval(failures: need.failures)
    }

    /// 3 s, doubling with each scan in a row that got no answer, up to a minute.
    static func retryInterval(failures: Int) -> TimeInterval {
        min(retryBase * pow(2, Double(max(failures - 1, 0))), retryCap)
    }
}

/// Brings the model in line with what the WindowServer knows, without asking any app (so it can't block on a busy
/// one, and costs about a millisecond): windows that are gone, background tabs, the Space each window is on, and which
/// apps own window-like surfaces the model doesn't know yet (those get a scan). Pure.
enum WindowServerReconcile {
    struct Tracked {
        let wid: CGWindowID
        let pid: pid_t
        let isMinimized: Bool
    }

    struct Input {
        var ownPID: pid_t
        var topology: SpaceTopology
        /// For every tracked window and every window on a Space.
        var descriptions: [CGWindowID: CGWindowDescription]
        var displays: [CGRect]
        var tracked: [Tracked]
        var trackedPIDs: Set<pid_t>
        var hiddenPIDs: Set<pid_t>
        /// Per app, the candidate surfaces a scan has looked at, and whether each was on screen then.
        var examined: [pid_t: [CGWindowID: Bool]]
    }

    struct Outcome: Equatable {
        /// Tracked windows the WindowServer no longer has: closes nobody told us about.
        var vanished = Set<CGWindowID>()
        var backgroundTabs = Set<CGWindowID>()
        /// The Spaces of tracked windows that are on one (unlisted ones keep what they had: minimized windows can drop off).
        var spaces = [CGWindowID: [CGSSpaceID]]()
        var appsWithUnknownWindows = Set<pid_t>()
        var untrackedOwners = Set<pid_t>()
    }

    static func evaluate(_ input: Input) -> Outcome {
        var outcome = Outcome()
        // Without the Space layout (SkyLight didn't answer) every window would look like it's on no Space: then only what
        // the WindowServer says for sure counts, that a window is gone.
        let layoutKnown = isLayoutKnown(input.topology)
        var surfaces = [TabGroups.Surface]()
        for window in input.tracked {
            guard let description = input.descriptions[window.wid] else {
                outcome.vanished.insert(window.wid)
                continue
            }
            guard layoutKnown else { continue }
            let spaces = input.topology.windowSpaces[window.wid] ?? []
            if !spaces.isEmpty { outcome.spaces[window.wid] = spaces }
            surfaces.append(TabGroups.Surface(wid: window.wid, pid: window.pid, frame: description.bounds,
                                              isOnScreen: description.isOnScreen, isOnSpace: !spaces.isEmpty,
                                              isMinimized: window.isMinimized))
        }
        guard layoutKnown else { return outcome }
        outcome.backgroundTabs = TabGroups.backgroundTabs(surfaces, hiddenPIDs: input.hiddenPIDs)
        let tracked = Set(input.tracked.map(\.wid))
        // Candidates come from the Space lists only: surfaces on no Space and off screen (background tabs, parked
        // helpers) can never be listed by AX, and asking would never end.
        for wid in input.topology.orderedWindowIDs where !tracked.contains(wid) {
            guard let description = input.descriptions[wid],
                  WindowEligibility.isCandidate(description, ownPID: input.ownPID, displays: input.displays),
                  needsExamination(isOnScreen: description.isOnScreen, examinedOnScreen: input.examined[description.pid]?[wid])
            else { continue }
            if input.trackedPIDs.contains(description.pid) {
                outcome.appsWithUnknownWindows.insert(description.pid)
            } else {
                outcome.untrackedOwners.insert(description.pid)
            }
        }
        return outcome
    }

    /// Spaces, and windows on them: what SkyLight answers when it answers at all.
    static func isLayoutKnown(_ topology: SpaceTopology) -> Bool {
        !topology.spaces.isEmpty && !topology.windowSpaces.isEmpty
    }

    /// A surface a scan already looked at needs another look only once it is on screen when it wasn't then: AX lists the
    /// windows of the Spaces on screen, so a window a sweep couldn't find on another Space can be found now.
    static func needsExamination(isOnScreen: Bool, examinedOnScreen: Bool?) -> Bool {
        guard let examinedOnScreen else { return true }
        return isOnScreen && !examinedOnScreen
    }

    /// Forgets surfaces the WindowServer no longer has.
    static func pruned(_ examined: [pid_t: [CGWindowID: Bool]], alive: Set<CGWindowID>) -> [pid_t: [CGWindowID: Bool]] {
        var result = [pid_t: [CGWindowID: Bool]]()
        for (pid, surfaces) in examined {
            let kept = surfaces.filter { alive.contains($0.key) }
            if !kept.isEmpty { result[pid] = kept }
        }
        return result
    }
}
