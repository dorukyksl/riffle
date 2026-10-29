#include "CrashGuardCore.h"
#include "CrashGuardInternal.h"

#include <dispatch/dispatch.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

// Everything a signal handler reads is plain C, set up before the handlers are installed, and it calls nothing but
// async-signal-safe functions, plus the one call that switches ⌘⇥ back on (WindowServer IPC), which `alarm` bounds.

_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "a signal handler may only use lock-free atomics");

static CrashGuardSetHotKey setHotKeyFunction;
static CrashGuardEnding ending;
static atomic_int ownsCommandTab;
static struct sigaction defaultAction;
static sigset_t alarmOnly;

// The ids of ⌘⇥ and ⌘⇧⇥ among macOS's symbolic hot keys (PrivateAPI.SymbolicHotKey).
enum { commandTab = 1, commandShiftTab = 2 };

static const int fatalSignals[] = { SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE, SIGSYS };
#define FATAL_SIGNAL_COUNT (sizeof fatalSignals / sizeof fatalSignals[0])

void CrashGuardSetOwnsCommandTab(bool owns) {
    atomic_store(&ownsCommandTab, owns ? 1 : 0);
}

void CrashGuardSetEnding(CrashGuardEnding newEnding) {
    ending = newEnding;
}

void CrashGuardRestoreCommandTab(void) {
    if (atomic_exchange(&ownsCommandTab, 0) == 0 || setHotKeyFunction == NULL) return;
    setHotKeyFunction(commandTab, true);
    setHotKeyFunction(commandShiftTab, true);
}

static void handleFatalSignal(int number) {
    // Talking to the WindowServer from a crashed process could block (say, the crash was inside malloc) or fault again:
    // if it hasn't finished in two seconds, SIGALRM's default action ends the process. abort() blocks every other signal
    // on its thread, so let this one through here.
    sigaction(SIGALRM, &defaultAction, NULL);
    pthread_sigmask(SIG_UNBLOCK, &alarmOnly, NULL);
    alarm(2);
    CrashGuardRestoreCommandTab();
    if (ending != NULL) ending(number);
    // Then go down with the same signal, so the crash is reported as usual: it's delivered as soon as this returns.
    sigaction(number, &defaultAction, NULL);
    raise(number);
}

static void restoreOnExit(void) {
    CrashGuardRestoreCommandTab();
}

void CrashGuardInstall(CrashGuardSetHotKey setHotKey) {
    static atomic_flag installed = ATOMIC_FLAG_INIT;
    if (atomic_flag_test_and_set(&installed)) return;
    setHotKeyFunction = setHotKey;
    defaultAction.sa_handler = SIG_DFL;
    sigemptyset(&defaultAction.sa_mask);
    sigemptyset(&alarmOnly);
    sigaddset(&alarmOnly, SIGALRM);

    // Its own stack, so that even a stack overflow can run the handler. Only for this thread: an overflow on another one
    // ends the process without it, and the next launch repairs ⌘⇥.
    size_t size = 4 * SIGSTKSZ;
    void *memory = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (memory != MAP_FAILED) {
        stack_t stack = { .ss_sp = memory, .ss_size = size, .ss_flags = 0 };
        sigaltstack(&stack, NULL);
    }

    struct sigaction action = { .sa_handler = handleFatalSignal, .sa_flags = SA_ONSTACK };
    // While it runs, the other fatal signals wait instead of nesting.
    sigemptyset(&action.sa_mask);
    for (size_t index = 0; index < FATAL_SIGNAL_COUNT; index++) sigaddset(&action.sa_mask, fatalSignals[index]);
    for (size_t index = 0; index < FATAL_SIGNAL_COUNT; index++) sigaction(fatalSignals[index], &action, NULL);

    CrashGuardInstallExceptionHandler();
    atexit(restoreOnExit);
}

void CrashGuardRestoreAndExit(int status) {
    // As in a crash handler: a WindowServer that doesn't answer gets two seconds, then SIGALRM's default action ends the
    // process. Set up here rather than taken from CrashGuardInstall, so it holds even without it.
    struct sigaction byDefault = { .sa_handler = SIG_DFL };
    sigemptyset(&byDefault.sa_mask);
    sigaction(SIGALRM, &byDefault, NULL);
    sigset_t alarmSignal;
    sigemptyset(&alarmSignal);
    sigaddset(&alarmSignal, SIGALRM);
    pthread_sigmask(SIG_UNBLOCK, &alarmSignal, NULL);
    alarm(2);
    CrashGuardRestoreCommandTab();
    _exit(status);
}

// Quitting signals. What they start runs on `terminationQueue`, never on the main thread: that may be the one that's stuck.
static const int terminationSignals[] = { SIGTERM, SIGINT, SIGHUP, SIGQUIT };
#define TERMINATION_SIGNAL_COUNT (sizeof terminationSignals / sizeof terminationSignals[0])
static CrashGuardTerminate terminateFunction;
static dispatch_queue_t terminationQueue;
static int64_t terminationGrace;
static atomic_int firstTerminationSignal;

static void terminationTimedOut(void *context) {
    (void)context;
    CrashGuardRestoreAndExit(128 + atomic_load(&firstTerminationSignal));
}

static void terminationSignalArrived(void *context) {
    int number = (int)(intptr_t)context;
    int none = 0;
    // The first one starts the clock; another (a second ⌃C) neither asks again nor gives the app longer.
    if (!atomic_compare_exchange_strong(&firstTerminationSignal, &none, number)) return;
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, terminationGrace), terminationQueue, NULL, terminationTimedOut);
    terminateFunction();
}

void CrashGuardHandleTerminationSignals(CrashGuardTerminate terminate, double grace) {
    static atomic_flag installed = ATOMIC_FLAG_INIT;
    if (atomic_flag_test_and_set(&installed)) return;
    terminateFunction = terminate;
    terminationGrace = (int64_t)(grace * NSEC_PER_SEC);
    terminationQueue = dispatch_queue_create("riffle.termination",
                                             dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    for (size_t index = 0; index < TERMINATION_SIGNAL_COUNT; index++) {
        int number = terminationSignals[index];
        // Ignored as a signal, whose default action would end the process on the spot with no cleanup; a dispatch source
        // still hears it. The sources live as long as the process.
        signal(number, SIG_IGN);
        dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, (uintptr_t)number, 0, terminationQueue);
        dispatch_set_context(source, (void *)(intptr_t)number);
        dispatch_source_set_event_handler_f(source, terminationSignalArrived);
        dispatch_resume(source);
    }
}
