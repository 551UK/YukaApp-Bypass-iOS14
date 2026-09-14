#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "YukaFirebaseConfig.h"

static NSString *CompatGoogleServicePath;

static BOOL IsGoogleServiceResource(NSString *name, NSString *type) {
    if (![name isKindOfClass:NSString.class]) return NO;
    if ([name isEqualToString:@"GoogleService-Info"] && (!type || [type isEqualToString:@"plist"])) return YES;
    if ([name isEqualToString:@"GoogleService-Info.plist"] && (!type || type.length == 0)) return YES;
    return NO;
}

static NSString *(*OriginalPathForResource)(id, SEL, NSString *, NSString *);
static NSString *PathForResource(id self, SEL cmd, NSString *name, NSString *type) {
    if (self == NSBundle.mainBundle && CompatGoogleServicePath && IsGoogleServiceResource(name, type)) {
        return CompatGoogleServicePath;
    }
    return OriginalPathForResource(self, cmd, name, type);
}

static NSURL *(*OriginalURLForResource)(id, SEL, NSString *, NSString *);
static NSURL *URLForResource(id self, SEL cmd, NSString *name, NSString *ext) {
    if (self == NSBundle.mainBundle && CompatGoogleServicePath && IsGoogleServiceResource(name, ext)) {
        return [NSURL fileURLWithPath:CompatGoogleServicePath];
    }
    return OriginalURLForResource(self, cmd, name, ext);
}

static NSString *(*OriginalPathForResourceInDirectory)(id, SEL, NSString *, NSString *, NSString *);
static NSString *PathForResourceInDirectory(id self, SEL cmd, NSString *name, NSString *type, NSString *directory) {
    if (self == NSBundle.mainBundle && CompatGoogleServicePath && (!directory || directory.length == 0) && IsGoogleServiceResource(name, type)) {
        return CompatGoogleServicePath;
    }
    return OriginalPathForResourceInDirectory(self, cmd, name, type, directory);
}

static NSURL *(*OriginalURLForResourceInDirectory)(id, SEL, NSString *, NSString *, NSString *);
static NSURL *URLForResourceInDirectory(id self, SEL cmd, NSString *name, NSString *ext, NSString *subdirectory) {
    if (self == NSBundle.mainBundle && CompatGoogleServicePath && (!subdirectory || subdirectory.length == 0) && IsGoogleServiceResource(name, ext)) {
        return [NSURL fileURLWithPath:CompatGoogleServicePath];
    }
    return OriginalURLForResourceInDirectory(self, cmd, name, ext, subdirectory);
}

static void HookInstanceMethod(Class cls, SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    *original = method_getImplementation(method);
    method_setImplementation(method, replacement);
}

static BOOL PrepareCompatibilityPlist(void) {
    NSString *originalPath = [NSBundle.mainBundle pathForResource:@"GoogleService-Info" ofType:@"plist"];
    if (!originalPath.length) return NO;

    NSMutableDictionary *plist = [NSMutableDictionary dictionaryWithContentsOfFile:originalPath];
    if (!plist) return NO;

    NSString *currentValue = plist[@"API_KEY"];
    if (![currentValue isKindOfClass:NSString.class]) return NO;

    // Keep every Yuka 4.38 Firebase setting exactly as shipped and change only
    // the public Firebase client key to the value used by the supplied Yuka 5.3 app.
    plist[@"API_KEY"] = CurrentFirebaseKey;

    NSString *destination = [NSTemporaryDirectory() stringByAppendingPathComponent:@"YukaBypass-GoogleService-Info.plist"];
    if (![plist writeToFile:destination atomically:YES]) return NO;

    NSDictionary *verify = [NSDictionary dictionaryWithContentsOfFile:destination];
    if (![verify[@"API_KEY"] isEqualToString:CurrentFirebaseKey]) return NO;

    CompatGoogleServicePath = [destination copy];
    NSLog(@"[YukaBypass] Firebase config compatibility plist prepared (original key changed: %@)", [currentValue isEqualToString:CurrentFirebaseKey] ? @"no" : @"yes");
    return YES;
}

__attribute__((constructor)) static void InitializeYukaCompatibility(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"yuca.scanner"]) return;
        if (!PrepareCompatibilityPlist()) {
            NSLog(@"[YukaBypass] Could not prepare Firebase compatibility plist; no hooks installed.");
            return;
        }

        HookInstanceMethod(NSBundle.class, @selector(pathForResource:ofType:), (IMP)PathForResource, (IMP *)&OriginalPathForResource);
        HookInstanceMethod(NSBundle.class, @selector(URLForResource:withExtension:), (IMP)URLForResource, (IMP *)&OriginalURLForResource);
        HookInstanceMethod(NSBundle.class, @selector(pathForResource:ofType:inDirectory:), (IMP)PathForResourceInDirectory, (IMP *)&OriginalPathForResourceInDirectory);
        HookInstanceMethod(NSBundle.class, @selector(URLForResource:withExtension:subdirectory:), (IMP)URLForResourceInDirectory, (IMP *)&OriginalURLForResourceInDirectory);

        NSLog(@"[YukaBypass] GoogleService-Info redirect active. No app-version or Firebase-object spoofing is enabled.");
    }
}
