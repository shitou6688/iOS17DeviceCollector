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

// 前向声明
static BOOL _isValidIOSVersion(NSString *ver);

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
    @" var sent=new Set(),detailSent=new Set();"
    @" function scan(){"
    @"  try{"
    @"   var t=document.body.innerText||'';"
    @"   var re=/(?:iOS|ios|系统|版本)\s*(\d{1,2}\.\d{1,2}(?:\.\d{1,2})?)/gi;"
    @"   var m,versions=[];"
    @"   while(m=re.exec(t)){"
    @"    var ver=m[1];"
    @"    if(parseInt(ver)<14||parseInt(ver)>20)continue;"
    @"    if(versions.indexOf(ver)<0)versions.push(ver);"
    @"   }"
    @"   if(versions.length>0){"
    @"    var fp=versions.join(',')+t.substring(0,50);"
    @"    if(!sent.has(fp)){sent.add(fp);"
    @"     var pm=t.match(/[¥￥]\s*([\d,]+)/);"
    @"     var price=pm?pm[1]:'';"
    @"     var im=t.match(/(iPhone\s*\d+\s*(Pro|Max|Plus|mini)?\s*(Max)?)/i);"
    @"     var title=im?im[1]:(document.title||'');"
    @"     if(!im&&document.title){var dm=document.title.match(/(iPhone\s*\d+\s*(Pro|Max|Plus|mini)?)/i);if(dm)title=dm[1];}"
    @"     var iid='';var um=location.href.match(/infoId=(\d+)/);if(um)iid=um[1];"
    @"     window.webkit.messageHandlers.i17c.postMessage({"
    @"      t:'scan',u:location.href,title:title,price:price,iid:iid,versions:versions,"
    @"      ctx:t.substring(Math.max(0,re.lastIndex-150),re.lastIndex+150)"
    @"     });"
    @"    }"
    @"   }"
    @"   crawlDetail();"
    @"  }catch(e){}"
    @" }"
    @" function crawlDetail(){"
    @"  try{"
    @"   var links=[];"
    @"   document.querySelectorAll('[href*=\"infoId\"],a[href*=\"goods-detail\"],a[href*=\"streamline_detail\"]').forEach(function(a){"
    @"    var h=a.href||a.getAttribute('href')||'';"
    @"    var m=h.match(/infoId=(\d+)/);"
    @"    if(m&&!detailSent.has(m[1]))links.push({id:m[1],t:a.textContent.trim().substring(0,60)});"
    @"   });"
    @"   if(!links.length)return;"
    @"   var item=links[0];"
    @"   if(detailSent.has(item.id))return;detailSent.add(item.id);"
    @"   fetchDetailAPI(item.id,item.t);"
    @"  }catch(e){}"
    @" }"
    @" function fetchDetailAPI(infoId,title){"
    @"  var body='infoId='+infoId+'&needVideo=0';"
    @"  var idx=0;"
    @"  function tryNext(){"
    @"   var urls=["
    @"    'https://app.zhuanzhuan.com/zz/transfer/getitemdetail',"
    @"    'https://app.zhuanzhuan.com/zz/v2/zzlogic/getiteminfo'"
    @"   ];"
    @"   if(idx>=urls.length)return;"
    @"   var url=urls[idx];"
    @"   fetch(url,{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:body,credentials:'include'})"
    @"   .then(function(r){if(!r.ok)throw r.status;return r.text();})"
    @"   .then(function(txt){"
    @"    var re=/(?:systemVersion|osVersion|iOS|ios|系统版本|操作系统)\"?\s*[:=]\s*\"?(\d{1,2}\.\d{1,2}(?:\.\d{1,2})?)\"?/gi;"
    @"    var m,vs=[];while(m=re.exec(txt)){var v=m[1];if(parseInt(v)>=14&&parseInt(v)<=20&&vs.indexOf(v)<0)vs.push(v);}"
    @"    if(vs.length>0){"
    @"     window.webkit.messageHandlers.i17c.postMessage({"
    @"      t:'api',u:url,title:title,price:'',iid:infoId,versions:vs,ctx:txt.substring(0,200)"
    @"     });"
    @"     idx=99;"
    @"    }else{idx++;tryNext();}"
    @"   }).catch(function(){idx++;tryNext();});"
    @"  }"
    @"  tryNext();"
    @" }"
    @" setInterval(function(){scan();crawlDetail();},4000);scan();crawlDetail();"
    @" new MutationObserver(function(){setTimeout(function(){scan();crawlDetail();},1200);}).observe(document.body||document.documentElement,{childList:1,subtree:1,characterData:1});"
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
        if (!_isValidIOSVersion(ver)) continue;
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

// ========= NSURLProtocol 拦截方案 (NSURLSession类簇无法直接swizzle) =========

// URL 关键词匹配
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

// 声明NSObject(I17C)的API解析方法
@interface NSObject (I17C_Protocol)
- (void)_parseAPI:(NSData *)d url:(NSString *)u;
- (void)_autoFetchDetail:(NSString *)jumpUrl title:(NSString *)title price:(NSString *)price infoId:(NSString *)infoId bid:(NSString *)bid;
- (void)_extractAndUploadVersion:(NSString *)text title:(NSString *)title price:(NSString *)price url:(NSString *)url infoId:(NSString *)infoId bid:(NSString *)bid;
@end

@interface I17CURLProtocol : NSURLProtocol
@end

@implementation I17CURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    // 检查是否已处理过（防递归）
    if ([NSURLProtocol propertyForKey:@"I17CProcessed" inRequest:request]) return NO;
    return _isListingAPI(request.URL.absoluteString);
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSMutableURLRequest *mReq = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:@"I17CProcessed" inRequest:mReq];
    
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSMutableArray *classes = [cfg.protocolClasses mutableCopy];
    [classes removeObject:[I17CURLProtocol class]];
    cfg.protocolClasses = classes;
    
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [session dataTaskWithRequest:mReq completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (d && !e && _hasDeviceKeywords(d)) {
            [(NSObject *)weakSelf _parseAPI:d url:self.request.URL.absoluteString];
        }
        if (e) {
            [self.client URLProtocol:self didFailWithError:e];
        } else {
            [self.client URLProtocol:self didReceiveResponse:r cacheStoragePolicy:NSURLCacheStorageNotAllowed];
            [self.client URLProtocol:self didLoadData:d];
            [self.client URLProtocolDidFinishLoading:self];
        }
    }];
    [task resume];
}

- (void)stopLoading {}

@end

// Swizzle NSURLSessionConfiguration 注入 NSURLProtocol
static void _injectProtocolIntoConfiguration(id config) {
    @try {
        NSArray *classes = [config valueForKey:@"protocolClasses"];
        if (![classes containsObject:[I17CURLProtocol class]]) {
            NSMutableArray *newClasses = [classes mutableCopy] ?: [NSMutableArray array];
            [newClasses insertObject:[I17CURLProtocol class] atIndex:0];
            [config setValue:newClasses forKey:@"protocolClasses"];
        }
    } @catch (NSException *e) {}
}

static IMP _orig_defaultCfg;
static id _hook_defaultCfg(id self, SEL _cmd) {
    id cfg = ((id(*)(id,SEL))_orig_defaultCfg)(self,_cmd);
    _injectProtocolIntoConfiguration(cfg);
    return cfg;
}

static IMP _orig_ephemeralCfg;
static id _hook_ephemeralCfg(id self, SEL _cmd) {
    id cfg = ((id(*)(id,SEL))_orig_ephemeralCfg)(self,_cmd);
    _injectProtocolIntoConfiguration(cfg);
    return cfg;
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
                    // 没找到 iOS 版本 → WKWebView渲染详情页提取 + 同时上传列表数据
                    NSString *jumpUrl=info[@"jumpUrl"]?:info[@"jump_url"]?:info[@"detailUrl"]?:info[@"url"]?:info[@"link"];
                    NSString *infoId=[info[@"infoId"]?:info[@"strInfoId"]?:info[@"id"]?:info[@"spuId"]?:info[@"productId"]?:info[@"goodsId"] description];
                    if(jumpUrl.length>5&&infoId.length>5){
                        [self _autoFetchDetail:jumpUrl title:title price:price infoId:infoId bid:bid];
                    }
                }
        }
    }@catch(NSException *e){}
}

// 自动拉取详情页，提取 iOS 版本
// 策略: 隐藏WKWebView渲染SPA页面, JS执行后evaluateJavaScript获取文本
// 限速: 每3秒1个, 排队延迟执行
- (void)_autoFetchDetail:(NSString *)jumpUrl title:(NSString *)title price:(NSString *)price infoId:(NSString *)infoId bid:(NSString *)bid {
    static NSMutableSet *fetched;
    static dispatch_once_t t; dispatch_once(&t,^{fetched=[NSMutableSet set];});
    @synchronized(fetched){ if([fetched containsObject:infoId]||fetched.count>500)return; [fetched addObject:infoId]; }
    static NSTimeInterval nextFetchTime;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (nextFetchTime < now) nextFetchTime = now;
    NSTimeInterval delay = nextFetchTime - now;
    nextFetchTime += 3.0; // 3秒间隔, 给JS渲染留时间
    
    NSString *capturedUrl = jumpUrl;
    NSString *capturedTitle = title;
    NSString *capturedPrice = price;
    NSString *capturedInfoId = infoId;
    NSString *capturedBid = bid;
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
        __block WKWebView *wv = [[WKWebView alloc] initWithFrame:CGRectMake(0, 0, 1, 1) configuration:config];
        wv.hidden = YES;
        // 注入JS扫描器到隐藏WebView
        if (gHandler) [gHandler ensureJS:wv.configuration.userContentController];
        
        NSURL *detailUrl = [NSURL URLWithString:capturedUrl];
        if (!detailUrl) return;
        NSURLRequest *req = [NSURLRequest requestWithURL:detailUrl cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:15];
        
        // JS渲染完成后提取文本
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [wv evaluateJavaScript:@"document.body?document.body.innerText:''" completionHandler:^(id result, NSError *err) {
                NSString *text = [result isKindOfClass:[NSString class]] ? (NSString *)result : @"";
                if (text.length > 50) {
                    [self _extractAndUploadVersion:text title:capturedTitle price:capturedPrice url:capturedUrl infoId:capturedInfoId bid:capturedBid];
                }
                [wv stopLoading];
                wv = nil; // 释放
            }];
        });
        
        [wv loadRequest:req];
    });
}

// 从文本中提取iOS版本号并上传（过滤内核版本号）
- (void)_extractAndUploadVersion:(NSString *)text title:(NSString *)title price:(NSString *)price url:(NSString *)url infoId:(NSString *)infoId bid:(NSString *)bid {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"(?:iOS|ios|系统版本|操作系统)[：:\\s]+(\\d{1,2}\\.\\d{1,2}(?:\\.\\d{1,2})?)" options:NSRegularExpressionCaseInsensitive error:nil];
    NSArray *matches = [re matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    NSMutableSet *versions = [NSMutableSet set];
    for (NSTextCheckingResult *m in matches) {
        NSString *v = [text substringWithRange:[m rangeAtIndex:1]];
        if (v && _isValidIOSVersion(v)) [versions addObject:v];
    }
    if (!versions.count) return;
    
    NSDateFormatter *df = [NSDateFormatter new]; df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    for (NSString *ver in versions) {
        if (![[CollectorConfig shared] shouldCapture:ver]) continue;
        [[Uploader shared] upload:@{
            @"title":title, @"price":price?:@"", @"ios_ver":ver, @"url":url, @"info_id":infoId,
            @"time":[df stringFromDate:[NSDate date]],
            @"source":[bid containsString:@"zhuanzhuan"]?@"转转":@"爱回收",
            @"context":@"webkit_rendered"
        }];
    }
}

// 校验是否为有效iOS版本号（过滤Darwin内核版本如26.x）
static BOOL _isValidIOSVersion(NSString *ver) {
    if (!ver.length) return NO;
    NSArray *parts = [ver componentsSeparatedByString:@"."];
    if (parts.count < 2) return NO;
    NSInteger major = [parts[0] integerValue];
    // iOS 版本号范围: 14.0 ~ 20.x（2026年最新），Dawin内核版本号通常 21+
    return major >= 14 && major <= 20;
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
            // 注册NSURLProtocol(NSURLSession是类簇，不能用method_setImplementation)
            [NSURLProtocol registerClass:[I17CURLProtocol class]];
            Class cfgClass = NSClassFromString(@"NSURLSessionConfiguration");
            if (cfgClass) {
                Method m = class_getClassMethod(cfgClass, @selector(defaultSessionConfiguration));
                if (m) { _orig_defaultCfg = method_getImplementation(m); method_setImplementation(m, (IMP)_hook_defaultCfg); }
                m = class_getClassMethod(cfgClass, @selector(ephemeralSessionConfiguration));
                if (m) { _orig_ephemeralCfg = method_getImplementation(m); method_setImplementation(m, (IMP)_hook_ephemeralCfg); }
            }
            NSLog(@"[iOS17Col] ✅ Hooks done");
        });
    }
}
