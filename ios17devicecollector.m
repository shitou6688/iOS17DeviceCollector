/*
 * iOS17DeviceCollector.m - 巨魔注入插件
 * 三阈值采集: <X.X  =X.X  >X.X，从服务器动态读取配置
 * 注入到转转/爱回收，WebView JS扫描 + API拦截双重采集
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

// ================= 默认配置 (会被服务器覆盖) =================
#define CONFIG_URL  @"http://124.221.171.80/chaxun/getConfig.php"
#define UPLOAD_URL  @"http://124.221.171.80/chaxun/collect.php"
// ===========================================================

#pragma mark - 阈值模型

@interface Threshold : NSObject
@property BOOL enabled;
@property (copy) NSString *op;   // "lt" "eq" "gt"
@property (copy) NSString *ver;  // "17.0"
- (BOOL)matchVersion:(NSString *)version;
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

#pragma mark - 全局配置

@interface CollectorConfig : NSObject
@property (copy) NSArray<Threshold *> *thresholds;
+ (instancetype)shared;
- (void)fetchFromServer;
- (BOOL)shouldCapture:(NSString *)iosVersion;
@end

@implementation CollectorConfig

+ (instancetype)shared { static id s; static dispatch_once_t t; dispatch_once(&t,^{s=[self new];}); return s; }

- (instancetype)init {
    if (self = [super init]) {
        // 默认阈值
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
                Threshold *t = [Threshold new];
                t.op = op;
                t.ver = item[@"version"] ?: @"17.0";
                t.enabled = [item[@"enabled"] boolValue];
                [arr addObject:t];
            }
        }
        if (arr.count == 3) {
            self.thresholds = arr;
            NSLog(@"[iOS17Col] 配置已更新: lt=%@(%@) eq=%@(%@) gt=%@(%@)",
                  ((Threshold *)arr[0]).ver, ((Threshold *)arr[0]).enabled?@"ON":@"OFF",
                  ((Threshold *)arr[1]).ver, ((Threshold *)arr[1]).enabled?@"ON":@"OFF",
                  ((Threshold *)arr[2]).ver, ((Threshold *)arr[2]).enabled?@"ON":@"OFF");
        }
    }] resume];
}

- (BOOL)shouldCapture:(NSString *)ver {
    if (!ver.length) return NO;
    for (Threshold *t in self.thresholds) {
        if ([t matchVersion:ver]) return YES;
    }
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
        if(!e) NSLog(@"[iOS17Col] ✅ 上传: %@", info[@"title"]);
        else NSLog(@"[iOS17Col] ❌ 上传失败");
    }] resume];
}
@end

#pragma mark - JS 注入

// 增强版 JS - 提取所有 iOS 版本号并回传
static NSString *kScanJS =
    @"(function(){"
    @" if(window.__i17c)return;window.__i17c=1;"
    @" var sent=new Set();"
    @" function scan(){"
    @"  try{"
    @"   var t=document.body.innerText||'';"
    @"   if(!/iOS|ios/.test(t))return;"
    // 提取所有 iOS 版本号
    @"   var re=/(?:iOS|ios|系统|版本)\\s*(\\d{1,2}\\.\\d{1,2}(?:\\.\\d{1,2})?)/gi;"
    @"   var m,versions=[];"
    @"   while(m=re.exec(t)){"
    @"    var ver=m[1];"
    @"    if(versions.indexOf(ver)<0)versions.push(ver);"
    @"   }"
    @"   if(!versions.length)return;"
    @"   var fp=versions.join(',')+t.substring(0,50);"
    @"   if(sent.has(fp))return;sent.add(fp);"
    // 提取价格
    @"   var pm=t.match(/[¥￥]\\s*([\\d,]+)/);"
    @"   var price=pm?pm[1]:'';"
    // 提取机型
    @"   var im=t.match(/(iPhone\\s*\\d+\\s*(Pro|Max|Plus|mini)?\\s*(Max)?)/i);"
    @"   var title=im?im[1]:(document.title||'');"
    @"   if(!im&&document.title){"
    @"     var dm=document.title.match(/(iPhone\\s*\\d+\\s*(Pro|Max|Plus|mini)?)/i);"
    @"     if(dm)title=dm[1];"
    @"   }"
    // 提取 infoId
    @"   var iid='';"
    @"   var um=location.href.match(/infoId=(\\d+)/);"
    @"   if(um)iid=um[1];"
    @"   window.webkit.messageHandlers.i17c.postMessage({"
    @"    t:'scan',u:location.href,title:title,price:price,iid:iid,versions:versions,"
    @"    ctx:t.substring(Math.max(0,re.lastIndex-150),re.lastIndex+150)"
    @"   });"
    @"  }catch(e){}"
    @" }"
    @" setInterval(scan,3000);scan();"
    @" new MutationObserver(function(){setTimeout(scan,800);}).observe(document.body||document.documentElement,{childList:1,subtree:1,characterData:1});"
    @"})();";


#pragma mark - 消息处理器

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

    for (NSString *ver in versions) {
        if (![[CollectorConfig shared] shouldCapture:ver]) continue;

        NSDateFormatter *df = [NSDateFormatter new];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        df.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];

        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        NSDictionary *info = @{
            @"title": b[@"title"]?:@"未知", @"price":b[@"price"]?:@"",
            @"ios_ver": ver, @"url":b[@"u"]?:@"",
            @"info_id":b[@"iid"]?:@"", @"context":b[@"ctx"]?:@"",
            @"time":[df stringFromDate:[NSDate date]],
            @"source":[bid containsString:@"zhuanzhuan"]?@"转转":@"爱回收",
            @"threshold_op": @"-"  // filled in by server
        };
        [[Uploader shared] upload:info];
    }
}

- (void)ensureJS:(WKUserContentController *)ctl {
    static NSMutableSet *done; static dispatch_once_t t; dispatch_once(&t,^{done=[NSMutableSet set];});
    NSValue *k = [NSValue valueWithNonretainedObject:ctl];
    @synchronized(done){ if([done containsObject:k])return; [done addObject:k]; }
    [ctl addScriptMessageHandler:self name:@"i17c"];
    [ctl addUserScript:[[WKUserScript alloc] initWithSource:kScanJS injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES]];
}
@end


#pragma mark - Hooks

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

// Hook NSURLSession - dataTaskWithRequest 和 dataTaskWithURL 双钩
@interface NSObject (I17C)
- (void)_parseAPI:(NSData *)d url:(NSString *)u;
- (void)_autoFetchDetail:(NSString *)jumpUrl title:(NSString *)title price:(NSString *)price infoId:(NSString *)infoId bid:(NSString *)bid;
- (void)_tryFetchDetailAPI:(NSString *)infoId title:(NSString *)title price:(NSString *)price bid:(NSString *)bid jumpUrl:(NSString *)jumpUrl retry:(int)retry;
- (void)_fetchDetailHTML:(NSString *)jumpUrl title:(NSString *)title price:(NSString *)price infoId:(NSString *)infoId bid:(NSString *)bid;
@end

// URL 关键词匹配：是否可能是商品列表/搜索 API
static BOOL _isListingAPI(NSString *u) {
    NSArray *keys = @[@"search",@"list",@"feed",@"flow",@"transfer",@"appraisal",
                      @"product",@"goods",@"item",@"getfeed",@"info",@"spu",
                      @"recommend",@"category",@"home",@"channel",@"page"];
    for (NSString *k in keys) {
        if ([u rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

// 响应内容关键词匹配
static BOOL _hasDeviceKeywords(NSData *d) {
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!s) return NO;
    return [s rangeOfString:@"iPhone" options:NSCaseInsensitiveSearch].location != NSNotFound
        || [s rangeOfString:@"iPad" options:NSCaseInsensitiveSearch].location != NSNotFound
        || [s rangeOfString:@"iOS" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static IMP _orig_dtwr;
static id _hook_dtwr(id self, SEL _cmd, NSURLRequest *req, void(^h)(NSData*,NSURLResponse*,NSError*)) {
    NSString *u = req.URL.absoluteString;
    if (!_isListingAPI(u)) return ((id(*)(id,SEL,id,id))_orig_dtwr)(self,_cmd,req,h);
    id(^wrap)(NSData*,NSURLResponse*,NSError*) = ^(NSData *d,NSURLResponse *r,NSError *e){
        if(d&&!e&&_hasDeviceKeywords(d)) [(NSObject*)self _parseAPI:d url:u];
        if(h)h(d,r,e);
        return (id)nil;
    };
    return ((id(*)(id,SEL,id,id))_orig_dtwr)(self,_cmd,req,[wrap copy]);
}

static IMP _orig_dtwu;
static id _hook_dtwu(id self, SEL _cmd, NSURL *url, void(^h)(NSData*,NSURLResponse*,NSError*)) {
    NSString *u = url.absoluteString;
    if (!_isListingAPI(u)) return ((id(*)(id,SEL,id,id))_orig_dtwu)(self,_cmd,url,h);
    id(^wrap)(NSData*,NSURLResponse*,NSError*) = ^(NSData *d,NSURLResponse *r,NSError *e){
        if(d&&!e&&_hasDeviceKeywords(d)) [(NSObject*)self _parseAPI:d url:u];
        if(h)h(d,r,e);
        return (id)nil;
    };
    return ((id(*)(id,SEL,id,id))_orig_dtwu)(self,_cmd,url,[wrap copy]);
}

@implementation NSObject (I17C)
- (void)_parseAPI:(NSData *)d url:(NSString *)u {
    @try {
        NSDictionary *j=[NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        // 扩展 JSON 路径匹配
        NSArray *infos=j[@"respData"][@"infos"]
                  ?:j[@"data"][@"list"]
                  ?:j[@"data"][@"infos"]
                  ?:j[@"data"][@"items"]
                  ?:j[@"data"][@"products"]
                  ?:j[@"data"][@"resultList"]
                  ?:j[@"data"][@"productList"]
                  ?:j[@"data"][@"recordList"]
                  ?:j[@"data"][@"spuInfos"]
                  ?:j[@"result"][@"data"]
                  ?:j[@"result"][@"list"]
                  ?:j[@"list"]
                  ?:j[@"infos"]
                  ?:j[@"data"];  // data 本身可能是数组
        if(![infos isKindOfClass:[NSArray class]])return;
        NSDateFormatter *df=[NSDateFormatter new];df.dateFormat=@"yyyy-MM-dd HH:mm:ss";
        NSString *bid=[[NSBundle mainBundle] bundleIdentifier];
        for(NSDictionary *info in infos){
            NSString *title=info[@"title"]?:info[@"infoDesc"]?:info[@"name"]?:info[@"productName"]?:info[@"goodsName"]?:@"";
            if(title.length<3)continue;
            // 把整个 info JSON 转字符串，搜索 iOS 版本
            NSData *jd=[NSJSONSerialization dataWithJSONObject:info options:0 error:nil];
            NSString *js=[[NSString alloc] initWithData:jd encoding:4];
            // 正则提取 iOS 版本号
            NSRegularExpression *re=[NSRegularExpression regularExpressionWithPattern:@"(?:iOS|ios|系统|版本)\\s*(\\d{1,2}\\.\\d{1,2}(?:\\.\\d{1,2})?)" options:0 error:nil];
            NSArray *matches=[re matchesInString:js options:0 range:NSMakeRange(0,js.length)];
            NSMutableSet *versions=[NSMutableSet set];
            for(NSTextCheckingResult *m in matches){
                NSString *v=[js substringWithRange:[m rangeAtIndex:1]];
                if(v) [versions addObject:v];
            }
                NSDictionary *pi=info[@"priceInfo"];
                NSString *price=pi[@"priceText"]?:[NSString stringWithFormat:@"%@",pi[@"value"]];
                if(!price.length) price=info[@"price"]?:info[@"priceText"]?:info[@"productPrice"]?:@"";
                if(versions.count>0){
                    for(NSString *ver in versions){
                        if(![[CollectorConfig shared] shouldCapture:ver])continue;
                        [[Uploader shared] upload:@{
                            @"title":title,@"price":price?:@"",
                            @"ios_ver":ver,@"url":info[@"jumpUrl"]?:u,
                            @"info_id":[info[@"infoId"]?:info[@"strInfoId"] description]?:@"",
                            @"time":[df stringFromDate:[NSDate date]],
                            @"source":[bid containsString:@"zhuanzhuan"]?@"转转":@"爱回收",
                            @"context":[js substringWithRange:NSMakeRange(MAX(0,(NSInteger)[[matches firstObject] range].location-30), MIN(120,js.length))]
                        }];
                    }
                } else if([title.lowercaseString hasPrefix:@"iphone"]||[title.lowercaseString hasPrefix:@"ipad"]){
                    // 没找到 iOS 版本 → 上传列表数据，服务端后续处理详情页
                    NSString *jumpUrl=info[@"jumpUrl"]?:info[@"jump_url"]?:info[@"detailUrl"]?:info[@"url"]?:info[@"link"];
                    NSString *infoId=[info[@"infoId"]?:info[@"strInfoId"]?:info[@"id"]?:info[@"spuId"]?:info[@"productId"]?:info[@"goodsId"] description];
                    [[Uploader shared] upload:@{
                        @"title":title, @"price":price?:@"",
                        @"ios_ver":@"?",
                        @"url":jumpUrl?:u, @"info_id":infoId?:@"",
                        @"time":[df stringFromDate:[NSDate date]],
                        @"source":[bid containsString:@"zhuanzhuan"]?@"转转":@"爱回收",
                        @"context":@"pending_detail"
                    }];
                }
        }
    }@catch(NSException *e){}
}

// 自动拉取详情页，提取 iOS 版本
// 限速: 1秒1个，排队延迟执行（不丢弃）
- (void)_autoFetchDetail:(NSString *)jumpUrl title:(NSString *)title price:(NSString *)price infoId:(NSString *)infoId bid:(NSString *)bid {
    static NSMutableSet *fetched;
    static dispatch_once_t t; dispatch_once(&t,^{fetched=[NSMutableSet set];});
    @synchronized(fetched){ if([fetched containsObject:infoId]||fetched.count>200)return; [fetched addObject:infoId]; }
    static NSTimeInterval nextFetchTime;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (nextFetchTime < now) nextFetchTime = now;
    NSTimeInterval delay = nextFetchTime - now;
    nextFetchTime += 1.0;
    
    NSString *yyBid = bid;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 策略1: 先尝试详情API (转转 POST transfer/getitemdetail)
        [self _tryFetchDetailAPI:infoId title:title price:price bid:yyBid jumpUrl:jumpUrl retry:0];
    });
}

// 递归尝试不同API端点获取详情
- (void)_tryFetchDetailAPI:(NSString *)infoId title:(NSString *)title price:(NSString *)price bid:(NSString *)bid jumpUrl:(NSString *)jumpUrl retry:(int)retry {
    NSString *body = [NSString stringWithFormat:@"infoId=%@&needVideo=0", infoId];
    NSMutableURLRequest *req;
    if (retry == 0) {
        // 转转: POST transfer/getitemdetail
        req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://app.zhuanzhuan.com/zz/transfer/getitemdetail"] cachePolicy:1 timeoutInterval:8];
    } else if (retry == 1) {
        // 爱回收/转转备选: POST v2/zzlogic/getiteminfo
        req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://app.zhuanzhuan.com/zz/v2/zzlogic/getiteminfo"] cachePolicy:1 timeoutInterval:8];
    } else if (retry == 2) {
        // 通用: 从jumpUrl提取host, POST /api/goods/detail
        NSURL *ju = [NSURL URLWithString:jumpUrl];
        if (!ju) return;
        NSString *apiUrl = [NSString stringWithFormat:@"%@://%@/api/goods/detail", ju.scheme, ju.host];
        req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:apiUrl] cachePolicy:1 timeoutInterval:8];
    } else {
        // 最终兜底: 请求原始HTML页面, 增强版regex提取版本号
        [self _fetchDetailHTML:jumpUrl title:title price:price infoId:infoId bid:bid];
        return;
    }
    req.HTTPMethod = @"POST";
    req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    if ([bid containsString:@"zhuanzhuan"]) {
        [req setValue:@"zhuanzhuan/12.0 (iPhone; iOS 16.0; Scale/2.00)" forHTTPHeaderField:@"User-Agent"];
    }
    
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (!d || e) { [self _tryFetchDetailAPI:infoId title:title price:price bid:bid jumpUrl:jumpUrl retry:retry+1]; return; }
        // 尝试JSON解析
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (j) {
            // 把整个响应转字符串搜索版本号
            NSString *js = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
            NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"(?:iOS|ios|系统|版本|systemVersion|osVersion)\"?:?\\s*[:=]?\\s*\"?(\\d{1,2}\\.\\d{1,2}(?:\\.\\d{1,2})?)\"?" options:NSRegularExpressionCaseInsensitive error:nil];
            NSArray *m = [re matchesInString:js options:0 range:NSMakeRange(0, js.length)];
            NSMutableSet *vs = [NSMutableSet set];
            for (NSTextCheckingResult *mr in m) { NSString *v = [js substringWithRange:[mr rangeAtIndex:1]]; if(v) [vs addObject:v]; }
            if (vs.count > 0) {
                NSDateFormatter *df = [NSDateFormatter new]; df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
                for (NSString *ver in vs) {
                    if (![[CollectorConfig shared] shouldCapture:ver]) continue;
                    NSUInteger ctxStart = [m.firstObject range].location;
                    NSString *ctx = @"";
                    if (ctxStart != NSNotFound && js.length > ctxStart)
                        ctx = [js substringWithRange:NSMakeRange(MAX(0,(NSInteger)ctxStart-30), MIN(120, js.length-ctxStart))];
                    [[Uploader shared] upload:@{@"title":title, @"price":price?:@"", @"ios_ver":ver, @"url":jumpUrl, @"info_id":infoId, @"time":[df stringFromDate:[NSDate date]], @"source":[bid containsString:@"zhuanzhuan"]?@"转转":@"爱回收", @"context":ctx}];
                }
                return; // 成功, 不再重试
            }
        }
        // JSON没版本号, 尝试下一个端点
        [self _tryFetchDetailAPI:infoId title:title price:price bid:bid jumpUrl:jumpUrl retry:retry+1];
    }] resume];
}

// 兜底: 请求HTML页面, 增强版regex(匹配JSON嵌入的版本号)
- (void)_fetchDetailHTML:(NSString *)jumpUrl title:(NSString *)title price:(NSString *)price infoId:(NSString *)infoId bid:(NSString *)bid {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:jumpUrl] cachePolicy:1 timeoutInterval:8];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (!d || e) return;
        NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        // 增强版: 匹配 "iOS 17.0" 或 "systemVersion":"17.0" 或 "os_version":"17.0" 等JSON/HTML中的版本号
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"(?:iOS|ios|系统|版本|systemVersion|osVersion)\\s*[:=]?\\s*\"?(\\d{1,2}\\.\\d{1,2}(?:\\.\\d{1,2})?)\"?" options:NSRegularExpressionCaseInsensitive error:nil];
        NSArray *m = [re matchesInString:s options:0 range:NSMakeRange(0, s.length)];
        NSMutableSet *vs = [NSMutableSet set];
        for (NSTextCheckingResult *mr in m) { NSString *v = [s substringWithRange:[mr rangeAtIndex:1]]; if(v) [vs addObject:v]; }
        NSDateFormatter *df = [NSDateFormatter new]; df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        for (NSString *ver in vs) {
            if (![[CollectorConfig shared] shouldCapture:ver]) continue;
            NSUInteger ctxStart = [m.firstObject range].location;
            NSString *ctx = @"";
            if (ctxStart != NSNotFound && s.length > ctxStart)
                ctx = [s substringWithRange:NSMakeRange(MAX(0,(NSInteger)ctxStart-30), MIN(120, s.length-ctxStart))];
            [[Uploader shared] upload:@{@"title":title, @"price":price?:@"", @"ios_ver":ver, @"url":jumpUrl, @"info_id":infoId, @"time":[df stringFromDate:[NSDate date]], @"source":[bid containsString:@"zhuanzhuan"]?@"转转":@"爱回收", @"context":ctx}];
        }
    }] resume];
}

@end


#pragma mark - 入口

__attribute__((constructor))
static void _init(void) {
    @autoreleasepool {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.5*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            NSLog(@"[iOS17Col] 🚀 插件已加载");
            [[CollectorConfig shared] fetchFromServer];

            Class c=NSClassFromString(@"WKUserContentController");
            if(c){
                Method m=class_getInstanceMethod(c,@selector(addScriptMessageHandler:name:));
                if(m){_orig_addSMH=method_getImplementation(m);method_setImplementation(m,(IMP)_hook_addSMH);}
                m=class_getInstanceMethod(c,@selector(addUserScript:));
                if(m){_orig_addUS=method_getImplementation(m);method_setImplementation(m,(IMP)_hook_addUS);}
            }
            Class sc=NSClassFromString(@"NSURLSession");
            if(sc){
                Method m=class_getInstanceMethod(sc,@selector(dataTaskWithRequest:completionHandler:));
                if(m){_orig_dtwr=method_getImplementation(m);method_setImplementation(m,(IMP)_hook_dtwr);}
                m=class_getInstanceMethod(sc,@selector(dataTaskWithURL:completionHandler:));
                if(m){_orig_dtwu=method_getImplementation(m);method_setImplementation(m,(IMP)_hook_dtwu);}
            }
            NSLog(@"[iOS17Col] ✅ Hooks done");
        });
    }
}
