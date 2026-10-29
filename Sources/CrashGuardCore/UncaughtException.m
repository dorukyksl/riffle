#import <Foundation/Foundation.h>

#import "CrashGuardInternal.h"

static NSUncaughtExceptionHandler *previousHandler;

// Not a signal handler: it runs on the thread that threw, before the runtime calls abort(). AppKit catches what's thrown
// on its main run loop itself (it logs the exception and carries on), so this sees the rest: other threads, and code
// outside the run loop.
static void handleUncaughtException(NSException *exception) {
    CrashGuardRestoreCommandTab();
    if (previousHandler != NULL) previousHandler(exception);
}

void CrashGuardInstallExceptionHandler(void) {
    previousHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(handleUncaughtException);
}
