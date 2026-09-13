#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>

static NSString *const SpoofVersion = @"5.3";
static BOOL IsVersionHeader(id key) {
    return [key isKindOfClass:NSString.class] &&
        [(NSString *)key caseInsensitiveCompare:@"X-Yuka-App-Version"] == NSOrderedSame;
}
static NSDictionary *VersionHeaders(NSDictionary *headers) {
    if (!headers) return nil;
    NSMutableDictionary *copy = [headers mutableCopy];
    for (id key in headers) if (IsVersionHeader(key)) copy[key] = SpoofVersion;
    return copy;
}
// Add an override to the concrete class without changing inherited implementations.
static void Hook(Class cls, SEL sel, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;
    *original = method_getImplementation(method);
    if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(method)))
        method_setImplementation(class_getInstanceMethod(cls, sel), replacement);
}
static id (*OriginalInfoValue)(id, SEL, NSString *);
static id InfoValue(id self, SEL cmd, NSString *key) {
    if (self == NSBundle.mainBundle && [key isEqualToString:@"CFBundleShortVersionString"])
        return SpoofVersion;
    return OriginalInfoValue(self, cmd, key);
}
static NSDictionary *(*OriginalInfo)(id, SEL);
static NSDictionary *Info(id self, SEL cmd) {
    NSDictionary *value = OriginalInfo(self, cmd);
    if (self != NSBundle.mainBundle || !value) return value;
    NSMutableDictionary *copy = [value mutableCopy];
    copy[@"CFBundleShortVersionString"] = SpoofVersion;
    return copy;
}
static void (*OriginalSet)(id, SEL, NSString *, NSString *);
static void SetHeader(id self, SEL cmd, NSString *value, NSString *field) {
    OriginalSet(self, cmd, value && IsVersionHeader(field) ? SpoofVersion : value, field);
}
static void (*OriginalAdd)(id, SEL, NSString *, NSString *);
static void AddHeader(id self, SEL cmd, NSString *value, NSString *field) {
    if (value && IsVersionHeader(field)) {
        OriginalSet(self, @selector(setValue:forHTTPHeaderField:), SpoofVersion, field);
        return;
    }
    OriginalAdd(self, cmd, value, field);
}
static void (*OriginalAll)(id, SEL, NSDictionary *);
static void AllHeaders(id self, SEL cmd, NSDictionary *headers) {
    OriginalAll(self, cmd, VersionHeaders(headers));
}
static void (*OriginalAdditional)(id, SEL, NSDictionary *);
static void AdditionalHeaders(id self, SEL cmd, NSDictionary *headers) {
    OriginalAdditional(self, cmd, VersionHeaders(headers));
}
// Cover CoreFoundation callers that bypass NSBundle's Objective-C methods.
static CFTypeRef (*OriginalCFValue)(CFBundleRef, CFStringRef);
static CFTypeRef CFValue(CFBundleRef bundle, CFStringRef key) {
    if (bundle == CFBundleGetMainBundle() && key &&
        CFEqual(key, CFSTR("CFBundleShortVersionString")))
        return (__bridge CFTypeRef)SpoofVersion;
    return OriginalCFValue(bundle, key);
}
static NSURLRequest *FinalRequest(NSURLRequest *request) {
    if (!request) return request;
    NSString *host = request.URL.host.lowercaseString;
    BOOL yukaHost = [host isEqualToString:@"yuka.io"] || [host hasSuffix:@".yuka.io"];
    if (!yukaHost && ![request valueForHTTPHeaderField:@"X-Yuka-App-Version"]) return request;
    NSMutableURLRequest *copy = [request mutableCopy];
    [copy setValue:SpoofVersion forHTTPHeaderField:@"X-Yuka-App-Version"];
    return copy;
}
typedef void (^Completion)(NSData *, NSURLResponse *, NSError *);
static NSURLSessionDataTask *(*OriginalDataCompletion)(id, SEL, NSURLRequest *, Completion);
static NSURLSessionDataTask *DataCompletion(id self, SEL cmd, NSURLRequest *request, Completion completion) {
    return OriginalDataCompletion(self, cmd, FinalRequest(request), completion);
}
static NSURLSessionDataTask *(*OriginalData)(id, SEL, NSURLRequest *);
static NSURLSessionDataTask *Data(id self, SEL cmd, NSURLRequest *request) {
    return OriginalData(self, cmd, FinalRequest(request));
}
static NSURLSessionUploadTask *(*OriginalUpload)(id, SEL, NSURLRequest *, NSData *, Completion);
static NSURLSessionUploadTask *Upload(id self, SEL cmd, NSURLRequest *request, NSData *body, Completion completion) {
    return OriginalUpload(self, cmd, FinalRequest(request), body, completion);
}
__attribute__((constructor)) static void Initialize(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"yuca.scanner"]) return;
        Hook(object_getClass(NSBundle.mainBundle), @selector(objectForInfoDictionaryKey:), (IMP)InfoValue, (IMP *)&OriginalInfoValue);
        Hook(object_getClass(NSBundle.mainBundle), @selector(infoDictionary), (IMP)Info, (IMP *)&OriginalInfo);
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://app.yuka.io"]];
        void *substrate = dlopen("/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate", RTLD_NOW);
        if (!substrate) substrate = dlopen("/usr/lib/libsubstrate.dylib", RTLD_NOW);
        typedef void (*HookFunction)(void *, void *, void **);
        HookFunction hookFunction = (HookFunction)dlsym(substrate ?: RTLD_DEFAULT, "MSHookFunction");
        if (hookFunction) hookFunction((void *)CFBundleGetValueForInfoDictionaryKey, (void *)CFValue, (void **)&OriginalCFValue);
        else NSLog(@"[YukaBypass] CoreFoundation hook unavailable; NSBundle and header hooks remain active.");
        Class sessionClass = object_getClass(NSURLSession.sharedSession);
        Hook(sessionClass, @selector(dataTaskWithRequest:completionHandler:), (IMP)DataCompletion, (IMP *)&OriginalDataCompletion);
        Hook(sessionClass, @selector(dataTaskWithRequest:), (IMP)Data, (IMP *)&OriginalData);
        Hook(sessionClass, @selector(uploadTaskWithRequest:fromData:completionHandler:), (IMP)Upload, (IMP *)&OriginalUpload);
        Class requestClass = object_getClass(request);
        Hook(requestClass, @selector(setValue:forHTTPHeaderField:), (IMP)SetHeader, (IMP *)&OriginalSet);
        if (OriginalSet) Hook(requestClass, @selector(addValue:forHTTPHeaderField:), (IMP)AddHeader, (IMP *)&OriginalAdd);
        Hook(requestClass, @selector(setAllHTTPHeaderFields:), (IMP)AllHeaders, (IMP *)&OriginalAll);
        Hook(object_getClass(NSURLSessionConfiguration.defaultSessionConfiguration), @selector(setHTTPAdditionalHeaders:), (IMP)AdditionalHeaders, (IMP *)&OriginalAdditional);
    }
}
