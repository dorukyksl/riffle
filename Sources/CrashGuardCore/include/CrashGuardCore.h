#ifndef CRASH_GUARD_CORE_H
#define CRASH_GUARD_CORE_H

#include <CoreGraphics/CGError.h>
#include <stdbool.h>
#include <stdint.h>

/// Switches one of macOS's symbolic hot keys on or off: SkyLight's CGSSetSymbolicHotKeyEnabled, or a stand-in in tests.
typedef CGError (*CrashGuardSetHotKey)(int32_t hotKey, bool enabled);

/// Installs what switches macOS's ⌘⇥ back on if the process goes down while it has it off: handlers for fatal signals
/// (on an alternate stack, so a stack overflow on the calling thread is covered), for uncaught Objective-C exceptions, and
/// for exit(). Call once, early, on the main thread. `setHotKey` is resolved by then; it is the only thing a signal handler
/// calls that isn't async-signal-safe. NULL when the call isn't available: the handlers then only pass the crash on.
void CrashGuardInstall(CrashGuardSetHotKey _Nullable setHotKey);

/// True while this process has ⌘⇥ switched off: only then do the handlers switch it back on.
void CrashGuardSetOwnsCommandTab(bool owns);

/// How a fatal-signal handler ends the process once ⌘⇥ is back on. NULL, the default, goes down with the same signal so
/// the crash is reported as usual. Tests pass a function that calls _exit: their crashes then leave no crash report.
typedef void (*CrashGuardEnding)(int signal);
void CrashGuardSetEnding(CrashGuardEnding _Nullable ending);

/// Asks the app to quit; it should hand that to the main thread and return.
typedef void (*CrashGuardTerminate)(void);

/// The signals that ask a process to quit (SIGTERM, SIGINT, SIGHUP, SIGQUIT: `kill`, ⌃C or a closed terminal) stop
/// ending it on the spot: `terminate` is called instead, on a queue of its own, so that the app quits the orderly way. If
/// the process is still there `grace` seconds after the first of them (its main thread is stuck), ⌘⇥ is switched back on
/// from that queue, as after a crash, and the process ends with status 128 + that signal. Later signals change nothing.
/// Call once, after CrashGuardInstall.
void CrashGuardHandleTerminationSignals(CrashGuardTerminate _Nonnull terminate, double grace);

/// Switches ⌘⇥ back on if this process has it off (an alarm ends the process if the WindowServer doesn't answer within two
/// seconds), then ends the process at once with `status`, running nothing else.
void CrashGuardRestoreAndExit(int status) __attribute__((noreturn));

#endif
