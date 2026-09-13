#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>

static NSMutableArray<NSString *> *RecentResults;
static NSUInteger RequestCount;
static NSString *HookStatus = @"Starting";
static UIWindow *ActiveWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive || ![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) if (window.isKeyWindow) return window;
    }
    // Yuka 4.38 may use the pre-scene UIApplication lifecycle on iOS 14.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *window in UIApplication.sharedApplication.windows) if (window.isKeyWindow) return window;
#pragma clang diagnostic pop
    return nil;
}
static NSString *DiagnosticSummary(void) {
    return [NSString stringWithFormat:@"Tweak 1.0.3 loaded\n%@\nRequests observed: %lu\n\n%@", HookStatus, (unsigned long)RequestCount,
        RecentResults.count ? [RecentResults componentsJoinedByString:@"\n\n"] : @"No completed requests captured yet. Scan a product, then tap this button again."];
}
@interface YukaDiagnosticButton : UIButton
- (void)showResult;
@end
@implementation YukaDiagnosticButton
- (void)showResult {
    UIViewController *controller = ActiveWindow().rootViewController;
    while (controller.presentedViewController) controller = controller.presentedViewController;
    if (!controller) return;
    if ([controller isKindOfClass:UIAlertController.class]) {
        ((UIAlertController *)controller).message = DiagnosticSummary();
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Yuka diagnostics" message:DiagnosticSummary() preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}
@end
static void ShowDiagnosticButton(void) {
    UIWindow *window = ActiveWindow();
    if (!window) return;
    static YukaDiagnosticButton *button;
    if (!button) {
        button = [YukaDiagnosticButton buttonWithType:UIButtonTypeSystem];
        [button setTitle:@"Yuka 1.0.3 • Info" forState:UIControlStateNormal];
        [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        button.backgroundColor = [UIColor colorWithRed:0 green:0.38 blue:0.3 alpha:0.95];
        button.layer.cornerRadius = 8;
        [button addTarget:button action:@selector(showResult) forControlEvents:UIControlEventTouchUpInside];
        button.accessibilityLabel = @"Yuka diagnostic results";
    }
    button.frame = CGRectMake(MAX(8, window.bounds.size.width - 160), window.safeAreaInsets.top + 6, 150, 34);
    if (button.superview != window) [window addSubview:button];
    [window bringSubviewToFront:button];
}
static NSString *const SpoofVersion = @"5.3";
static NSString *const SpoofBuild = @"2654";
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
    if (self == NSBundle.mainBundle && [key isEqualToString:@"CFBundleVersion"]) return SpoofBuild;
    return OriginalInfoValue(self, cmd, key);
}
static NSDictionary *(*OriginalInfo)(id, SEL);
static NSDictionary *Info(id self, SEL cmd) {
    NSDictionary *value = OriginalInfo(self, cmd);
    if (self != NSBundle.mainBundle || !value) return value;
    NSMutableDictionary *copy = [value mutableCopy];
    copy[@"CFBundleShortVersionString"] = SpoofVersion;
    copy[@"CFBundleVersion"] = SpoofBuild;
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
    if (bundle == CFBundleGetMainBundle() && key && CFEqual(key, CFSTR("CFBundleVersion"))) return (__bridge CFTypeRef)SpoofBuild;
    return OriginalCFValue(bundle, key);
}
static NSURLRequest *FinalRequest(NSURLRequest *request) {
    if (!request) return request;
    NSString *host = request.URL.host.lowercaseString;
    BOOL yukaHost = [host isEqualToString:@"yuka.io"] || [host hasSuffix:@".yuka.io"] || [host isEqualToString:@"goodtoucan.com"] || [host hasSuffix:@".goodtoucan.com"];
    if (!yukaHost && ![request valueForHTTPHeaderField:@"X-Yuka-App-Version"]) return request;
    NSMutableURLRequest *copy = [request mutableCopy];
    [copy setValue:SpoofVersion forHTTPHeaderField:@"X-Yuka-App-Version"];
    return copy;
}
typedef void (^Completion)(NSData *, NSURLResponse *, NSError *);
// Diagnostic output deliberately excludes URLs, tokens, headers and response values.
static void ReportProductResult(NSURLRequest *request, NSData *data, NSURLResponse *response, NSError *error) {
    NSString *host = request.URL.host.lowercaseString;
    if (!host.length) return;
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
    BOOL product = [request.URL.path containsString:@"/product/"];
    NSString *category = product ? @"Product" : ([host hasSuffix:@"goodtoucan.com"] ? @"Yuka API" : @"Other service");
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!RecentResults) RecentResults = [NSMutableArray array];
        [RecentResults addObject:[NSString stringWithFormat:@"%@: %@", category, detail]];
        if (RecentResults.count > 4) [RecentResults removeObjectAtIndex:0];
        ShowDiagnosticButton();
    });
}
static NSURLSessionDataTask *(*OriginalDataCompletion)(id, SEL, NSURLRequest *, Completion);
static NSURLSessionDataTask *DataCompletion(id self, SEL cmd, NSURLRequest *request, Completion completion) {
    dispatch_async(dispatch_get_main_queue(), ^{ RequestCount++; });
    if (!completion) return OriginalDataCompletion(self, cmd, FinalRequest(request), nil);
    return OriginalDataCompletion(self, cmd, FinalRequest(request), ^(NSData *data, NSURLResponse *response, NSError *error) {
        ReportProductResult(request, data, response, error);
        completion(data, response, error);
    });
}
static NSURLSessionDataTask *(*OriginalData)(id, SEL, NSURLRequest *);
static NSURLSessionDataTask *Data(id self, SEL cmd, NSURLRequest *request) {
    dispatch_async(dispatch_get_main_queue(), ^{ RequestCount++; });
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
        HookStatus = [NSString stringWithFormat:@"Alamofire: %@ / %@\nSession: %@", OriginalDelegateData ? @"data hooked" : @"data missing", OriginalDelegateComplete ? @"completion hooked" : @"completion missing", OriginalData ? @"hooked" : @"missing"];
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer) {
                (void)timer;
                Class lateDelegate = NSClassFromString(@"_TtC9Alamofire15SessionDelegate");
                if (lateDelegate && !OriginalDelegateData) Hook(lateDelegate, @selector(URLSession:dataTask:didReceiveData:), (IMP)DelegateData, (IMP *)&OriginalDelegateData);
                if (lateDelegate && !OriginalDelegateComplete) Hook(lateDelegate, @selector(URLSession:task:didCompleteWithError:), (IMP)DelegateComplete, (IMP *)&OriginalDelegateComplete);
                HookStatus = [NSString stringWithFormat:@"Alamofire: %@ / %@\nSession: %@", OriginalDelegateData ? @"data hooked" : @"data missing", OriginalDelegateComplete ? @"completion hooked" : @"completion missing", OriginalData ? @"hooked" : @"missing"];
                ShowDiagnosticButton();
            }];
        });
        Class requestClass = object_getClass(request);
        Hook(requestClass, @selector(setValue:forHTTPHeaderField:), (IMP)SetHeader, (IMP *)&OriginalSet);
        if (OriginalSet) Hook(requestClass, @selector(addValue:forHTTPHeaderField:), (IMP)AddHeader, (IMP *)&OriginalAdd);
        Hook(requestClass, @selector(setAllHTTPHeaderFields:), (IMP)AllHeaders, (IMP *)&OriginalAll);
        Hook(object_getClass(NSURLSessionConfiguration.defaultSessionConfiguration), @selector(setHTTPAdditionalHeaders:), (IMP)AdditionalHeaders, (IMP *)&OriginalAdditional);
    }
}
