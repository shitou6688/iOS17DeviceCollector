/*
 * iOS17DeviceCollector.m - 巨魔注入插件
 * 策略: 遍历所有子类hook NSURLSession + WKWebView JS扫描
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

#define CONFIG_URL  @"http://124.221.171.80/chaxun/getConfig.php"
#define UPLOAD_URL  @"http://124.221.171.80/chaxun/collect.php"

#pragma mark - 阈值模型

@interface Threshold : NSObject
@property BOOL enabled;
@property (copy) NSString *op, *ver;
- (BOOL)matchVersion:(NSString *)v;
@end

@implementation Threshold
- (BOOL)matchVersion:(NSString *)v {
    if (!_enabled || !v.length) return NO;
    NSArray *a = [v componentsSeparatedByString:@"."];
    NSArray *b = [_ver componentsSeparatedByString:@"."];
    NSInteger n = MAX(a.count, b.count);
    for (NSInteger i = 0; i < n; i++) {
        NSInteger ai = (i < a.count) ? [a[i] integerValue] : 0;
        NSInteger bi = (i < b.count) ? [b[i] integerValue] : 0;
        if ([_op isEqualToString:@"lt"]) return ai < bi;
        if ([_op isEqualToString:@"gt"]) return ai > bi;
        if (ai != bi) return NO;
    }
    return [_op isEqualToString:@"eq"];
}
@end

#pragma mark - 配置

@interface CollectorConfig : NSObject
@property (copy) NSArray<Threshold *> *thresholds;
+ (instancetype)shared;
- (void)fetchFromServer;
- (BOOL)shouldCapture:(NSString *)ver;
@end

@implementation CollectorConfig
+ (instancetype)shared { static id s; static dispatch_once_t t; dispatch_once(&t,^{s=[self new];}); return s; }

- (instancetype)init {
    if (self = [super init]) {
        Threshold *t1 = [Threshold new]; t1.op = @"lt"; t1.ver = @"17.0"; t1.enabled = YES;
        Threshold *t2 = [Threshold new]; t2.op = @"eq"; t2.ver = @"17.0"; t2.enabled = YES;
        Threshold *t3 = [Threshold new]; t3.op = @"gt"; t3.ver = @"17.0"; t3.enabled = NO;
        _thresholds = @[t1, t2, t3];
    }
    return self;
}

- (void)fetchFromServer {
    NSURL *url = [NSURL URLWithString:CONFIG_URL];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url cachePolicy:1 timeoutInterval:10];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (!d || e) return;
        NSDictionary *cfg = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (!cfg) return;
        NSDictionary *ts = cfg[@"thresholds"];
        if (![ts isKindOfClass:[NSDictionary class]]) return;
        NSMutableArray *arr = [NSMutableArray array];
        for (NSString *op in @[@"lt",@"eq",@"gt"]) {
            NSDictionary *item = ts[op];
            if ([item isKindOfClass:[NSDictionary class]]) {
                Threshold *t = [Threshold new]; t.op = op;
                t.ver = item[@"version"] ?: @"17.0";
                t.enabled = [item[@"enabled"] boolValue];
                [arr addObject:t];
            }
        }
        if (arr.count == 3) self.thresholds = arr;
    }] resume];
}

- (BOOL)shouldCapture:(NSString *)ver {
    if (!ver.length) return NO;
    for (Threshold *t in self.thresholds) if ([t matchVersion:ver]) return YES;
    return NO;
}
@end

#pragma mark - 上传器

@interface Uploader : NSObject
+ (instancetype)shared;
- (void)upload:(NSDictionary *)info;
@end

@implementation Uploader { NSMutableSet *_dedup; }
+ (instancetype)shared { static id s; static dispatch_once_t t; dispatch_once(&t,^{s=[self new];}); return s; }
- (instancetype)init { if(self=[super init])_dedup=[NSMutableSet set]; return self; }

- (void)upload:(NSDictionary *)info {
    NSString *fp = [NSString stringWithFormat:@"%@|%@", info[@"title"]?:@"", info[@"url"]?:@""];
    @synchronized(_dedup) { if([_dedup containsObject:fp])return; if(_dedup.count>500)[_dedup removeAllObjects]; [_dedup addObject:fp]; }
    NSData *body = [NSJSONSerialization dataWithJSONObject:info options:0 error:nil];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:UPLOAD_URL]];
    req.HTTPMethod = @"POST"; req.HTTPBody = body; req.timeoutInterval = 10;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d,NSURLResponse *r,NSError *e){
        if(!e) NSLog(@"[iOS17Col] upload OK: %@", info[@"title"]);
    }] resume];
}
@end

#pragma mark - 辅助函数

static BOOL _isValidIOSVersion(NSString *ver) {
    if (!ver.length) return NO;
    NSArray *p = [ver componentsSeparatedByString:@"."];
    if (p.count < 2) return NO;
    NSInteger major = [p[0] integerValue];
    return major >= 14 && major <= 20;
}

static BOOL _isListingURL(NSString *url) {
    NSArray *keys = @[@"search",@"list",@"feed",@"flow",@"transfer",@"appraisal",
                      @"product",@"goods",@"item",@"getfeed",@"info",@"spu",
                      @"recommend",@"category",@"home",@"channel",@"page"];
    for (NSString *k in keys)
        if ([url rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    return NO;
}

static BOOL _respHasDeviceKeywords(NSData *d) {
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!s) return NO;
    return [s rangeOfString:@"iPhone" options:NSCaseInsensitiveSearch].location != NSNotFound
        || [s rangeOfString:@"iPad" options:NSCaseInsensitiveSearch].location != NSNotFound
        || [s rangeOfString:@"iOS" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static void _parseAndUpload(NSData *d, NSString *url) {
    @try {
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        NSArray *infos = j[@"respData"][@"infos"] ?: j[@"data"][@"list"] ?: j[@"data"][@"infos"]
                      ?: j[@"data"][@"items"] ?: j[@"data"][@"products"] ?: j[@"data"][@"resultList"]
                      ?: j[@"data"] ?: j[@"list"] ?: j[@"infos"];
        if (![infos isKindOfClass:[NSArray class]]) return;

        NSDateFormatter *df = [NSDateFormatter new]; df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        NSString *source = [bid containsString:@"zhuanzhuan"] ? @"转转" : @"爱回收";

        for (NSDictionary *info in infos) {
            NSString *title = info[@"title"] ?: info[@"infoDesc"] ?: info[@"name"] ?: @"";
            if (title.length < 3) continue;

            // 整条 JSON 转字符串搜版本号
            NSData *jd = [NSJSONSerialization dataWithJSONObject:info options:0 error:nil];
            NSString *js = [[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding];

            NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
                @"(?:iOS|ios|系统版本|操作系统|systemVersion|osVersion)\\D*(\\d{1,2}\\.\\d{1,2}(?:\\.\\d{1,2})?)"
                options:NSRegularExpressionCaseInsensitive error:nil];
            NSArray *matches = [re matchesInString:js options:0 range:NSMakeRange(0, js.length)];
            NSMutableSet *vers = [NSMutableSet set];
            for (NSTextCheckingResult *m in matches) {
                NSString *v = [js substringWithRange:[m rangeAtIndex:1]];
                if (v && _isValidIOSVersion(v)) [vers addObject:v];
            }

            NSDictionary *pi = info[@"priceInfo"];
            NSString *price = pi[@"priceText"] ?: [NSString stringWithFormat:@"%@", pi[@"value"]];
            if (!price.length) price = info[@"price"] ?: info[@"priceText"] ?: @"";

            if (vers.count > 0) {
                for (NSString *ver in vers) {
                    if (![[CollectorConfig shared] shouldCapture:ver]) continue;
                    [[Uploader shared] upload:@{
                        @"title": title, @"price": price?:@"", @"ios_ver": ver,
                        @"url": info[@"jumpUrl"]?:url,
                        @"info_id": [info[@"infoId"] description]?:@"",
                        @"time": [df stringFromDate:[NSDate date]],
                        @"source": source, @"context": @"api_intercept"
                    }];
                }
            } else if ([title.lowercaseString hasPrefix:@"iphone"] || [title.lowercaseString hasPrefix:@"ipad"]) {
                // 列表项无版本号 — 上传列表数据供服务端处理
                NSString *jumpUrl = info[@"jumpUrl"] ?: info[@"jump_url"] ?: info[@"detailUrl"] ?: info[@"url"];
                NSString *infoId = [info[@"infoId"] ?: info[@"strInfoId"] ?: info[@"id"] description];
                [[Uploader shared] upload:@{
                    @"title": title, @"price": price?:@"", @"ios_ver": @"?",
                    @"url": jumpUrl?:url, @"info_id": infoId?:@"",
                    @"time": [df stringFromDate:[NSDate date]],
                    @"source": source, @"context": @"pending_detail"
                }];
            }
        }
    } @catch (NSException *e) {}
}

#pragma mark - JS注入 (扫描当前页面iOS版本)

static NSString *kScanJS =
    @"(function(){if(window.__i17c)return;window.__i17c=1;"
    @"var sent=new Set();function scan(){try{"
    @"var t=document.body?document.body.innerText:'';if(!t)return;"
    @"var re=/(?:iOS|ios|系统版本|操作系统)\\s*(\\d{1,2}\\.\\d{1,2}(?:\\.\\d{1,2})?)/gi;"
    @"var m,vs=[];while(m=re.exec(t)){var v=m[1];if(parseInt(v)>=14&&parseInt(v)<=20&&vs.indexOf(v)<0)vs.push(v);}"
    @"if(!vs.length)return;"
    @"var fp=vs.join(',')+t.substring(0,50);if(sent.has(fp))return;sent.add(fp);"
    @"var pm=t.match(/[¥￥]\\s*([\\d,]+)/);var price=pm?pm[1]:'';"
    @"var im=t.match(/(iPhone\\s*\\d+\\s*(Pro|Max|Plus|mini)?\\s*(Max)?)/i);"
    @"var title=im?im[1]:(document.title||'');"
    @"if(!im&&document.title){var dm=document.title.match(/(iPhone\\s*\\d+\\s*(Pro|Max|Plus|mini)?)/i);if(dm)title=dm[1];}"
    @"var iid='';var um=location.href.match(/infoId=(\\d+)/);if(um)iid=um[1];"
    @"window.webkit.messageHandlers.i17c.postMessage({"
    @"t:'scan',u:location.href,title:title,price:price,iid:iid,versions:vs,"
    @"ctx:t.substring(Math.max(0,re.lastIndex-150),re.lastIndex+150)});"
    @"}catch(e){}}"
    @"setInterval(scan,3000);scan();"
    @"new MutationObserver(function(){setTimeout(scan,800);})"
    @".observe(document.body||document.documentElement,{childList:1,subtree:1,characterData:1});"
    @"})();";

#pragma mark - WKWebView消息处理

@interface MsgHandler : NSObject <WKScriptMessageHandler>
- (void)ensureJS:(WKUserContentController *)ctl;
@end

@implementation MsgHandler

- (void)userContentController:(WKUserContentController *)ctl didReceiveScriptMessage:(WKScriptMessage *)msg {
    if (![msg.body isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *b = msg.body;
    NSArray *versions = b[@"versions"];
    if (![versions isKindOfClass:[NSArray class]] || !versions.count) return;
    [self ensureJS:ctl];

    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    df.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];

    for (NSString *ver in versions) {
        if (!_isValidIOSVersion(ver)) continue;
        if (![[CollectorConfig shared] shouldCapture:ver]) continue;
        [[Uploader shared] upload:@{
            @"title": b[@"title"]?:@"未知", @"price": b[@"price"]?:@"",
            @"ios_ver": ver, @"url": b[@"u"]?:@"", @"info_id": b[@"iid"]?:@"",
            @"time": [df stringFromDate:[NSDate date]],
            @"source": [bid containsString:@"zhuanzhuan"]?@"转转":@"爱回收",
            @"context": b[@"ctx"]?:@"", @"threshold_op": @"-"
        }];
    }
}

- (void)ensureJS:(WKUserContentController *)ctl {
    static NSMutableSet *done; static dispatch_once_t t; dispatch_once(&t,^{done=[NSMutableSet set];});
    NSValue *k = [NSValue valueWithNonretainedObject:ctl];
    @synchronized(done){ if([done containsObject:k])return; [done addObject:k]; }
    [ctl addScriptMessageHandler:self name:@"i17c"];
    [ctl addUserScript:[[WKUserScript alloc] initWithSource:kScanJS
        injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES]];
}
@end

#pragma mark - KVO方式NSURLSession拦截(兼容类簇)

static MsgHandler *gHandler;

// Hook WKUserContentController
static IMP _orig_addSMH;
static void _hook_addSMH(id self, SEL _cmd, id<WKScriptMessageHandler> h, NSString *n) {
    if(!gHandler){gHandler=[MsgHandler new];[gHandler ensureJS:self];}
    if(_orig_addSMH)((void(*)(id,SEL,id,NSString*))_orig_addSMH)(self,_cmd,h,n);
}
static IMP _orig_addUS;
static void _hook_addUS(id self, SEL _cmd, WKUserScript *s){
    if(gHandler)[gHandler ensureJS:self];
    if(_orig_addUS)((void(*)(id,SEL,WKUserScript*))_orig_addUS)(self,_cmd,s);
}

// ====== NSURLSession拦截 (NSMapTable存每class的原始IMP) ======

static NSMapTable *_origMap; // key=Class, value=IMP

static id _hook_dtwr(id self, SEL _cmd, NSURLRequest *req, void(^h)(NSData*,NSURLResponse*,NSError*)) {
    IMP orig = (__bridge IMP)NSMapGet(_origMap, (__bridge void *)[self class]);
    if (!orig) return nil;
    NSString *url = req.URL.absoluteString;
    if (_isListingURL(url)) {
        id(^wrap)(NSData*,NSURLResponse*,NSError*) = ^(NSData *d, NSURLResponse *r, NSError *e) {
            if (d && !e && _respHasDeviceKeywords(d)) _parseAndUpload(d, url);
            if (h) h(d, r, e);
            return (id)nil;
        };
        return ((id(*)(id,SEL,id,id))orig)(self, _cmd, req, [wrap copy]);
    }
    return ((id(*)(id,SEL,id,id))orig)(self, _cmd, req, h);
}

static id _hook_dtwu(id self, SEL _cmd, NSURL *url, void(^h)(NSData*,NSURLResponse*,NSError*)) {
    IMP orig = (__bridge IMP)NSMapGet(_origMap, (__bridge void *)[self class]);
    if (!orig) return nil;
    NSString *urlStr = url.absoluteString;
    if (_isListingURL(urlStr)) {
        id(^wrap)(NSData*,NSURLResponse*,NSError*) = ^(NSData *d, NSURLResponse *r, NSError *e) {
            if (d && !e && _respHasDeviceKeywords(d)) _parseAndUpload(d, urlStr);
            if (h) h(d, r, e);
            return (id)nil;
        };
        return ((id(*)(id,SEL,id,id))orig)(self, _cmd, url, [wrap copy]);
    }
    return ((id(*)(id,SEL,id,id))orig)(self, _cmd, url, h);
}

static void _hookSessionClass(Class cls) {
    Method m1 = class_getInstanceMethod(cls, @selector(dataTaskWithRequest:completionHandler:));
    Method m2 = class_getInstanceMethod(cls, @selector(dataTaskWithURL:completionHandler:));
    if (m1) {
        IMP orig = method_getImplementation(m1);
        if (orig != (IMP)_hook_dtwr) {
            NSMapInsert(_origMap, (__bridge void *)cls, (__bridge void *)orig);
            method_setImplementation(m1, (IMP)_hook_dtwr);
        }
    }
    if (m2) {
        IMP orig = method_getImplementation(m2);
        if (orig != (IMP)_hook_dtwu) {
            NSMapInsert(_origMap, (__bridge void *)cls, (__bridge void *)orig);
            method_setImplementation(m2, (IMP)_hook_dtwu);
        }
    }
}

static void _hookAllSessions(void) {
    _origMap = NSCreateMapTable(NSPointerFunctionsOpaqueMemory, NSPointerFunctionsOpaqueMemory, 16);
    unsigned int count;
    Class *classes = objc_copyClassList(&count);
    Class nsurlsession = objc_getClass("NSURLSession");
    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        if (cls != nsurlsession && !class_respondsToSelector(cls, @selector(dataTaskWithRequest:completionHandler:))) continue;
        NSString *name = NSStringFromClass(cls);
        BOOL match = (cls == nsurlsession) || [name hasPrefix:@"__NSCFURL"] || [name hasSuffix:@"URLSession"];
        if (!match) continue;
        _hookSessionClass(cls);
        NSLog(@"[iOS17Col] hooked: %@", name);
    }
    free(classes);
}

#pragma mark - 入口

__attribute__((constructor))
static void _init(void) {
    @autoreleasepool {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            NSLog(@"[iOS17Col] loaded");
            [[CollectorConfig shared] fetchFromServer];

            // WKWebView hooks
            Class c = NSClassFromString(@"WKUserContentController");
            if (c) {
                Method m = class_getInstanceMethod(c, @selector(addScriptMessageHandler:name:));
                if (m) { _orig_addSMH = method_getImplementation(m); method_setImplementation(m, (IMP)_hook_addSMH); }
                m = class_getInstanceMethod(c, @selector(addUserScript:));
                if (m) { _orig_addUS = method_getImplementation(m); method_setImplementation(m, (IMP)_hook_addUS); }
            }

            // 遍历所有NSURLSession子类hook
            _hookAllSessions();

            NSLog(@"[iOS17Col] hooks done");
        });
    }
}
