import CoreFoundation

/// macOS's own ⌘⇥ (and ⌘⇧⇥), switched off while one of Riffle's shortcuts uses ⌘⇥: the Dock consumes that keystroke before
/// any app hears it. The switch outlives the process, so the steps are ordered for dying at any point between them:
/// - taking over: write the record, arm the crash guard, switch off;
/// - giving back: switch on, disarm, erase the record.
/// While armed, `CrashGuard` switches ⌘⇥ back on if the process goes down. Where it can't (SIGKILL, a power cut), the record
/// survives and the next launch switches ⌘⇥ back on (`repairAtLaunch`).
final class NativeCommandTab {
    struct System {
        /// The record, kept across launches, that Riffle switched ⌘⇥ off and hasn't switched it back on yet.
        var recorded: () -> Bool
        var setRecorded: (Bool) -> Void
        /// Both hot keys at once.
        var setEnabled: (Bool) -> Void
        /// Whether both are on; nil when the system can't tell.
        var isEnabled: () -> Bool?
        var armCrashGuard: (Bool) -> Void
    }

    enum Outcome: Equatable {
        /// No record: whatever state ⌘⇥ is in, Riffle didn't put it there, so it's left alone.
        case notOurs
        /// It was on already (the crash guard did it, but a signal handler can't write settings): only the record went.
        case alreadyOn
        case switchedOn
        /// The system still says it's off: the record stays, and the next launch tries again.
        case stillOff
    }

    enum LaunchStep: Equatable {
        case nothing
        case forgetRecord
        case switchBackOn
    }

    private let system: System
    /// This process switched ⌘⇥ off. Only then does quitting switch it back on: a second copy of Riffle that quits at once
    /// (single instance) must not undo what the running one did.
    private(set) var ownsCommandTab = false

    init(system: System = .live) {
        self.system = system
    }

    func takeOver() {
        system.setRecorded(true)
        system.armCrashGuard(true)
        ownsCommandTab = true
        system.setEnabled(false)
    }

    /// Switches ⌘⇥ back on if Riffle switched it off, in this process or an earlier one.
    @discardableResult
    func giveBack() -> Outcome {
        ownsCommandTab = false
        guard system.recorded() else {
            system.armCrashGuard(false)
            return .notOurs
        }
        system.setEnabled(true)
        system.armCrashGuard(false)
        return forgetRecordUnlessStillOff()
    }

    /// Once this copy holds the single-instance lock, before anything can take ⌘⇥ over.
    func repairAtLaunch() -> Outcome {
        switch NativeCommandTab.launchStep(recorded: system.recorded(), enabled: system.isEnabled()) {
        case .nothing:
            return .notOurs
        case .forgetRecord:
            system.setRecorded(false)
            return .alreadyOn
        case .switchBackOn:
            system.setEnabled(true)
            return forgetRecordUnlessStillOff()
        }
    }

    private func forgetRecordUnlessStillOff() -> Outcome {
        if NativeCommandTab.keepsRecord(afterSwitchingOn: system.isEnabled()) { return .stillOff }
        system.setRecorded(false)
        return .switchedOn
    }

    /// `enabled`: what the system says now, nil when it can't tell. Without a record ⌘⇥ is never touched, whatever its
    /// state: another app (or the user) may have switched it off.
    static func launchStep(recorded: Bool, enabled: Bool?) -> LaunchStep {
        guard recorded else { return .nothing }
        return enabled == true ? .forgetRecord : .switchBackOn
    }

    /// The record goes once the system says ⌘⇥ is on, or can't say: keeping it then would only repeat a call that can't
    /// be checked at every launch.
    static func keepsRecord(afterSwitchingOn enabled: Bool?) -> Bool {
        enabled == false
    }
}

extension NativeCommandTab.System {
    static let live = NativeCommandTab.System(
        recorded: { Prefs.shared.didDisableNativeCommandTab },
        setRecorded: { recorded in
            Prefs.shared.didDisableNativeCommandTab = recorded
            // Settings reach cfprefsd asynchronously: wait for it, so that even a SIGKILL right after leaves the record.
            CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        },
        setEnabled: { enabled in
            PrivateAPI.setSymbolicHotKey(.commandTab, enabled: enabled)
            PrivateAPI.setSymbolicHotKey(.commandShiftTab, enabled: enabled)
        },
        isEnabled: {
            guard let commandTab = PrivateAPI.isSymbolicHotKeyEnabled(.commandTab),
                  let commandShiftTab = PrivateAPI.isSymbolicHotKeyEnabled(.commandShiftTab) else { return nil }
            return commandTab && commandShiftTab
        },
        armCrashGuard: CrashGuard.setOwnsCommandTab
    )
}
