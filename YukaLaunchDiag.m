#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>

static NSString *LogPath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return docs ? [docs stringByAppendingPathComponent:@"YukaLaunchDiag.txt"] : nil;
}

static void AppendLine(NSString *line) {
    @autoreleasepool {
        NSString *path = LogPath();
        if (!path || !line) return;
        NSString *full = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], line];
        NSData *data = [full dataUsingEncoding:NSUTF8StringEncoding];
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [data writeToFile:path atomically:YES];
            return;
        }
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle closeFile];
    }
}

static void LogCaller(NSString *kind, NSInteger code, void *caller) {
    Dl_info info = {0};
    dladdr(caller, &info);
    unsigned long long offset = (info.dli_fbase && caller) ?
        (unsigned long long)((uintptr_t)caller - (uintptr_t)info.dli_fbase) : 0;
    NSString *image = info.dli_fname ? [NSString stringWithUTF8String:info.dli_fname] : @"?";
    AppendLine([NSString stringWithFormat:@"%@ code=%ld caller=%@+0x%llx", kind, (long)code, image, offset]);
}

static BOOL (*OriginalDidFinish)(id, SEL, UIApplication *, NSDictionary *);
static BOOL DiagnosticDidFinish(id self, SEL cmd, UIApplication *app, NSDictionary *options) {
    AppendLine(@"AppDelegate didFinishLaunching START");
    BOOL result = OriginalDidFinish(self, cmd, app, options);
    AppendLine([NSString stringWithFormat:@"AppDelegate didFinishLaunching RETURN %d", result]);
    return result;
}

static void (*OriginalDidBecomeActive)(id, SEL, UIApplication *);
static void DiagnosticDidBecomeActive(id self, SEL cmd, UIApplication *app) {
    AppendLine(@"AppDelegate didBecomeActive START");
    OriginalDidBecomeActive(self, cmd, app);
    AppendLine(@"AppDelegate didBecomeActive RETURN");
}

static id (*OriginalRemoteValue)(id, SEL, NSString *);
static id DiagnosticRemoteValue(id self, SEL cmd, NSString *key) {
    AppendLine([NSString stringWithFormat:@"RemoteConfig key: %@", key ?: @"(null)"]);
    return OriginalRemoteValue(self, cmd, key);
}

static void (*OriginalExit)(int);
static void DiagnosticExit(int status) {
    LogCaller(@"exit", status, __builtin_return_address(0));
    OriginalExit(status);
}

static void (*Original_Exit)(int);
static void Diagnostic_Exit(int status) {
    LogCaller(@"_exit", status, __builtin_return_address(0));
    Original_Exit(status);
}

static void (*OriginalAbort)(void);
static void DiagnosticAbort(void) {
    LogCaller(@"abort", 0, __builtin_return_address(0));
    OriginalAbort();
}

static int (*OriginalKill)(pid_t, int);
static int DiagnosticKill(pid_t pid, int sig) {
    if (pid == getpid()) LogCaller(@"kill", sig, __builtin_return_address(0));
    return OriginalKill(pid, sig);
}

static void (*OriginalObjCExceptionThrow)(id);
static void DiagnosticObjCExceptionThrow(id exception) {
    if ([exception isKindOfClass:NSException.class]) {
        NSException *e = exception;
        AppendLine([NSString stringWithFormat:@"objc_exception_throw %@: %@", e.name ?: @"?", e.reason ?: @"?"]);
    } else {
        AppendLine(@"objc_exception_throw non-NSException");
    }
    OriginalObjCExceptionThrow(exception);
}

static NSUncaughtExceptionHandler *PreviousExceptionHandler;
static void DiagnosticUncaughtException(NSException *exception) {
    AppendLine([NSString stringWithFormat:@"UNCAUGHT %@: %@", exception.name ?: @"?", exception.reason ?: @"?"]);
    if (PreviousExceptionHandler) PreviousExceptionHandler(exception);
}

static void HookInstance(Class cls, SEL sel, IMP replacement, IMP *original) {
    if (!cls) return;
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;
    if (original) *original = method_getImplementation(method);
    method_setImplementation(method, replacement);
}

static void InstallFunctionHook(const char *name, void *replacement, void **original) {
    typedef void (*MSHookFunctionType)(void *, void *, void **);
    MSHookFunctionType hook = (MSHookFunctionType)dlsym(RTLD_DEFAULT, "MSHookFunction");
    void *target = dlsym(RTLD_DEFAULT, name);
    if (hook && target) hook(target, replacement, original);
}

__attribute__((constructor)) static void InitializeYukaLaunchDiag(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"yuca.scanner"]) return;
        NSString *path = LogPath();
        if (path) [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        AppendLine(@"YukaLaunchDiag 2.0.1 constructor loaded");

        PreviousExceptionHandler = NSGetUncaughtExceptionHandler();
        NSSetUncaughtExceptionHandler(DiagnosticUncaughtException);

        Class appDelegate = NSClassFromString(@"_TtC4Yuka11AppDelegate");
        HookInstance(appDelegate, @selector(application:didFinishLaunchingWithOptions:), (IMP)DiagnosticDidFinish, (IMP *)&OriginalDidFinish);
        HookInstance(appDelegate, @selector(applicationDidBecomeActive:), (IMP)DiagnosticDidBecomeActive, (IMP *)&OriginalDidBecomeActive);

        Class remoteConfig = NSClassFromString(@"FIRRemoteConfig");
        HookInstance(remoteConfig, @selector(configValueForKey:), (IMP)DiagnosticRemoteValue, (IMP *)&OriginalRemoteValue);

        InstallFunctionHook("exit", (void *)&DiagnosticExit, (void **)&OriginalExit);
        InstallFunctionHook("_exit", (void *)&Diagnostic_Exit, (void **)&Original_Exit);
        InstallFunctionHook("abort", (void *)&DiagnosticAbort, (void **)&OriginalAbort);
        InstallFunctionHook("kill", (void *)&DiagnosticKill, (void **)&OriginalKill);
        InstallFunctionHook("objc_exception_throw", (void *)&DiagnosticObjCExceptionThrow, (void **)&OriginalObjCExceptionThrow);

        AppendLine(@"diagnostic hooks installed");
    }
}
