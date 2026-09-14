#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <signal.h>
#include <sys/ucontext.h>
#include <mach/arm/thread_status.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdint.h>
#include <string.h>

static int CrashFD = -1;
static struct sigaction Previous[NSIG];
static const int Signals[] = {SIGTRAP, SIGABRT, SIGILL, SIGSEGV, SIGBUS};
static volatile sig_atomic_t Handling;
static void Raw(const char *s, size_t count) {
    if (CrashFD >= 0) (void)write(CrashFD, s, count);
}
static void Hex(const char *label, uintptr_t value) {
    char line[100]; size_t n = 0;
    while (*label && n < 60) line[n++] = *label++;
    line[n++] = '0'; line[n++] = 'x';
    for (int shift = (int)(sizeof(value) * 8) - 4; shift >= 0; shift -= 4)
        line[n++] = "0123456789abcdef"[(value >> shift) & 15];
    line[n++] = '\n'; Raw(line, n);
}
static void Capture(int sig, siginfo_t *info, void *context) {
    if (!Handling) {
        Handling = 1;
        Raw("FATAL SIGNAL\n", sizeof("FATAL SIGNAL\n") - 1);
        Hex("signal=", (uintptr_t)sig);
        if (info) Hex("code=", (uintptr_t)info->si_code);
#if defined(__arm64__)
        ucontext_t *uc = (ucontext_t *)context;
        if (uc && uc->uc_mcontext) {
            arm_thread_state64_t state = uc->uc_mcontext->__ss;
            Hex("pc=", (uintptr_t)arm_thread_state64_get_pc(state));
            Hex("lr=", (uintptr_t)arm_thread_state64_get_lr(state));
            Hex("fp=", (uintptr_t)arm_thread_state64_get_fp(state));
        }
#else
        (void)context;
#endif
    }
    // Preserve normal crash termination; never try to continue after a fault.
    struct sigaction next = Previous[sig];
    if (next.sa_handler == SIG_IGN) { memset(&next, 0, sizeof(next)); next.sa_handler = SIG_DFL; }
    sigaction(sig, &next, NULL);
    raise(sig);
}
static void Install(void) {
    for (size_t i = 0; i < sizeof(Signals) / sizeof(Signals[0]); i++) {
        int sig = Signals[i]; struct sigaction old;
        if (sigaction(sig, NULL, &old) != 0) continue;
        if ((old.sa_flags & SA_SIGINFO) && old.sa_sigaction == Capture) continue;
        struct sigaction action; memset(&action, 0, sizeof(action));
        sigemptyset(&action.sa_mask);
        action.sa_sigaction = Capture; action.sa_flags = SA_SIGINFO;
        Previous[sig] = old;
        sigaction(sig, &action, NULL);
    }
}
static void ImageMap(void) {
    // Addresses plus image names allow symbolication against the supplied IPA.
    // Capture these before a crash; never call dyld/Foundation in the handler.
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *path = _dyld_get_image_name(i); if (!path) continue;
        const char *name = strrchr(path, '/'); name = name ? name + 1 : path;
        Raw("image ", 6); Raw(name, strlen(name)); Raw("\n", 1);
        Hex("base=", (uintptr_t)_dyld_get_image_header(i));
        Hex("slide=", (uintptr_t)_dyld_get_image_vmaddr_slide(i));
    }
}
__attribute__((constructor)) static void InitializeCrashCapture(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqual:@"yuca.scanner"]) return;
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *path = [docs stringByAppendingPathComponent:@"YukaCrash.txt"];
        NSString *previous = [docs stringByAppendingPathComponent:@"YukaCrash-previous.txt"];
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm removeItemAtPath:previous error:NULL];
        if ([fm fileExistsAtPath:path]) [fm moveItemAtPath:path toPath:previous error:NULL];
        CrashFD = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0600);
        Raw("Yuka crash capture 2.1.1\n", sizeof("Yuka crash capture 2.1.1\n") - 1);
        ImageMap(); Install();
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            (void)note; Install(); Raw("ACTIVE: signal handlers armed\n", sizeof("ACTIVE: signal handlers armed\n") - 1);
        }];
    }
}
