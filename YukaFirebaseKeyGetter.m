#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "YukaFirebaseConfig.h"

// Yuka 4.38's Firestore client does not necessarily travel through NSURLSession.
// Change only FIROptions' APIKey getter, leaving setters and storage configuration alone.
// This is intentionally narrower than the 1.0.5 experiment that regressed launch.
static IMP OriginalAPIKeyIMP;
static BOOL APIKeyGetterInstalled;

static id YukaCurrentAPIKey(id self, SEL cmd) {
    id value = ((id (*)(id, SEL))OriginalAPIKeyIMP)(self, cmd);
    if ([value isKindOfClass:NSString.class] && [(NSString *)value isEqualToString:OldFirebaseKey])
        return CurrentFirebaseKey;
    return value;
}

static void InstallAPIKeyGetter(void) {
    if (APIKeyGetterInstalled) return;
    Class options = NSClassFromString(@"FIROptions");
    if (!options) return;

    SEL selector = NSSelectorFromString(@"APIKey");
    Method method = class_getInstanceMethod(options, selector);
    if (!method) return;

    IMP original = method_getImplementation(method);
    if (original == (IMP)YukaCurrentAPIKey) {
        APIKeyGetterInstalled = YES;
        return;
    }

    OriginalAPIKeyIMP = original;
    const char *types = method_getTypeEncoding(method);
    if (!class_addMethod(options, selector, (IMP)YukaCurrentAPIKey, types))
        method_setImplementation(class_getInstanceMethod(options, selector), (IMP)YukaCurrentAPIKey);

    APIKeyGetterInstalled = YES;
    NSLog(@"[YukaBypass] FIROptions APIKey getter hooked (getter only)");
}

__attribute__((constructor)) static void InitializeFirebaseKeyGetter(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"yuca.scanner"]) return;

        InstallAPIKeyGetter();
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
                (void)timer;
                InstallAPIKeyGetter();
            }];
        });
    }
}
