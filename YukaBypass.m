#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
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
// Diagnostic output deliberately excludes URLs, tokens, headers and response values.
static void ReportProductResult(NSURLRequest *request, NSData *data, NSURLResponse *response, NSError *error) {
    NSString *host = request.URL.host.lowercaseString;
    if (!([host isEqualToString:@"goodtoucan.com"] || [host hasSuffix:@".goodtoucan.com"])) return;
    if (![request.URL.path containsString:@"/product/"]) return;
    NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 0;
    NSString *shape = @"No JSON body";
    if (data.length) {
        id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:NULL];
        if ([json isKindOfClass:NSDictionary.class]) {
            NSArray *keys = [[(NSDictionary *)json allKeys] sortedArrayUsingSelector:@selector(compare:)];
            if (keys.count > 20) keys = [keys subarrayWithRange:NSMakeRange(0, 20)];
            shape = [@"JSON keys: " stringByAppendingString:[keys componentsJoinedByString:@", "]];
            if (shape.length > 400) shape = [shape substringToIndex:400];
        } else if ([json isKindOfClass:NSArray.class]) shape = @"JSON array";
        else if (json) shape = @"JSON scalar";
        else shape = @"Non-JSON body";
    }
    NSString *detail = [NSString stringWithFormat:@"HTTP: %ld\nTransport: %@ (%ld)\nType: %@\nBytes: %lu\n%@\n\nPlease screenshot this result. No account tokens or response values are shown.",
        (long)status, error.domain ?: @"No transport error", (long)error.code,
        response.MIMEType ?: @"none", (unsigned long)data.length, shape];
    dispatch_async(dispatch_get_main_queue(), ^{
        static CFAbsoluteTime lastShown = 0;
        if (CFAbsoluteTimeGetCurrent() - lastShown < 10) return;
        UIWindow *window = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive || ![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *candidate in ((UIWindowScene *)scene).windows) if (candidate.isKeyWindow) window = candidate;
        }
        UIViewController *controller = window.rootViewController;
        while (controller.presentedViewController) controller = controller.presentedViewController;
        if (!controller) return;
        if ([controller isKindOfClass:UIAlertController.class]) {
            ((UIAlertController *)controller).message = [NSString stringWithFormat:@"%@\n\n%@", ((UIAlertController *)controller).message ?: @"", detail];
            lastShown = CFAbsoluteTimeGetCurrent();
            return;
        }
        lastShown = CFAbsoluteTimeGetCurrent();
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Yuka request diagnostic" message:detail preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [controller presentViewController:alert animated:YES completion:nil];
    });
}
static NSURLSessionDataTask *(*OriginalDataCompletion)(id, SEL, NSURLRequest *, Completion);
static NSURLSessionDataTask *DataCompletion(id self, SEL cmd, NSURLRequest *request, Completion completion) {
    if (!completion) return OriginalDataCompletion(self, cmd, FinalRequest(request), nil);
    return OriginalDataCompletion(self, cmd, FinalRequest(request), ^(NSData *data, NSURLResponse *response, NSError *error) {
        ReportProductResult(request, data, response, error);
        completion(data, response, error);
    });
}
static NSURLSessionDataTask *(*OriginalData)(id, SEL, NSURLRequest *);
static NSURLSessionDataTask *Data(id self, SEL cmd, NSURLRequest *request) {
    return OriginalData(self, cmd, FinalRequest(request));
}
static NSURLSessionUploadTask *(*OriginalUpload)(id, SEL, NSURLRequest *, NSData *, Completion);
static NSURLSessionUploadTask *Upload(id self, SEL cmd, NSURLRequest *request, NSData *body, Completion completion) {
    if (!completion) return OriginalUpload(self, cmd, FinalRequest(request), body, nil);
    return OriginalUpload(self, cmd, FinalRequest(request), body, ^(NSData *data, NSURLResponse *response, NSError *error) {
        ReportProductResult(request, data, response, error);
        completion(data, response, error);
    });
}
static char ResponseDataKey;
static void (*OriginalDelegateData)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSData *);
static void DelegateData(id self, SEL cmd, NSURLSession *session, NSURLSessionDataTask *task, NSData *data) {
    NSURLRequest *request = task.originalRequest;
    NSString *host = request.URL.host.lowercaseString;
    if (([host isEqualToString:@"goodtoucan.com"] || [host hasSuffix:@".goodtoucan.com"]) && [request.URL.path containsString:@"/product/"]) {
        NSMutableData *buffer = objc_getAssociatedObject(task, &ResponseDataKey);
        if (!buffer) {
            buffer = [NSMutableData data];
            objc_setAssociatedObject(task, &ResponseDataKey, buffer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (buffer.length + data.length <= 1024 * 1024) [buffer appendData:data];
    }
    OriginalDelegateData(self, cmd, session, task, data);
}
static void (*OriginalDelegateComplete)(id, SEL, NSURLSession *, NSURLSessionTask *, NSError *);
static void DelegateComplete(id self, SEL cmd, NSURLSession *session, NSURLSessionTask *task, NSError *error) {
    NSData *data = objc_getAssociatedObject(task, &ResponseDataKey);
    ReportProductResult(task.originalRequest, data, task.response, error);
    objc_setAssociatedObject(task, &ResponseDataKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    OriginalDelegateComplete(self, cmd, session, task, error);
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
        Class delegateClass = NSClassFromString(@"_TtC9Alamofire15SessionDelegate");
        if (delegateClass) {
            Hook(delegateClass, @selector(URLSession:dataTask:didReceiveData:), (IMP)DelegateData, (IMP *)&OriginalDelegateData);
            Hook(delegateClass, @selector(URLSession:task:didCompleteWithError:), (IMP)DelegateComplete, (IMP *)&OriginalDelegateComplete);
        }
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
