#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#import "YukaFirebaseConfig.h"

static NSString *const kSpoofAppVersion = @"5.3";
static NSString *const kSpoofBuild = @"2654";
static NSString *const kSpoofIOSVersion = @"16.2";
static NSString *const kSpoofOSString = @"Version 16.2 (Build 20C65)";
static NSString *const kSpoofUserAgent = @"Yuka/2654 CFNetwork/1402.0.8 Darwin/22.3.0";

static id SpoofedInfoValue(NSString *key) {
    if ([key isEqualToString:@"CFBundleShortVersionString"]) return kSpoofAppVersion;
    if ([key isEqualToString:@"CFBundleVersion"]) return kSpoofBuild;
    if ([key isEqualToString:@"MinimumOSVersion"]) return @"15.5";
    if ([key isEqualToString:@"DTPlatformVersion"]) return @"26.5";
    if ([key isEqualToString:@"DTSDKName"]) return @"iphoneos26.5";
    if ([key isEqualToString:@"DTSDKBuild"]) return @"23F81a";
    if ([key isEqualToString:@"DTPlatformBuild"]) return @"23F81a";
    if ([key isEqualToString:@"DTXcode"]) return @"2660";
    if ([key isEqualToString:@"DTXcodeBuild"]) return @"17F113";
    if ([key isEqualToString:@"DTAppStoreToolsBuild"]) return @"17F106";
    if ([key isEqualToString:@"BuildMachineOSBuild"]) return @"25G72";
    if ([key isEqualToString:@"BAUsesAppleHosting"]) return @YES;
    if ([key isEqualToString:@"BAAppGroupID"]) return @"group.yuca.scanner";
    if ([key isEqualToString:@"BAHasManagedAssetPacks"]) return @YES;
    if ([key isEqualToString:@"GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_STORAGE"]) return @NO;
    return nil;
}

static void ApplyLatestInfo(NSMutableDictionary *dict) {
    if (!dict) return;
    NSArray<NSString *> *keys = @[@"CFBundleShortVersionString", @"CFBundleVersion", @"MinimumOSVersion", @"DTPlatformVersion", @"DTSDKName", @"DTSDKBuild", @"DTPlatformBuild", @"DTXcode", @"DTXcodeBuild", @"DTAppStoreToolsBuild", @"BuildMachineOSBuild", @"BAUsesAppleHosting", @"BAAppGroupID", @"BAHasManagedAssetPacks", @"GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_STORAGE"];
    for (NSString *key in keys) {
        id value = SpoofedInfoValue(key);
        if (value) dict[key] = value;
    }
}

static BOOL IsYukaHost(NSString *host) {
    NSString *h = host.lowercaseString;
    return [h isEqualToString:@"goodtoucan.com"] || [h hasSuffix:@".goodtoucan.com"] || [h isEqualToString:@"yuka.io"] || [h hasSuffix:@".yuka.io"];
}

static BOOL IsGoogleHost(NSString *host) {
    NSString *h = host.lowercaseString;
    return [h hasSuffix:@".googleapis.com"] || [h hasSuffix:@".google.com"] || [h hasSuffix:@".firebaseio.com"];
}

static NSString *LatestAcceptVersionForURL(NSURL *url) {
    NSString *p = url.path.lowercaseString ?: @"";
    if ([p containsString:@"/cosmetics/"]) return @"4";
    if ([p containsString:@"/algolia/"]) return @"3";
    if ([p containsString:@"/ocr/"]) return @"2";
    if ([p containsString:@"/food/"] || [p containsString:@"/user/quota"] || [p containsString:@"/metadata"] || [p containsString:@"/parse-origins"]) return @"17";
    return nil;
}

static BOOL HeaderIs(NSString *field, NSString *wanted) {
    return [field isKindOfClass:NSString.class] && [field caseInsensitiveCompare:wanted] == NSOrderedSame;
}

static NSString *LatestHeaderValue(NSMutableURLRequest *request, NSString *value, NSString *field) {
    NSURL *url = request.URL;
    if (HeaderIs(field, @"X-Yuka-App-Version") && IsYukaHost(url.host)) return kSpoofAppVersion;
    if (HeaderIs(field, @"X-Accept-Version") && IsYukaHost(url.host)) return LatestAcceptVersionForURL(url) ?: value;
    if (HeaderIs(field, @"User-Agent") && IsYukaHost(url.host)) return kSpoofUserAgent;
    if (HeaderIs(field, @"X-osv")) return kSpoofIOSVersion;
    if (HeaderIs(field, @"X-Goog-Api-Key") && [value isEqualToString:OldFirebaseKey]) return CurrentFirebaseKey;
    return value;
}

static NSURLRequest *LatestRequest(NSURLRequest *request) {
    if (!request || !request.URL) return request;
    BOOL yuka = IsYukaHost(request.URL.host);
    BOOL google = IsGoogleHost(request.URL.host);
    if (!yuka && !google && ![request valueForHTTPHeaderField:@"X-Yuka-App-Version"] && ![request valueForHTTPHeaderField:@"X-Accept-Version"]) return request;

    NSMutableURLRequest *copy = [request mutableCopy];
    if (yuka) {
        [copy setValue:kSpoofAppVersion forHTTPHeaderField:@"X-Yuka-App-Version"];
        NSString *accept = LatestAcceptVersionForURL(copy.URL);
        if (accept) [copy setValue:accept forHTTPHeaderField:@"X-Accept-Version"];
        [copy setValue:kSpoofUserAgent forHTTPHeaderField:@"User-Agent"];
        if ([copy valueForHTTPHeaderField:@"X-osv"]) [copy setValue:kSpoofIOSVersion forHTTPHeaderField:@"X-osv"];
    }

    if (google) {
        NSString *apiKey = [copy valueForHTTPHeaderField:@"X-Goog-Api-Key"];
        if ([apiKey isEqualToString:OldFirebaseKey]) [copy setValue:CurrentFirebaseKey forHTTPHeaderField:@"X-Goog-Api-Key"];
        if ([copy valueForHTTPHeaderField:@"X-osv"]) [copy setValue:kSpoofIOSVersion forHTTPHeaderField:@"X-osv"];
        if ([copy.URL.host.lowercaseString isEqualToString:@"firebaseappcheck.googleapis.com"]) [copy setValue:@"yuca.scanner" forHTTPHeaderField:@"X-Ios-Bundle-Identifier"];

        NSURLComponents *components = [NSURLComponents componentsWithURL:copy.URL resolvingAgainstBaseURL:NO];
        if (components.queryItems.count) {
            NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray arrayWithCapacity:components.queryItems.count];
            BOOL changed = NO;
            for (NSURLQueryItem *item in components.queryItems) {
                if ([item.name isEqualToString:@"key"] && [item.value isEqualToString:OldFirebaseKey]) {
                    [items addObject:[NSURLQueryItem queryItemWithName:item.name value:CurrentFirebaseKey]];
                    changed = YES;
                } else {
                    [items addObject:item];
                }
            }
            if (changed) {
                components.queryItems = items;
                if (components.URL) copy.URL = components.URL;
            }
        }
    }
    return copy;
}

static BOOL HookMethod(Class cls, SEL sel, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;
    IMP old = method_getImplementation(method);
    if (original) *original = old;
    const char *types = method_getTypeEncoding(method);
    if (!class_addMethod(cls, sel, replacement, types)) method_setImplementation(class_getInstanceMethod(cls, sel), replacement);
    return YES;
}

static id (*OrigInfoValue)(id, SEL, NSString *);
static id NewInfoValue(id self, SEL cmd, NSString *key) {
    if (self == NSBundle.mainBundle) {
        id value = SpoofedInfoValue(key);
        if (value) return value;
    }
    return OrigInfoValue(self, cmd, key);
}

static NSDictionary *(*OrigInfoDictionary)(id, SEL);
static NSDictionary *NewInfoDictionary(id self, SEL cmd) {
    NSDictionary *original = OrigInfoDictionary(self, cmd);
    if (self != NSBundle.mainBundle || !original) return original;
    NSMutableDictionary *copy = [original mutableCopy];
    ApplyLatestInfo(copy);
    return copy;
}

static NSString *(*OrigSystemVersion)(id, SEL);
static NSString *NewSystemVersion(id self, SEL cmd) {
    (void)self; (void)cmd;
    return kSpoofIOSVersion;
}

static NSString *(*OrigOSVersionString)(id, SEL);
static NSString *NewOSVersionString(id self, SEL cmd) {
    (void)self; (void)cmd;
    return kSpoofOSString;
}

static void (*OrigSetHeader)(id, SEL, NSString *, NSString *);
static void NewSetHeader(id self, SEL cmd, NSString *value, NSString *field) {
    OrigSetHeader(self, cmd, LatestHeaderValue((NSMutableURLRequest *)self, value, field), field);
}

static void (*OrigAddHeader)(id, SEL, NSString *, NSString *);
static void NewAddHeader(id self, SEL cmd, NSString *value, NSString *field) {
    NSString *latest = LatestHeaderValue((NSMutableURLRequest *)self, value, field);
    if (HeaderIs(field, @"X-Yuka-App-Version") || HeaderIs(field, @"X-Accept-Version") || HeaderIs(field, @"User-Agent") || HeaderIs(field, @"X-osv") || HeaderIs(field, @"X-Goog-Api-Key")) {
        OrigSetHeader(self, @selector(setValue:forHTTPHeaderField:), latest, field);
        return;
    }
    OrigAddHeader(self, cmd, latest, field);
}

typedef void (^DataCompletion)(NSData *, NSURLResponse *, NSError *);
static NSURLSessionDataTask *(*OrigDataTaskCompletion)(id, SEL, NSURLRequest *, DataCompletion);
static NSURLSessionDataTask *NewDataTaskCompletion(id self, SEL cmd, NSURLRequest *request, DataCompletion completion) {
    return OrigDataTaskCompletion(self, cmd, LatestRequest(request), completion);
}

static NSURLSessionDataTask *(*OrigDataTask)(id, SEL, NSURLRequest *);
static NSURLSessionDataTask *NewDataTask(id self, SEL cmd, NSURLRequest *request) {
    return OrigDataTask(self, cmd, LatestRequest(request));
}

static NSURLSessionUploadTask *(*OrigUploadTaskCompletion)(id, SEL, NSURLRequest *, NSData *, DataCompletion);
static NSURLSessionUploadTask *NewUploadTaskCompletion(id self, SEL cmd, NSURLRequest *request, NSData *data, DataCompletion completion) {
    return OrigUploadTaskCompletion(self, cmd, LatestRequest(request), data, completion);
}

static CFTypeRef (*OrigCFBundleGetValue)(CFBundleRef, CFStringRef);
static CFTypeRef NewCFBundleGetValue(CFBundleRef bundle, CFStringRef key) {
    if (bundle == CFBundleGetMainBundle() && key) {
        NSString *nsKey = (__bridge NSString *)key;
        id value = SpoofedInfoValue(nsKey);
        if (value) return (__bridge CFTypeRef)value;
    }
    return OrigCFBundleGetValue(bundle, key);
}

static void InstallCFBundleHook(void) {
    typedef void (*MSHookFunctionType)(void *, void *, void **);
    MSHookFunctionType hook = (MSHookFunctionType)dlsym(RTLD_DEFAULT, "MSHookFunction");
    void *target = dlsym(RTLD_DEFAULT, "CFBundleGetValueForInfoDictionaryKey");
    if (hook && target) hook(target, (void *)&NewCFBundleGetValue, (void **)&OrigCFBundleGetValue);
}

__attribute__((constructor)) static void InitializeYukaSpoof(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"yuca.scanner"]) return;

        Class bundleClass = object_getClass(NSBundle.mainBundle);
        HookMethod(bundleClass, @selector(objectForInfoDictionaryKey:), (IMP)NewInfoValue, (IMP *)&OrigInfoValue);
        HookMethod(bundleClass, @selector(infoDictionary), (IMP)NewInfoDictionary, (IMP *)&OrigInfoDictionary);

        Class deviceClass = object_getClass(UIDevice.currentDevice);
        HookMethod(deviceClass, @selector(systemVersion), (IMP)NewSystemVersion, (IMP *)&OrigSystemVersion);

        Class processClass = object_getClass(NSProcessInfo.processInfo);
        HookMethod(processClass, @selector(operatingSystemVersionString), (IMP)NewOSVersionString, (IMP *)&OrigOSVersionString);

        NSMutableURLRequest *probeRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://goodtoucan.com/"]];
        Class requestClass = object_getClass(probeRequest);
        HookMethod(requestClass, @selector(setValue:forHTTPHeaderField:), (IMP)NewSetHeader, (IMP *)&OrigSetHeader);
        HookMethod(requestClass, @selector(addValue:forHTTPHeaderField:), (IMP)NewAddHeader, (IMP *)&OrigAddHeader);

        NSURLSession *probeSession = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
        Class sessionClass = object_getClass(probeSession);
        HookMethod(sessionClass, @selector(dataTaskWithRequest:completionHandler:), (IMP)NewDataTaskCompletion, (IMP *)&OrigDataTaskCompletion);
        HookMethod(sessionClass, @selector(dataTaskWithRequest:), (IMP)NewDataTask, (IMP *)&OrigDataTask);
        HookMethod(sessionClass, @selector(uploadTaskWithRequest:fromData:completionHandler:), (IMP)NewUploadTaskCompletion, (IMP *)&OrigUploadTaskCompletion);
        [probeSession invalidateAndCancel];

        InstallCFBundleHook();
        NSLog(@"[YukaBypass] 2.0.0 active: Yuka 5.3/2654, iOS 16.2, API versions food=17 cosmetics=4 algolia=3 ocr=2.");
    }
}
