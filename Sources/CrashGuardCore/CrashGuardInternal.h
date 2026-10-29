#ifndef CRASH_GUARD_INTERNAL_H
#define CRASH_GUARD_INTERNAL_H

/// Switches ⌘⇥ back on if this process owns it, and stops owning it: when an uncaught exception goes on to abort(), whose
/// SIGABRT comes back here, the WindowServer is called once. Async-signal-safe apart from that call.
void CrashGuardRestoreCommandTab(void);

void CrashGuardInstallExceptionHandler(void);

#endif
