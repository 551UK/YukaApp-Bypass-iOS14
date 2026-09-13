#import <Foundation/Foundation.h>
#import <objc/runtime.h>

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
__attribute__((constructor)) static void Initialize(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"yuca.scanner"]) return;
        Hook(object_getClass(NSBundle.mainBundle), @selector(objectForInfoDictionaryKey:), (IMP)InfoValue, (IMP *)&OriginalInfoValue);
        Hook(object_getClass(NSBundle.mainBundle), @selector(infoDictionary), (IMP)Info, (IMP *)&OriginalInfo);
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://app.yuka.io"]];
        Class requestClass = object_getClass(request);
        Hook(requestClass, @selector(setValue:forHTTPHeaderField:), (IMP)SetHeader, (IMP *)&OriginalSet);
        if (OriginalSet) Hook(requestClass, @selector(addValue:forHTTPHeaderField:), (IMP)AddHeader, (IMP *)&OriginalAdd);
        Hook(requestClass, @selector(setAllHTTPHeaderFields:), (IMP)AllHeaders, (IMP *)&OriginalAll);
        Hook(object_getClass(NSURLSessionConfiguration.defaultSessionConfiguration), @selector(setHTTPAdditionalHeaders:), (IMP)AdditionalHeaders, (IMP *)&OriginalAdditional);
    }
}
