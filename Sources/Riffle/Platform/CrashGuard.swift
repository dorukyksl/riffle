import CrashGuardCore

/// If Riffle goes down while it has macOS's own ⌘⇥ switched off, switch it back on on the way, so the Mac isn't left
/// without one; the crash is then reported as usual. The handlers are C (CrashGuardCore): nothing they run allocates,
/// takes a lock or enters the Swift or Objective-C runtime, apart from the WindowServer call itself, which an alarm cuts
/// short after two seconds.
///
/// Caught: fatal signals (bad memory access, Swift runtime traps, abort(), a stack overflow on the main thread…),
/// uncaught Objective-C exceptions (those AppKit doesn't catch on its run loop itself), exit(), and a quitting signal the
/// stuck main thread never gets to (`handleTerminationSignals`).
/// Not caught: SIGKILL (Force Quit, `kill -9`, the system ending a hung or out-of-memory process), a power cut, a stack
/// overflow on another thread, or the alarm firing first. For those, `NativeCommandTab`'s record survives and the next
/// launch switches ⌘⇥ back on.
enum CrashGuard {
    /// How long the app gets to quit after a quitting signal before it's ended without its cleanup.
    static let terminationGrace: Double = 3

    static func install() {
        CrashGuardInstall(PrivateAPI.symbolicHotKeySetter)
    }

    static func setOwnsCommandTab(_ owns: Bool) {
        CrashGuardSetOwnsCommandTab(owns)
    }

    /// `kill`, logout, ⌃C in a terminal, a closed terminal: `terminate` is called on a queue of Riffle's own and should
    /// have AppKit quit on the main thread, where the cleanup (giving ⌘⇥ back) runs. If the main thread is stuck and Riffle
    /// is still running `terminationGrace` seconds later, ⌘⇥ is switched back on from that queue and the process ends.
    static func handleTerminationSignals(terminate: @convention(c) () -> Void) {
        CrashGuardHandleTerminationSignals(terminate, terminationGrace)
    }
}
