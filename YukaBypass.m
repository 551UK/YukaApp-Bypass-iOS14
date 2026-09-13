#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#import "YukaFirebaseConfig.h"

static NSMutableArray<NSString *> *RecentResults;
static NSUInteger RequestCount;
static NSString *LastProductResult;
static NSString *LastAPIResult;
static NSString *FirebaseStatus = @"No Firebase callback observed";
static NSString *FirebaseHookStatus = @"Installing";
static NSUInteger FirebaseKeyRewrites;
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
    id auth = nil;
    Class authClass = NSClassFromString(@"FIRAuth");
    if ([authClass respondsToSelector:@selector(auth)]) auth = ((id (*)(id, SEL))objc_msgSend)(authClass, @selector(auth));
    id user = nil;
    if ([auth respondsToSelector:@selector(currentUser)]) user = ((id (*)(id, SEL))objc_msgSend)(auth, @selector(currentUser));
    return [NSString stringWithFormat:@"Tweak 1.0.6 loaded\n%@\nFirebase config: %@\nFirebase hooks: %@\nSigned in: %@\nRequests observed: %lu\n\nProduct: %@\n\nAPI: %@\n\nFirebase: %@\n\n%@", HookStatus, [NSString stringWithFormat:@"Request-only update (%lu replacements)", (unsigned long)FirebaseKeyRewrites], FirebaseHookStatus, user ? @"yes" : @"no", (unsigned long)RequestCount,
        LastProductResult ?: @"No product request captured", LastAPIResult ?: @"No Yuka API request captured", FirebaseStatus,
        RecentResults.count ? [RecentResults componentsJoinedByString:@"\n"] : @"No relevant events yet."];
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
        [button setTitle:@"Yuka 1.0.6 • Info" forState:UIControlStateNormal];
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
    BOOL google = [host hasSuffix:@".googleapis.com"];
    if (!yukaHost && !google && ![request valueForHTTPHeaderField:@"X-Yuka-App-Version"]) return request;
    NSMutableURLRequest *copy = [request mutableCopy];
    if (yukaHost || [request valueForHTTPHeaderField:@"X-Yuka-App-Version"]) [copy setValue:SpoofVersion forHTTPHeaderField:@"X-Yuka-App-Version"];
    if (google) {
        NSURLComponents *url = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
        NSMutableArray *items = [NSMutableArray array];
        BOOL changed = NO;
        for (NSURLQueryItem *item in url.queryItems) {
            if ([item.name isEqualToString:@"key"] && [item.value isEqualToString:OldFirebaseKey]) {
                [items addObject:[NSURLQueryItem queryItemWithName:item.name value:CurrentFirebaseKey]];
                changed = YES;
                dispatch_async(dispatch_get_main_queue(), ^{ FirebaseKeyRewrites++; });
            } else [items addObject:item];
        }
        if (changed) { url.queryItems = items; if (url.URL) copy.URL = url.URL; }
        if ([[request valueForHTTPHeaderField:@"X-Goog-Api-Key"] isEqualToString:OldFirebaseKey]) {
            [copy setValue:CurrentFirebaseKey forHTTPHeaderField:@"X-Goog-Api-Key"];
            dispatch_async(dispatch_get_main_queue(), ^{ FirebaseKeyRewrites++; });
        }
    }
    return copy;
}
static void ObserveStart(NSURLRequest *request) {
    NSString *host = request.URL.host.lowercaseString;
    BOOL api = [host isEqualToString:@"goodtoucan.com"] || [host hasSuffix:@".goodtoucan.com"];
    if (!api) return;
    BOOL product = [request.URL.path containsString:@"/product/"];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (product) LastProductResult = @"Request created; awaiting response";
        else LastAPIResult = @"Request created; awaiting response";
    });
}
typedef void (^Completion)(NSData *, NSURLResponse *, NSError *);
// Diagnostic output deliberately excludes URLs, tokens, headers and response values.
static void ReportProductResult(NSURLRequest *request, NSData *data, NSURLResponse *response, NSError *error) {
    NSString *host = request.URL.host.lowercaseString;
    if (!host.length) return;
    NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 0;
    NSString *shape = @"No JSON body";
    NSString *serverReason = @"";
    if (data.length) {
        id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:NULL];
        if ([json isKindOfClass:NSDictionary.class]) {
            id errorObject = json[@"error"];
            if ([errorObject isKindOfClass:NSDictionary.class]) {
                NSMutableArray *reasons = [NSMutableArray array];
                id statusValue = errorObject[@"status"];
                if ([statusValue isKindOfClass:NSString.class] && [statusValue rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789"] invertedSet]].location == NSNotFound) [reasons addObject:statusValue];
                id details = errorObject[@"details"];
                if ([details isKindOfClass:NSArray.class]) for (id item in details) {
                    if (![item isKindOfClass:NSDictionary.class]) continue;
                    id reason = item[@"reason"];
                    if ([reason isKindOfClass:NSString.class] && [reason rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789"] invertedSet]].location == NSNotFound) [reasons addObject:reason];
                }
                serverReason = [reasons componentsJoinedByString:@" "];
            }
            NSArray *keys = [[(NSDictionary *)json allKeys] sortedArrayUsingSelector:@selector(compare:)];
            if (keys.count > 20) keys = [keys subarrayWithRange:NSMakeRange(0, 20)];
            shape = [@"JSON keys: " stringByAppendingString:[keys componentsJoinedByString:@", "]];
            if (shape.length > 400) shape = [shape substringToIndex:400];
        } else if ([json isKindOfClass:NSArray.class]) shape = @"JSON array";
        else if (json) shape = @"JSON scalar";
        else shape = @"Non-JSON body";
    }
    NSString *detail = [NSString stringWithFormat:@"%@ HTTP %ld; %@ %ld; %lu bytes; %@ %@", [host hasSuffix:@".googleapis.com"] ? host : @"Service", (long)status, error.domain ?: @"transport OK", (long)error.code, (unsigned long)data.length, shape, serverReason];
    BOOL product = [request.URL.path containsString:@"/product/"];
    BOOL api = [host isEqualToString:@"goodtoucan.com"] || [host hasSuffix:@".goodtoucan.com"];
    if (!api && !product && !error && status < 400) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (product) LastProductResult = detail;
        else if (api) LastAPIResult = detail;
        else {
            if (!RecentResults) RecentResults = [NSMutableArray array];
            [RecentResults addObject:[@"Network failure: " stringByAppendingString:detail]];
            if (RecentResults.count > 3) [RecentResults removeObjectAtIndex:0];
        }
        ShowDiagnosticButton();
    });
}
static NSURLSessionDataTask *(*OriginalDataCompletion)(id, SEL, NSURLRequest *, Completion);
static NSURLSessionDataTask *DataCompletion(id self, SEL cmd, NSURLRequest *request, Completion completion) {
    dispatch_async(dispatch_get_main_queue(), ^{ RequestCount++; });
    ObserveStart(request);
    if (!completion) return OriginalDataCompletion(self, cmd, FinalRequest(request), nil);
    return OriginalDataCompletion(self, cmd, FinalRequest(request), ^(NSData *data, NSURLResponse *response, NSError *error) {
        ReportProductResult(request, data, response, error);
        completion(data, response, error);
    });
}
static NSURLSessionDataTask *(*OriginalData)(id, SEL, NSURLRequest *);
static NSURLSessionDataTask *Data(id self, SEL cmd, NSURLRequest *request) {
    dispatch_async(dispatch_get_main_queue(), ^{ RequestCount++; });
    ObserveStart(request);
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
typedef void (^FirebaseCompletion)(id, NSError *);
static void FirebaseEvent(NSString *operation, id value, NSError *error) {
    NSString *result;
    if (error) {
        NSString *reason = @"";
        NSString *description = error.localizedDescription.uppercaseString;
        for (NSString *term in @[@"APP CHECK", @"APPCHECK", @"PERMISSION", @"UNAUTHENTICATED", @"EXPIRED", @"NETWORK", @"DISABLED", @"API KEY", @"ATTEST", @"UNAVAILABLE", @"OFFLINE"]) {
            if ([description containsString:term]) { reason = term; break; }
        }
        result = [NSString stringWithFormat:@"%@: %@ %ld %@", operation, error.domain, (long)error.code, reason];
    } else result = [NSString stringWithFormat:@"%@: %@", operation, value ? @"success" : @"empty result"];
    dispatch_async(dispatch_get_main_queue(), ^{
        FirebaseStatus = result;
        if (!RecentResults) RecentResults = [NSMutableArray array];
        if (![RecentResults containsObject:result]) [RecentResults addObject:result];
        if (RecentResults.count > 5) [RecentResults removeObjectAtIndex:0];
    });
}
static void FirebaseStart(NSString *operation) {
    dispatch_async(dispatch_get_main_queue(), ^{ FirebaseStatus = [operation stringByAppendingString:@": awaiting callback"]; });
}
static void (*OriginalToken)(id, SEL, BOOL, FirebaseCompletion);
static void Token(id self, SEL cmd, BOOL refresh, FirebaseCompletion completion) {
    if (!completion) { OriginalToken(self, cmd, refresh, nil); return; }
    FirebaseStart(@"Auth token");
    OriginalToken(self, cmd, refresh, ^(id result, NSError *error) {
        FirebaseEvent(@"Auth token", result, error);
        completion(result, error);
    });
}
static void (*OriginalTokenResult)(id, SEL, BOOL, FirebaseCompletion);
static void TokenResult(id self, SEL cmd, BOOL refresh, FirebaseCompletion completion) {
    if (!completion) { OriginalTokenResult(self, cmd, refresh, nil); return; }
    FirebaseStart(@"Auth token result");
    OriginalTokenResult(self, cmd, refresh, ^(id result, NSError *error) {
        FirebaseEvent(@"Auth token result", result, error);
        completion(result, error);
    });
}
static void (*OriginalDocument)(id, SEL, NSInteger, FirebaseCompletion);
static void Document(id self, SEL cmd, NSInteger source, FirebaseCompletion completion) {
    if (!completion) { OriginalDocument(self, cmd, source, nil); return; }
    FirebaseStart(@"Database document");
    OriginalDocument(self, cmd, source, ^(id result, NSError *error) {
        FirebaseEvent(@"Database document", result, error);
        completion(result, error);
    });
}
static void (*OriginalQuery)(id, SEL, NSInteger, FirebaseCompletion);
static void Query(id self, SEL cmd, NSInteger source, FirebaseCompletion completion) {
    if (!completion) { OriginalQuery(self, cmd, source, nil); return; }
    FirebaseStart(@"Database query");
    OriginalQuery(self, cmd, source, ^(id result, NSError *error) {
        FirebaseEvent(@"Database query", result, error);
        completion(result, error);
    });
}
static id (*OriginalQueryListen)(id, SEL, BOOL, FirebaseCompletion);
static id QueryListen(id self, SEL cmd, BOOL options, FirebaseCompletion completion) {
    if (!completion) return OriginalQueryListen(self, cmd, options, nil);
    FirebaseStart(@"Database listener");
    return OriginalQueryListen(self, cmd, options, ^(id result, NSError *error) {
        FirebaseEvent(@"Database listener", result, error);
        completion(result, error);
    });
}
static id (*OriginalDocumentListen)(id, SEL, BOOL, FirebaseCompletion);
static id DocumentListen(id self, SEL cmd, BOOL options, FirebaseCompletion completion) {
    if (!completion) return OriginalDocumentListen(self, cmd, options, nil);
    FirebaseStart(@"Document listener");
    return OriginalDocumentListen(self, cmd, options, ^(id result, NSError *error) {
        FirebaseEvent(@"Document listener", result, error);
        completion(result, error);
    });
}
static id (*OriginalQueryListenSimple)(id, SEL, FirebaseCompletion);
static id QueryListenSimple(id self, SEL cmd, FirebaseCompletion completion) {
    if (!completion) return OriginalQueryListenSimple(self, cmd, nil);
    FirebaseStart(@"Database listener");
    return OriginalQueryListenSimple(self, cmd, ^(id result, NSError *error) {
        FirebaseEvent(@"Database listener", result, error);
        completion(result, error);
    });
}
static id (*OriginalDocumentListenSimple)(id, SEL, FirebaseCompletion);
static id DocumentListenSimple(id self, SEL cmd, FirebaseCompletion completion) {
    if (!completion) return OriginalDocumentListenSimple(self, cmd, nil);
    FirebaseStart(@"Document listener");
    return OriginalDocumentListenSimple(self, cmd, ^(id result, NSError *error) {
        FirebaseEvent(@"Document listener", result, error);
        completion(result, error);
    });
}
static void InstallFirebaseHooks(void) {
    Class user = NSClassFromString(@"FIRUser");
    Class document = NSClassFromString(@"FIRDocumentReference");
    Class query = NSClassFromString(@"FIRQuery");
    if (user && !OriginalToken) Hook(user, NSSelectorFromString(@"getIDTokenForcingRefresh:completion:"), (IMP)Token, (IMP *)&OriginalToken);
    if (user && !OriginalTokenResult) Hook(user, NSSelectorFromString(@"getIDTokenResultForcingRefresh:completion:"), (IMP)TokenResult, (IMP *)&OriginalTokenResult);
    if (document && !OriginalDocument) Hook(document, NSSelectorFromString(@"getDocumentWithSource:completion:"), (IMP)Document, (IMP *)&OriginalDocument);
    if (query && !OriginalQuery) Hook(query, NSSelectorFromString(@"getDocumentsWithSource:completion:"), (IMP)Query, (IMP *)&OriginalQuery);
    if (query && !OriginalQueryListen) Hook(query, NSSelectorFromString(@"addSnapshotListenerWithIncludeMetadataChanges:listener:"), (IMP)QueryListen, (IMP *)&OriginalQueryListen);
    if (document && !OriginalDocumentListen) Hook(document, NSSelectorFromString(@"addSnapshotListenerWithIncludeMetadataChanges:listener:"), (IMP)DocumentListen, (IMP *)&OriginalDocumentListen);
    if (query && !OriginalQueryListenSimple) Hook(query, NSSelectorFromString(@"addSnapshotListener:"), (IMP)QueryListenSimple, (IMP *)&OriginalQueryListenSimple);
    if (document && !OriginalDocumentListenSimple) Hook(document, NSSelectorFromString(@"addSnapshotListener:"), (IMP)DocumentListenSimple, (IMP *)&OriginalDocumentListenSimple);
    FirebaseHookStatus = [NSString stringWithFormat:@"auth %@, database %@, listener %@", OriginalToken ? @"yes" : @"no", OriginalDocument ? @"yes" : @"no", OriginalQueryListen ? @"yes" : @"no"];
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
        InstallFirebaseHooks();
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
                InstallFirebaseHooks();
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
