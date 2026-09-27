#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *YTLogPath(void) {
    NSString *home = NSHomeDirectory();
    NSString *docs = [home stringByAppendingPathComponent:@"Documents"];
    return [docs stringByAppendingPathComponent:@"YTPlaybackDiag.log"];
}
static NSMapTable<AVPlayerItem *, AVPlayer *> *YTPlayerByItem;
static NSMapTable<AVPlayerItem *, NSNumber *> *YTLastRecoveryByItem;
static NSMutableSet<NSString *> *YTHookedMethods;

static void YTEnsureLogFile(void) {
    NSString *dir = [YTLogPath() stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    if (![[NSFileManager defaultManager] fileExistsAtPath:YTLogPath()]) {
        [@"YouTube Playback Diag Fix v0.1.1\n" writeToFile:YTLogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

static void YTLog(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
static void YTLog(NSString *format, ...) {
    if (!format) return;
    va_list args; va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    static NSDateFormatter *df; static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [NSDateFormatter new];
        df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], msg ?: @""];
    @synchronized ([NSFileManager class]) {
        YTEnsureLogFile();
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:YTLogPath()];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
    NSLog(@"[YTPlaybackDiag] %@", msg);
}

static BOOL YTInterestingURL(NSURL *url) {
    NSString *h = url.host.lowercaseString ?: @"";
    return [h containsString:@"googlevideo.com"] ||
           [h containsString:@"youtube.com"] ||
           [h containsString:@"youtubei.googleapis.com"] ||
           [h containsString:@"googleapis.com"] ||
           [h containsString:@"ytimg.com"];
}

static NSString *YTSafeURL(NSURL *url) {
    if (!url) return @"(null)";
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!c) return [NSString stringWithFormat:@"%@://%@%@", url.scheme ?: @"?", url.host ?: @"?", url.path ?: @""];
    NSSet *allowed = [NSSet setWithArray:@[@"itag",@"mime",@"range",@"rn",@"rbuf",@"dur",@"clen",@"source",@"c"]];
    NSMutableArray *safe = [NSMutableArray array];
    for (NSURLQueryItem *q in c.queryItems ?: @[]) if ([allowed containsObject:q.name.lowercaseString]) [safe addObject:q];
    c.queryItems = safe.count ? safe : nil;
    c.user = nil; c.password = nil; c.fragment = nil;
    return c.string ?: [NSString stringWithFormat:@"%@://%@%@", url.scheme ?: @"?", url.host ?: @"?", url.path ?: @""];
}

static NSString *YTRequestSummary(NSURLRequest *r) {
    if (!r) return @"(null request)";
    NSMutableArray *parts = [NSMutableArray array];
    NSString *range = [r valueForHTTPHeaderField:@"Range"];
    NSString *accept = [r valueForHTTPHeaderField:@"Accept"];
    if (range.length) [parts addObject:[NSString stringWithFormat:@"Range=%@", range]];
    if (accept.length && accept.length < 180) [parts addObject:[NSString stringWithFormat:@"Accept=%@", accept]];
    NSString *extra = parts.count ? [NSString stringWithFormat:@" [%@]", [parts componentsJoinedByString:@"; "]] : @"";
    return [NSString stringWithFormat:@"%@ %@%@", r.HTTPMethod ?: @"GET", YTSafeURL(r.URL), extra];
}

static NSString *YTResponseSummary(NSURLResponse *response) {
    if (![response isKindOfClass:[NSHTTPURLResponse class]]) return @"status=0";
    NSHTTPURLResponse *r = (NSHTTPURLResponse *)response;
    NSDictionary *h = r.allHeaderFields ?: @{};
    NSMutableArray *bits = [NSMutableArray arrayWithObject:[NSString stringWithFormat:@"status=%ld", (long)r.statusCode]];
    for (NSString *key in @[@"Content-Type",@"Content-Length",@"Content-Range",@"Accept-Ranges",@"Server"]) {
        id val = h[key] ?: h[key.lowercaseString];
        if (val) [bits addObject:[NSString stringWithFormat:@"%@=%@", key, val]];
    }
    return [bits componentsJoinedByString:@" "];
}

static void YTLogTaskSnapshot(NSURLSessionTask *task, NSString *tag) {
    if (!task) return;
    NSURLRequest *req = task.currentRequest ?: task.originalRequest;
    if (!YTInterestingURL(req.URL)) return;
    NSError *e = task.error;
    NSString *bang = ([task.response isKindOfClass:[NSHTTPURLResponse class]] && ((NSHTTPURLResponse *)task.response).statusCode >= 400) || e ? @" !!!" : @"";
    YTLog(@"NET %@%@ task=%lu state=%ld %@ bytes=%lld/%lld error=%@ | %@",
          tag, bang, (unsigned long)task.taskIdentifier, (long)task.state,
          YTResponseSummary(task.response), task.countOfBytesReceived, task.countOfBytesExpectedToReceive,
          e ? [NSString stringWithFormat:@"%@/%ld %@", e.domain, (long)e.code, e.localizedDescription] : @"none",
          YTRequestSummary(req));
}

static void YTLogPlayerItem(AVPlayerItem *item, NSString *tag, NSError *eventError) {
    if (!item) return;
    NSError *e = eventError ?: item.error;
    YTLog(@"PLAYER %@ item=%p status=%ld error=%@ duration=%.3f loadedRanges=%@",
          tag, item, (long)item.status,
          e ? [NSString stringWithFormat:@"%@/%ld %@ userInfo=%@", e.domain, (long)e.code, e.localizedDescription, e.userInfo ?: @{}] : @"none",
          CMTimeGetSeconds(item.duration), item.loadedTimeRanges ?: @[]);
    AVPlayerItemErrorLogEvent *ee = item.errorLog.events.lastObject;
    if (ee) {
        NSURL *uriURL = ee.URI.length ? [NSURL URLWithString:ee.URI] : nil;
        YTLog(@"AVERROR !!! status=%ld domain=%@ comment=%@ uri=%@ server=%@ session=%@",
              (long)ee.errorStatusCode, ee.errorDomain ?: @"", ee.errorComment ?: @"",
              uriURL ? YTSafeURL(uriURL) : @"", ee.serverAddress ?: @"", ee.playbackSessionID ?: @"");
    }
    AVPlayerItemAccessLogEvent *ae = item.accessLog.events.lastObject;
    if (ae) {
        NSURL *uriURL = ae.URI.length ? [NSURL URLWithString:ae.URI] : nil;
        YTLog(@"ACCESS uri=%@ server=%@ stalls=%ld mediaRequests=%ld indicated=%.0f observed=%.0f transfer=%.3f segments=%.3f",
              uriURL ? YTSafeURL(uriURL) : @"", ae.serverAddress ?: @"", (long)ae.numberOfStalls, (long)ae.numberOfMediaRequests,
              ae.indicatedBitrate, ae.observedBitrate, ae.transferDuration, ae.segmentsDownloadedDuration);
    }
}

static void YTAttemptStallRecovery(AVPlayerItem *item) {
    AVPlayer *player = item ? [YTPlayerByItem objectForKey:item] : nil;
    if (!player) { YTLog(@"RECOVERY skipped: no AVPlayer mapped for item=%p", item); return; }
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSNumber *last = [YTLastRecoveryByItem objectForKey:item];
    if (last && now - last.doubleValue < 8.0) { YTLog(@"RECOVERY skipped: cooldown item=%p", item); return; }
    [YTLastRecoveryByItem setObject:@(now) forKey:item];
    YTLog(@"RECOVERY scheduling one-shot play item=%p at %.3fs rate=%.2f", item, CMTimeGetSeconds(player.currentTime), player.rate);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.85 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        AVPlayer *p = [YTPlayerByItem objectForKey:item];
        if (!p || p.currentItem != item) return;
        if (item.status != AVPlayerItemStatusReadyToPlay) { YTLog(@"RECOVERY not applied: item status=%ld", (long)item.status); return; }
        [p play];
        YTLog(@"RECOVERY play issued at %.3fs; rate=%.2f", CMTimeGetSeconds(p.currentTime), p.rate);
    });
}

@interface YTPlaybackDiagObserver : NSObject @end
@implementation YTPlaybackDiagObserver
- (void)stalled:(NSNotification *)n { AVPlayerItem *i=n.object; YTLogPlayerItem(i,@"STALL",nil); YTAttemptStallRecovery(i); }
- (void)failed:(NSNotification *)n { YTLogPlayerItem(n.object,@"FAILED_TO_END",n.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey]); }
- (void)newError:(NSNotification *)n { YTLogPlayerItem(n.object,@"NEW_ERROR_LOG",nil); }
@end
static YTPlaybackDiagObserver *YTObserver;

static BOOL YTClassIsSubclassOf(Class cls, Class parent) {
    for (Class c=cls;c;c=class_getSuperclass(c)) if (c==parent) return YES;
    return NO;
}
static BOOL YTClassDirectlyImplements(Class cls, SEL sel) {
    unsigned int count=0; Method *methods=class_copyMethodList(cls,&count); BOOL found=NO;
    for (unsigned int i=0;i<count;i++) if (method_getName(methods[i])==sel) { found=YES; break; }
    free(methods); return found;
}
static BOOL YTMarkHooked(Class cls, SEL sel) {
    NSString *key=[NSString stringWithFormat:@"%s::%s",class_getName(cls),sel_getName(sel)];
    @synchronized (YTHookedMethods) {
        if ([YTHookedMethods containsObject:key]) return NO;
        [YTHookedMethods addObject:key]; return YES;
    }
}

static void YTHookTaskClass(Class cls) {
    SEL resumeSel=@selector(resume);
    if (YTClassDirectlyImplements(cls,resumeSel) && YTMarkHooked(cls,resumeSel)) {
        Method m=class_getInstanceMethod(cls,resumeSel); IMP old=method_getImplementation(m); const char *types=method_getTypeEncoding(m);
        IMP neu=imp_implementationWithBlock(^void(NSURLSessionTask *task) {
            NSURLRequest *r=task.currentRequest ?: task.originalRequest;
            if (YTInterestingURL(r.URL)) {
                YTLog(@"NET RESUME class=%s task=%lu | %@",class_getName([task class]),(unsigned long)task.taskIdentifier,YTRequestSummary(r));
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.75*NSEC_PER_SEC)),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{YTLogTaskSnapshot(task,@"+0.75s");});
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.0*NSEC_PER_SEC)),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{YTLogTaskSnapshot(task,@"+3s");});
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(10.0*NSEC_PER_SEC)),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{YTLogTaskSnapshot(task,@"+10s");});
            }
            ((void(*)(id,SEL))old)(task,resumeSel);
        });
        class_replaceMethod(cls,resumeSel,neu,types);
    }
    SEL cancelSel=@selector(cancel);
    if (YTClassDirectlyImplements(cls,cancelSel) && YTMarkHooked(cls,cancelSel)) {
        Method m=class_getInstanceMethod(cls,cancelSel); IMP old=method_getImplementation(m); const char *types=method_getTypeEncoding(m);
        IMP neu=imp_implementationWithBlock(^void(NSURLSessionTask *task) {
            NSURLRequest *r=task.currentRequest ?: task.originalRequest;
            if (YTInterestingURL(r.URL)) YTLogTaskSnapshot(task,@"CANCEL");
            ((void(*)(id,SEL))old)(task,cancelSel);
        });
        class_replaceMethod(cls,cancelSel,neu,types);
    }
}

static void YTHookSessionClass(Class cls) {
    SEL s1=@selector(dataTaskWithRequest:completionHandler:);
    if (YTClassDirectlyImplements(cls,s1) && YTMarkHooked(cls,s1)) {
        Method m=class_getInstanceMethod(cls,s1); IMP old=method_getImplementation(m); const char *types=method_getTypeEncoding(m);
        IMP neu=imp_implementationWithBlock(^NSURLSessionDataTask *(NSURLSession *session, NSURLRequest *request, void (^completion)(NSData *,NSURLResponse *,NSError *)) {
            if (!completion || !YTInterestingURL(request.URL)) return ((id(*)(id,SEL,id,id))old)(session,s1,request,completion);
            void (^wrapped)(NSData *,NSURLResponse *,NSError *)=^(NSData *data,NSURLResponse *response,NSError *error) {
                BOOL bad=([response isKindOfClass:[NSHTTPURLResponse class]] && ((NSHTTPURLResponse *)response).statusCode>=400) || error;
                YTLog(@"NET COMPLETE%@ %@ bytes=%lu error=%@ | %@",bad?@" !!!":@"",YTResponseSummary(response),(unsigned long)data.length,
                      error?[NSString stringWithFormat:@"%@/%ld %@",error.domain,(long)error.code,error.localizedDescription]:@"none",YTRequestSummary(request));
                completion(data,response,error);
            };
            return ((id(*)(id,SEL,id,id))old)(session,s1,request,wrapped);
        });
        class_replaceMethod(cls,s1,neu,types);
    }
    SEL s2=@selector(dataTaskWithURL:completionHandler:);
    if (YTClassDirectlyImplements(cls,s2) && YTMarkHooked(cls,s2)) {
        Method m=class_getInstanceMethod(cls,s2); IMP old=method_getImplementation(m); const char *types=method_getTypeEncoding(m);
        IMP neu=imp_implementationWithBlock(^NSURLSessionDataTask *(NSURLSession *session, NSURL *url, void (^completion)(NSData *,NSURLResponse *,NSError *)) {
            if (!completion || !YTInterestingURL(url)) return ((id(*)(id,SEL,id,id))old)(session,s2,url,completion);
            void (^wrapped)(NSData *,NSURLResponse *,NSError *)=^(NSData *data,NSURLResponse *response,NSError *error) {
                BOOL bad=([response isKindOfClass:[NSHTTPURLResponse class]] && ((NSHTTPURLResponse *)response).statusCode>=400) || error;
                YTLog(@"NET COMPLETE%@ %@ bytes=%lu error=%@ | GET %@",bad?@" !!!":@"",YTResponseSummary(response),(unsigned long)data.length,
                      error?[NSString stringWithFormat:@"%@/%ld %@",error.domain,(long)error.code,error.localizedDescription]:@"none",YTSafeURL(url));
                completion(data,response,error);
            };
            return ((id(*)(id,SEL,id,id))old)(session,s2,url,wrapped);
        });
        class_replaceMethod(cls,s2,neu,types);
    }
}

static void YTHookAVPlayer(void) {
    Class cls=[AVPlayer class];
    SEL s1=@selector(initWithPlayerItem:);
    if (YTClassDirectlyImplements(cls,s1) && YTMarkHooked(cls,s1)) {
        Method m=class_getInstanceMethod(cls,s1); IMP old=method_getImplementation(m); const char *types=method_getTypeEncoding(m);
        IMP neu=imp_implementationWithBlock(^id(AVPlayer *selfObj,AVPlayerItem *item) {
            AVPlayer *p=((id(*)(id,SEL,id))old)(selfObj,s1,item);
            if (p && item) { [YTPlayerByItem setObject:p forKey:item]; YTLog(@"PLAYER MAP init player=%p item=%p",p,item); }
            return p;
        });
        class_replaceMethod(cls,s1,neu,types);
    }
    SEL s2=@selector(replaceCurrentItemWithPlayerItem:);
    if (YTClassDirectlyImplements(cls,s2) && YTMarkHooked(cls,s2)) {
        Method m=class_getInstanceMethod(cls,s2); IMP old=method_getImplementation(m); const char *types=method_getTypeEncoding(m);
        IMP neu=imp_implementationWithBlock(^void(AVPlayer *p,AVPlayerItem *item) {
            ((void(*)(id,SEL,id))old)(p,s2,item);
            if (item) { [YTPlayerByItem setObject:p forKey:item]; YTLog(@"PLAYER MAP replace player=%p item=%p",p,item); }
        });
        class_replaceMethod(cls,s2,neu,types);
    }
}

static void YTInstallNetworkHooks(void) {
    int count=objc_getClassList(NULL,0); if (count<=0) return;
    Class *classes=(__unsafe_unretained Class *)malloc(sizeof(Class)*(unsigned)count);
    count=objc_getClassList(classes,count);
    Class taskBase=[NSURLSessionTask class], sessionBase=[NSURLSession class];
    for (int i=0;i<count;i++) {
        Class cls=classes[i];
        if (YTClassIsSubclassOf(cls,taskBase)) YTHookTaskClass(cls);
        if (YTClassIsSubclassOf(cls,sessionBase)) YTHookSessionClass(cls);
    }
    free(classes);
}

__attribute__((constructor)) static void YTInit(void) {
    @autoreleasepool {
        NSString *bid=NSBundle.mainBundle.bundleIdentifier ?: @"";
        if (![bid isEqualToString:@"com.google.ios.youtube"]) return;
        YTHookedMethods=[NSMutableSet new];
        YTPlayerByItem=[NSMapTable weakToWeakObjectsMapTable];
        YTLastRecoveryByItem=[NSMapTable weakToStrongObjectsMapTable];
        YTObserver=[YTPlaybackDiagObserver new];
        NSNotificationCenter *nc=NSNotificationCenter.defaultCenter;
        [nc addObserver:YTObserver selector:@selector(stalled:) name:AVPlayerItemPlaybackStalledNotification object:nil];
        [nc addObserver:YTObserver selector:@selector(failed:) name:AVPlayerItemFailedToPlayToEndTimeNotification object:nil];
        [nc addObserver:YTObserver selector:@selector(newError:) name:AVPlayerItemNewErrorLogEntryNotification object:nil];
        YTHookAVPlayer();
        YTInstallNetworkHooks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{YTInstallNetworkHooks();});
        YTEnsureLogFile();
        NSString *ver=[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
        NSString *build=[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?";
        UIDevice *d=UIDevice.currentDevice;
        YTLog(@"===== START v0.1.1 | YouTube %@ (%@) | iOS %@ | model %@ =====",ver,build,d.systemVersion,d.model);
    }
}
