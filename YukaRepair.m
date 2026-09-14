#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "YukaFirebaseConfig.h"

// Signatures verified against the Firebase 10.10.0 shipped in Yuka 4.38.
@interface NSObject (YukaOptions)
- (instancetype)initWithContentsOfFile:(NSString *)path;
- (NSDictionary *)optionsDictionary;
@end

static NSString *ConfigPath;
static NSBundle *MainBundle;
static NSString *const Version = @"5.3";
static NSString *const Build = @"2654";

static BOOL Hook(Class cls, SEL selector, IMP replacement, IMP *original) {
    if (!cls) return NO;
    Method m = class_getInstanceMethod(cls, selector);
    if (!m) return NO;
    *original = method_getImplementation(m);
    if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(m)))
        method_setImplementation(class_getInstanceMethod(cls, selector), replacement);
    return YES;
}

static NSDictionary *UpdatedDictionary(NSDictionary *value) {
    if (![value isKindOfClass:NSDictionary.class] ||
        ![value[@"GOOGLE_APP_ID"] isEqual:@"1:844633789705:ios:c1efa388053df516"] ||
        ![value[@"BUNDLE_ID"] isEqual:@"yuca.scanner"]) return value;

    NSMutableDictionary *copy = [value mutableCopy];
    if ([copy[@"API_KEY"] isEqual:OldFirebaseKey]) copy[@"API_KEY"] = CurrentFirebaseKey;
    if ([copy[@"STORAGE_BUCKET"] isEqual:@"project-6706240203345572135.appspot.com"])
        copy[@"STORAGE_BUCKET"] = @"yuka-app";
    return copy;
}

static NSDictionary *(*OriginalDefaultDictionary)(id, SEL);
static NSDictionary *DefaultDictionary(id self, SEL cmd) {
    return UpdatedDictionary(OriginalDefaultDictionary(self, cmd));
}

static void (*OriginalConfigure)(id, SEL, NSString *, id);
static void Configure(id self, SEL cmd, NSString *name, id options) {
    // FIROptions is effectively locked after Firebase starts using it, so build
    // a fresh options object from the repaired dictionary rather than mutating
    // the live instance in place.
    id replacement = options;
    if ([options respondsToSelector:@selector(optionsDictionary)]) {
        NSDictionary *original = [options optionsDictionary];
        NSDictionary *updated = UpdatedDictionary(original);
        if (![updated isEqual:original] && ConfigPath && [updated writeToFile:ConfigPath atomically:YES]) {
            id fresh = [[NSClassFromString(@"FIROptions") alloc] initWithContentsOfFile:ConfigPath];
            if (fresh) {
                // Keep the non-plist values Yuka already configured.
                for (NSString *key in @[@"deepLinkURLScheme", @"appGroupID"]) {
                    SEL getter = NSSelectorFromString(key);
                    NSString *setterName = [NSString stringWithFormat:@"set%@%@:",
                                            [[key substringToIndex:1] uppercaseString],
                                            [key substringFromIndex:1]];
                    SEL setter = NSSelectorFromString(setterName);
                    if ([options respondsToSelector:getter] && [fresh respondsToSelector:setter]) {
                        id value = ((id (*)(id, SEL))objc_msgSend)(options, getter);
                        ((void (*)(id, SEL, id))objc_msgSend)(fresh, setter, value);
                    }
                }
                replacement = fresh;
            }
        }
    }
    OriginalConfigure(self, cmd, name, replacement);
}

static id (*OriginalInfoValue)(id, SEL, NSString *);
static id InfoValue(id self, SEL cmd, NSString *key) {
    if (self == MainBundle) {
        if ([key isEqual:@"CFBundleShortVersionString"]) return Version;
        if ([key isEqual:@"CFBundleVersion"]) return Build;
    }
    return OriginalInfoValue(self, cmd, key);
}

static NSDictionary *(*OriginalInfo)(id, SEL);
static NSDictionary *Info(id self, SEL cmd) {
    NSDictionary *value = OriginalInfo(self, cmd);
    if (self != MainBundle || !value) return value;
    NSMutableDictionary *copy = [value mutableCopy];
    copy[@"CFBundleShortVersionString"] = Version;
    copy[@"CFBundleVersion"] = Build;
    return copy;
}

static BOOL YukaHost(NSString *host) {
    return [host isEqual:@"goodtoucan.com"] || [host hasSuffix:@".goodtoucan.com"] ||
           [host isEqual:@"yuka.io"] || [host hasSuffix:@".yuka.io"];
}

static NSURLRequest *RepairRequest(NSURLRequest *request) {
    NSString *host = request.URL.host.lowercaseString;
    BOOL yuka = YukaHost(host);
    BOOL google = [host hasSuffix:@".googleapis.com"];
    if (!yuka && !google) return request;

    NSMutableURLRequest *copy = [request mutableCopy];

    if (yuka) {
        [copy setValue:Version forHTTPHeaderField:@"X-Yuka-App-Version"];
        [copy setValue:@"Yuka/2654 CFNetwork/1402.0.8 Darwin/22.3.0" forHTTPHeaderField:@"User-Agent"];
    }

    // Spoof only the network metadata. Runtime availability checks still see
    // the real iOS 14 version, avoiding calls to newer OS APIs.
    if ([copy valueForHTTPHeaderField:@"X-osv"])
        [copy setValue:@"16.2" forHTTPHeaderField:@"X-osv"];

    if (google) {
        if ([[copy valueForHTTPHeaderField:@"X-Goog-Api-Key"] isEqual:OldFirebaseKey])
            [copy setValue:CurrentFirebaseKey forHTTPHeaderField:@"X-Goog-Api-Key"];

        NSURLComponents *url = [NSURLComponents componentsWithURL:copy.URL resolvingAgainstBaseURL:NO];
        NSMutableArray *items = [NSMutableArray array];
        BOOL changed = NO;
        for (NSURLQueryItem *item in url.queryItems) {
            if ([item.name isEqual:@"key"] && [item.value isEqual:OldFirebaseKey]) {
                [items addObject:[NSURLQueryItem queryItemWithName:item.name value:CurrentFirebaseKey]];
                changed = YES;
            } else {
                [items addObject:item];
            }
        }
        if (changed) {
            url.queryItems = items;
            if (url.URL) copy.URL = url.URL;
        }
    }

    return copy;
}

typedef void (^Completion)(NSData *, NSURLResponse *, NSError *);

static id (*OriginalDataCompletion)(id, SEL, NSURLRequest *, Completion);
static id DataCompletion(id self, SEL cmd, NSURLRequest *request, Completion completion) {
    return OriginalDataCompletion(self, cmd, RepairRequest(request), completion);
}

static id (*OriginalData)(id, SEL, NSURLRequest *);
static id Data(id self, SEL cmd, NSURLRequest *request) {
    return OriginalData(self, cmd, RepairRequest(request));
}

static id (*OriginalUpload)(id, SEL, NSURLRequest *, NSData *, Completion);
static id Upload(id self, SEL cmd, NSURLRequest *request, NSData *body, Completion completion) {
    return OriginalUpload(self, cmd, RepairRequest(request), body, completion);
}

__attribute__((constructor)) static void Initialize(void) {
    @autoreleasepool {
        MainBundle = NSBundle.mainBundle;
        if (![MainBundle.bundleIdentifier isEqual:@"yuca.scanner"]) return;

        ConfigPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"YukaRepair-Firebase.plist"];

        Hook(object_getClass(NSClassFromString(@"FIROptions")),
             NSSelectorFromString(@"defaultOptionsDictionary"),
             (IMP)DefaultDictionary, (IMP *)&OriginalDefaultDictionary);
        Hook(object_getClass(NSClassFromString(@"FIRApp")),
             NSSelectorFromString(@"configureWithName:options:"),
             (IMP)Configure, (IMP *)&OriginalConfigure);

        Hook(object_getClass(MainBundle), @selector(objectForInfoDictionaryKey:),
             (IMP)InfoValue, (IMP *)&OriginalInfoValue);
        Hook(object_getClass(MainBundle), @selector(infoDictionary),
             (IMP)Info, (IMP *)&OriginalInfo);

        NSURLSession *probe = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
        Class cls = object_getClass(probe);
        Hook(cls, @selector(dataTaskWithRequest:completionHandler:),
             (IMP)DataCompletion, (IMP *)&OriginalDataCompletion);
        Hook(cls, @selector(dataTaskWithRequest:),
             (IMP)Data, (IMP *)&OriginalData);
        Hook(cls, @selector(uploadTaskWithRequest:fromData:completionHandler:),
             (IMP)Upload, (IMP *)&OriginalUpload);
        [probe invalidateAndCancel];
    }
}
