#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <fcntl.h>
#include <unistd.h>
#import "YukaFirebaseConfig.h"

// Signatures verified against the Firebase 10.10.0 shipped in Yuka 4.38.
@interface NSObject (YukaOptions)
- (instancetype)initWithContentsOfFile:(NSString *)path;
- (NSDictionary *)optionsDictionary;
@end
static NSString *ConfigPath;
static NSString *LogPath;
static NSBundle *MainBundle;
static NSString *const Version = @"5.3";
static NSString *const Build = @"2654";
static void Log(NSString *line) {
    if (!LogPath || !line) return;
    NSData *data = [[NSString stringWithFormat:@"%@ %@\n", NSDate.date, line] dataUsingEncoding:NSUTF8StringEncoding];
    int fd = open(LogPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd >= 0) { (void)write(fd, data.bytes, data.length); close(fd); }
}
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
    NSDictionary *value = UpdatedDictionary(OriginalDefaultDictionary(self, cmd));
    Log([NSString stringWithFormat:@"Firebase default config: current key=%@", [value[@"API_KEY"] isEqual:CurrentFirebaseKey] ? @"yes" : @"no"]);
    return value;
}
static void (*OriginalConfigure)(id, SEL, NSString *, id);
static void Configure(id self, SEL cmd, NSString *name, id options) {
    // Never edit an existing FIROptions instance: Firebase locks it after use.
    // Reconstruct from its dictionary before handing it to FIRApp instead.
    id replacement = options;
    if ([options respondsToSelector:@selector(optionsDictionary)]) {
        NSDictionary *original = [options optionsDictionary];
        NSDictionary *updated = UpdatedDictionary(original);
        if (![updated isEqual:original] && ConfigPath && [updated writeToFile:ConfigPath atomically:YES]) {
            id fresh = [[NSClassFromString(@"FIROptions") alloc] initWithContentsOfFile:ConfigPath];
            if (fresh) {
                // Preserve non-plist options using their verified public accessors.
                for (NSString *key in @[@"deepLinkURLScheme", @"appGroupID"]) {
                    SEL getter = NSSelectorFromString(key);
                    NSString *setterName = [NSString stringWithFormat:@"set%@%@:", [[key substringToIndex:1] uppercaseString], [key substringFromIndex:1]];
                    SEL setter = NSSelectorFromString(setterName);
                    if ([options respondsToSelector:getter] && [fresh respondsToSelector:setter]) {
                        id value = ((id (*)(id, SEL))objc_msgSend)(options, getter);
                        ((void (*)(id, SEL, id))objc_msgSend)(fresh, setter, value);
                    }
                }
                replacement = fresh;
            }
        }
        NSDictionary *effective = [replacement optionsDictionary];
        Log([NSString stringWithFormat:@"Firebase configure: current key=%@; current bucket=%@", [effective[@"API_KEY"] isEqual:CurrentFirebaseKey] ? @"yes" : @"no", [effective[@"STORAGE_BUCKET"] isEqual:@"yuka-app"] ? @"yes" : @"no"]);
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
    copy[@"CFBundleShortVersionString"] = Version; copy[@"CFBundleVersion"] = Build;
    return copy;
}
static BOOL YukaHost(NSString *h) {
    return [h isEqual:@"goodtoucan.com"] || [h hasSuffix:@".goodtoucan.com"] || [h isEqual:@"yuka.io"] || [h hasSuffix:@".yuka.io"];
}
static NSURLRequest *Request(NSURLRequest *request) {
    NSString *host = request.URL.host.lowercaseString;
    BOOL yuka = YukaHost(host), google = [host hasSuffix:@".googleapis.com"];
    if (!yuka && !google) return request;
    NSMutableURLRequest *copy = [request mutableCopy];
    if (yuka) {
        [copy setValue:Version forHTTPHeaderField:@"X-Yuka-App-Version"];
        [copy setValue:@"Yuka/2654 CFNetwork/1402.0.8 Darwin/22.3.0" forHTTPHeaderField:@"User-Agent"];
    }
    // Report the requested OS identity in network metadata only. Keep runtime
    // availability checks truthful so iOS 14 does not attempt newer APIs.
    if ([copy valueForHTTPHeaderField:@"X-osv"]) [copy setValue:@"16.2" forHTTPHeaderField:@"X-osv"];
    if (google) {
        if ([[copy valueForHTTPHeaderField:@"X-Goog-Api-Key"] isEqual:OldFirebaseKey])
            [copy setValue:CurrentFirebaseKey forHTTPHeaderField:@"X-Goog-Api-Key"];
        NSURLComponents *url = [NSURLComponents componentsWithURL:copy.URL resolvingAgainstBaseURL:NO];
        NSMutableArray *items = [NSMutableArray array]; BOOL changed = NO;
        for (NSURLQueryItem *item in url.queryItems) {
            if ([item.name isEqual:@"key"] && [item.value isEqual:OldFirebaseKey]) {
                [items addObject:[NSURLQueryItem queryItemWithName:item.name value:CurrentFirebaseKey]]; changed = YES;
            } else [items addObject:item];
        }
        if (changed) { url.queryItems = items; if (url.URL) copy.URL = url.URL; }
    }
    return copy;
}
static void Result(NSURLRequest *request, NSData *data, NSURLResponse *response, NSError *error) {
    NSString *host = request.URL.host.lowercaseString;
    if (!YukaHost(host) && ![host hasSuffix:@".googleapis.com"]) return;
    NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 0;
    NSString *category = [request.URL.path containsString:@"/product/"] ? @"product" : @"startup/service";
    Log([NSString stringWithFormat:@"%@ %@ HTTP=%ld transport=%@/%ld", host, category, (long)status, error.domain ?: @"OK", (long)error.code]);
    if (status >= 400 && data.length) {
        id body = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        id e = [body isKindOfClass:NSDictionary.class] ? body[@"error"] : nil;
        if ([e isKindOfClass:NSDictionary.class]) {
            // Only log machine-readable reason codes; never tokens, URLs, or bodies.
            NSMutableArray *codes = [NSMutableArray array];
            id statusCode = e[@"status"]; if ([statusCode isKindOfClass:NSString.class]) [codes addObject:statusCode];
            id details = e[@"details"];
            if ([details isKindOfClass:NSArray.class]) for (id d in details) {
                id reason = [d isKindOfClass:NSDictionary.class] ? d[@"reason"] : nil;
                if ([reason isKindOfClass:NSString.class]) [codes addObject:reason];
            }
            NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789"] invertedSet];
            for (NSString *code in codes) if (code.length < 100 && [code rangeOfCharacterFromSet:invalid].location == NSNotFound) Log(code);
        }
    }
}
typedef void (^Completion)(NSData *, NSURLResponse *, NSError *);
static id (*OriginalDataCompletion)(id, SEL, NSURLRequest *, Completion);
static id DataCompletion(id self, SEL cmd, NSURLRequest *request, Completion completion) {
    NSURLRequest *updated = Request(request);
    if (!completion) return OriginalDataCompletion(self, cmd, updated, nil);
    return OriginalDataCompletion(self, cmd, updated, ^(NSData *data, NSURLResponse *response, NSError *error) {
        Result(updated, data, response, error); completion(data, response, error);
    });
}
static id (*OriginalData)(id, SEL, NSURLRequest *);
static id Data(id self, SEL cmd, NSURLRequest *request) { return OriginalData(self, cmd, Request(request)); }
static id (*OriginalUpload)(id, SEL, NSURLRequest *, NSData *, Completion);
static id Upload(id self, SEL cmd, NSURLRequest *request, NSData *body, Completion completion) {
    NSURLRequest *updated = Request(request);
    if (!completion) return OriginalUpload(self, cmd, updated, body, nil);
    return OriginalUpload(self, cmd, updated, body, ^(NSData *data, NSURLResponse *response, NSError *error) {
        Result(updated, data, response, error); completion(data, response, error);
    });
}
typedef void (^DocumentCompletion)(id, NSError *);
static void (*OriginalDocument)(id, SEL, DocumentCompletion);
static void Document(id self, SEL cmd, DocumentCompletion completion) {
    if (!completion) { OriginalDocument(self, cmd, nil); return; }
    OriginalDocument(self, cmd, ^(id snapshot, NSError *error) {
        Log([NSString stringWithFormat:@"Firestore document: %@/%ld", error.domain ?: @"OK", (long)error.code]);
        completion(snapshot, error); Log(@"Firestore document callback AFTER app");
    });
}
static void (*OriginalDocumentSource)(id, SEL, NSInteger, DocumentCompletion);
static void DocumentSource(id self, SEL cmd, NSInteger source, DocumentCompletion completion) {
    Log([NSString stringWithFormat:@"Firestore document START source=%ld", (long)source]);
    if (!completion) { OriginalDocumentSource(self, cmd, source, nil); return; }
    OriginalDocumentSource(self, cmd, source, ^(id snapshot, NSError *error) {
        Log([NSString stringWithFormat:@"Firestore document callback BEFORE app: %@/%ld", error.domain ?: @"OK", (long)error.code]);
        completion(snapshot, error);
        Log(@"Firestore document callback AFTER app");
    });
}
static void (*OriginalQuery)(id, SEL, DocumentCompletion);
static void Query(id self, SEL cmd, DocumentCompletion completion) {
    Log(@"Firestore query START");
    if (!completion) { OriginalQuery(self, cmd, nil); return; }
    OriginalQuery(self, cmd, ^(id snapshot, NSError *error) {
        Log([NSString stringWithFormat:@"Firestore query callback BEFORE app: %@/%ld", error.domain ?: @"OK", (long)error.code]);
        completion(snapshot, error); Log(@"Firestore query callback AFTER app");
    });
}
static id (*OriginalListener)(id, SEL, DocumentCompletion);
static id Listener(id self, SEL cmd, DocumentCompletion completion) {
    Log(@"Firestore listener START");
    if (!completion) return OriginalListener(self, cmd, nil);
    return OriginalListener(self, cmd, ^(id snapshot, NSError *error) {
        Log([NSString stringWithFormat:@"Firestore listener callback BEFORE app: %@/%ld", error.domain ?: @"OK", (long)error.code]);
        completion(snapshot, error); Log(@"Firestore listener callback AFTER app");
    });
}
static id (*OriginalRemoteValue)(id, SEL, NSString *);
static id RemoteValue(id self, SEL cmd, NSString *key) {
    // Config key names are useful; fetched values can contain private data.
    Log([@"Remote Config read: " stringByAppendingString:key ?: @"(nil)"]);
    return OriginalRemoteValue(self, cmd, key);
}
__attribute__((constructor)) static void Initialize(void) {
    @autoreleasepool {
        MainBundle = NSBundle.mainBundle;
        if (![MainBundle.bundleIdentifier isEqual:@"yuca.scanner"]) return;
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        LogPath = [docs stringByAppendingPathComponent:@"YukaRepair.txt"];
        // Rotate at launch, retaining the previous run for comparison.
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *previous = [docs stringByAppendingPathComponent:@"YukaRepair-previous.txt"];
        [fm removeItemAtPath:previous error:NULL];
        if ([fm fileExistsAtPath:LogPath]) [fm moveItemAtPath:LogPath toPath:previous error:NULL];
        ConfigPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"YukaRepair-Firebase.plist"];
        Log(@"Yuka Repair 2.1.1 loaded");
        BOOL dict = Hook(object_getClass(NSClassFromString(@"FIROptions")), NSSelectorFromString(@"defaultOptionsDictionary"), (IMP)DefaultDictionary, (IMP *)&OriginalDefaultDictionary);
        BOOL config = Hook(object_getClass(NSClassFromString(@"FIRApp")), NSSelectorFromString(@"configureWithName:options:"), (IMP)Configure, (IMP *)&OriginalConfigure);
        Log([NSString stringWithFormat:@"Firebase hooks: defaults=%d configure=%d", dict, config]);
        Hook(object_getClass(MainBundle), @selector(objectForInfoDictionaryKey:), (IMP)InfoValue, (IMP *)&OriginalInfoValue);
        Hook(object_getClass(MainBundle), @selector(infoDictionary), (IMP)Info, (IMP *)&OriginalInfo);
        NSURLSession *probe = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
        Class cls = object_getClass(probe);
        Hook(cls, @selector(dataTaskWithRequest:completionHandler:), (IMP)DataCompletion, (IMP *)&OriginalDataCompletion);
        Hook(cls, @selector(dataTaskWithRequest:), (IMP)Data, (IMP *)&OriginalData);
        Hook(cls, @selector(uploadTaskWithRequest:fromData:completionHandler:), (IMP)Upload, (IMP *)&OriginalUpload);
        [probe invalidateAndCancel];
        Hook(NSClassFromString(@"FIRDocumentReference"), NSSelectorFromString(@"getDocumentWithCompletion:"), (IMP)Document, (IMP *)&OriginalDocument);
        BOOL docSource = Hook(NSClassFromString(@"FIRDocumentReference"), NSSelectorFromString(@"getDocumentWithSource:completion:"), (IMP)DocumentSource, (IMP *)&OriginalDocumentSource);
        BOOL query = Hook(NSClassFromString(@"FIRQuery"), NSSelectorFromString(@"getDocumentsWithCompletion:"), (IMP)Query, (IMP *)&OriginalQuery);
        BOOL listener = Hook(NSClassFromString(@"FIRQuery"), NSSelectorFromString(@"addSnapshotListener:"), (IMP)Listener, (IMP *)&OriginalListener);
        BOOL remote = Hook(NSClassFromString(@"FIRRemoteConfig"), NSSelectorFromString(@"configValueForKey:"), (IMP)RemoteValue, (IMP *)&OriginalRemoteValue);
        Log([NSString stringWithFormat:@"Trace hooks: documentSource=%d query=%d listener=%d remote=%d", docSource, query, listener, remote]);
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            (void)note; Log(@"Application active");
        }];
    }
}
