import CrashGuardCore
import Foundation

// For CrashGuardTests, never shipped. Installs the crash guard with a stand-in for the WindowServer call, so it never touches
// the real ⌘⇥, then ends the way its argument says. The stand-in writes one byte to stdout per hot key it's asked to switch:
// the hot key's id, plus 0x80 for "on". Reports go to stderr.
//
// Crashes end with _exit(100 + signal) once the handler has done everything else it does in production, so they leave
// no crash report on the Mac. Only "production-crash" goes down like the app would (CrashGuardTests runs it only in CI).
// The "terminate" modes say "ready" on stderr, then wait for the quitting signals the test sends to this process.

// Whatever happens, this process is gone within ten seconds (a crash handler's alarm(2) replaces this one).
alarm(10)

let report: CrashGuardSetHotKey = { hotKey, enabled in
    var byte = UInt8(truncatingIfNeeded: hotKey) | (enabled ? 0x80 : 0)
    _ = write(STDOUT_FILENO, &byte, 1)
    return .success
}

/// A WindowServer that never answers.
let hang: CrashGuardSetHotKey = { hotKey, _ in
    var byte = UInt8(truncatingIfNeeded: hotKey)
    _ = write(STDOUT_FILENO, &byte, 1)
    while true { pause() }
}

let endQuietly: CrashGuardEnding = { signal in _exit(100 + signal) }

func tell(_ text: String) {
    fputs(text + "\n", stderr)
}

/// What the app does on a quitting signal: quit on the main thread. Says so on stderr each time it's asked.
let quitOnMainThread: CrashGuardTerminate = {
    fputs("asked to quit\n", stderr)
    DispatchQueue.main.async { exit(0) }
}

/// The grace period of the "terminate" modes: shorter than the app's, to keep the tests quick.
let terminationGrace = 0.5

@inline(never)
func dive(_ depth: Int) -> Int {
    var frame = (depth, depth, depth, depth)
    return withUnsafeMutableBytes(of: &frame) { $0.count } &+ dive(depth &+ 1)
}

/// The fatal signals that have a handler running on the alternate stack, whether that stack is set, and whether uncaught
/// exceptions have a handler.
func describeInstallation() -> String {
    var onStack = [Int32]()
    for number in Int32(1)..<NSIG {
        var action = sigaction()
        if sigaction(number, nil, &action) == 0, action.sa_flags & SA_ONSTACK != 0 { onStack.append(number) }
    }
    var stack = stack_t()
    sigaltstack(nil, &stack)
    return """
    signals \(onStack.map(String.init).joined(separator: " "))
    altstack \(stack.ss_flags & SS_DISABLE == 0 ? "yes" : "no")
    exceptions \(NSGetUncaughtExceptionHandler() != nil ? "yes" : "no")
    """
}

/// Production's ending without the crash: the installed SIGSEGV handler, called directly while SIGSEGV is blocked. It
/// switches ⌘⇥ back on, arms the alarm, puts SIGSEGV back to its default action and raises it again, which then waits,
/// pending, instead of ending this process.
func describeProductionEnding() -> String {
    var segv = sigset_t()
    sigemptyset(&segv)
    sigaddset(&segv, SIGSEGV)
    pthread_sigmask(SIG_BLOCK, &segv, nil)
    var installed = sigaction()
    sigaction(SIGSEGV, nil, &installed)
    installed.__sigaction_u.__sa_handler?(SIGSEGV)
    let alarmSeconds = alarm(0)
    var after = sigaction()
    sigaction(SIGSEGV, nil, &after)
    var pending = sigset_t()
    sigpending(&pending)
    return """
    action \(after.__sigaction_u.__sa_handler == nil ? "default" : "handler")
    pending \(sigismember(&pending, SIGSEGV) == 1 ? "yes" : "no")
    alarm \(alarmSeconds)
    """
}

let mode = CommandLine.arguments.dropFirst().first ?? ""
CrashGuardInstall(["hang", "terminate-stuck-hang"].contains(mode) ? hang : report)
CrashGuardSetOwnsCommandTab(true)
if !mode.hasPrefix("production-") { CrashGuardSetEnding(endQuietly) }

switch mode {
case "installation":
    CrashGuardSetOwnsCommandTab(false)
    tell(describeInstallation())
    exit(0)
case "production-ending":
    tell(describeProductionEnding())
    // SIGSEGV stays blocked and pending: leaving now doesn't deliver it.
    _exit(0)
case "bad-access", "production-crash":
    UnsafeMutablePointer<Int>(bitPattern: 8)!.pointee = 1
case "swift-trap":
    let empty = [Int]()
    print(empty[CommandLine.arguments.count])
case "exception":
    NSException(name: .genericException, reason: "CrashGuardProbe", userInfo: nil).raise()
case "stack-overflow":
    print(dive(0))
case "hang":
    abort()
case "exit":
    exit(3)
case "disarmed":
    CrashGuardSetOwnsCommandTab(false)
    exit(3)
case "terminate", "terminate-stuck", "terminate-stuck-hang":
    // Waits for the test to send a quitting signal. "terminate" quits on the main thread when asked, the way AppKit does;
    // in the others the main thread is stuck and never gets to it.
    CrashGuardHandleTerminationSignals(quitOnMainThread, terminationGrace)
    tell("ready")
    if mode == "terminate" { dispatchMain() }
    while true { sleep(1) }
default:
    exit(64)
}
