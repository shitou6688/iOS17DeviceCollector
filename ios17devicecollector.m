/*
 * iOS17DeviceCollector.m
 * ======================
 * 巨魔注入插件 - 转转/爱回收 iOS 17.0 设备自动采集
 *
 * 工作原理:
 *   1. 注入 JS 到 WebView, 监听页面内容
 *   2. 检测到 "iOS 17.0" → 自动提取机型/价格/链接
 *   3. POST 到你的服务器
 *
 * 编译 (需 macOS + Xcode):
 *   xcrun -sdk iphoneos clang -arch arm64 -dynamiclib \
 *     -framework Foundation -framework UIKit -framework WebKit \
 *     -o iOS17Collector.dylib iOS17DeviceCollector.m
 *
 * 注入:
 *   用巨魔注入器把 iOS17Collector.dylib 注入到转转.ipa 的 /Frameworks/
 *
 * 服务器端:
 *   需要 PHP 接收脚本 (见 collect.php)
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

// ======================== 配置 ========================
#define UPLOAD_URL   @"http://124.221.171.80/chaxun/api/collect.php"
#define TARGET_IOS   @"17.0"
// ======================================================

#pragma mark - 数据模型

@interface DeviceInfo : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *price;
@property (nonatomic, copy) NSString *infoId;
@property (nonatomic, copy) NSString *detailURL;
@property (nonatomic, copy) NSString *iosVer;
@property (nonatomic, copy) NSString *time;
@property (nonatomic, copy) NSString *source;
@property (nonatomic, copy) NSString *context;  // 上下文文本 (用于验证)
@end

@implementation DeviceInfo
- (NSString *)jsonString {
    NSDictionary *d = @{
        @"title":    _title ?: @"",
        @"price":    _price ?: @"",
        @"info_id":  _infoId ?: @"",
        @"url":      _detailURL ?: @"",
        @"ios_ver":  _iosVer ?: @"",
        @"time":     _time ?: @"",
        @"source":   _source ?: @"",
        @"context":  _context ?: @""
    };
    NSData *j = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    return [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding];
}
@end

#pragma mark - 上传器

@interface Uploader : NSObject
+ (instancetype)shared;
- (void)upload:(DeviceInfo *)device;
- (void)log:(NSString *)msg;
@end

@implementation Uploader {
    NSMutableSet *_dedup;
}

+ (instancetype)shared {
    static Uploader *s;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [[Uploader alloc] init]; });
    return s;
}

- (instancetype)init {
    if (self = [super init]) {
        _dedup = [NSMutableSet set];
    }
    return self;
}

- (void)upload:(DeviceInfo *)device {
    // 去重: 同商品 10 分钟内不重复上报
    NSString *fingerprint = [NSString stringWithFormat:@"%@|%@",
        device.title, device.detailURL];
    @synchronized(_dedup) {
        if ([_dedup containsObject:fingerprint]) return;
        if (_dedup.count > 500) [_dedup removeAllObjects];
        [_dedup addObject:fingerprint];
    }
    
    [self log:[NSString stringWithFormat:@"📱 捕获: %@ | ¥%@",
        device.title, device.price]];
    
    NSURL *url = [NSURL URLWithString:UPLOAD_URL];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.HTTPBody = [[device jsonString] dataUsingEncoding:NSUTF8StringEncoding];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.timeoutInterval = 10;
    
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (e) {
            [self log:[NSString stringWithFormat:@"❌ 上传失败: %@", e.localizedDescription]];
        } else {
            NSInteger code = ((NSHTTPURLResponse *)r).statusCode;
            [self log:[NSString stringWithFormat:@"✅ 上传成功 HTTP %ld", (long)code]];
        }
    }] resume];
}

- (void)log:(NSString *)msg {
    NSLog(@"[iOS17Col] %@", msg);
}
@end

#pragma mark - JS 注入脚本

// 列表页扫描 JS
static NSString *kScanJS =
    @"(function(){\n"
    @" if(window.__i17c_scan)return;window.__i17c_scan=1;\n"
    @" var seen=new Set();\n"
    @" function scan(){\n"
    @"  try{\n"
    @"   var t=document.body.innerText||'';\n"
    @"   if(!/17\\.0|iOS\\s*17|ios\\s*17/.test(t))return;\n"
    @"   var fp=t.substring(0,60);\n"
    @"   if(seen.has(fp))return;seen.add(fp);\n"
    // 提取 iOS 版本上下文
    @"   var m=t.match(/(?:iOS|ios|系统|版本)[^\\n]{0,30}17\\.0[^\\n]{0,30}/g)||[];\n"
    @"   var ctx=m.join('|').substring(0,500);\n"
    // 提取价格
    @"   var pm=t.match(/[¥￥￥]\\s*([\\d,]+)/);\n"
    @"   var price=pm?pm[1]:'';\n"
    // 提取标题
    @"   var h1=document.querySelector('h1,[class*=title]');\n"
    @"   var title=h1?h1.innerText:(document.title||'');\n"
    @"   window.webkit.messageHandlers.i17c.postMessage({\n"
    @"    t:'scan',u:location.href,title:title,price:price,ctx:ctx\n"
    @"   });\n"
    @"  }catch(e){}\n"
    @" }\n"
    @" setInterval(scan,3000);scan();\n"
    @" var ob=new MutationObserver(function(){setTimeout(scan,800);});\n"
    @" ob.observe(document.body||document.documentElement,{childList:1,subtree:1,characterData:1});\n"
    @"})();";

// 详情页深度扫描 JS  
static NSString *kDetailJS =
    @"(function(){\n"
    @" if(window.__i17c_detail)return;window.__i17c_detail=1;\n"
    @" setTimeout(function(){\n"
    @"  try{\n"
    @"   var t=document.body.innerText||'';\n"
    @"   if(!/(iOS|ios|系统|版本)\\s*17\\.0/.test(t))return;\n"
    // 尝试获取结构化数据
    @"   var title=document.title||'';\n"
    @"   var price='';\n"
    @"   var p=document.querySelector('[class*=price],.price,.now-price');\n"
    @"   if(p)price=p.innerText.replace(/[^0-9.]/g,'');\n"
    @"   if(!price){\n"
    @"     var pm=t.match(/[¥￥￥]\\s*([\\d,]+)/);\n"
    @"     if(pm)price=pm[1];\n"
    @"   }\n"
    // 提取 iOS 版本周围的详细描述
    @"   var idx=t.search(/(iOS|ios|系统|版本)\\s*17\\.0/i);\n"
    @"   var ctx='';\n"
    @"   if(idx>=0){\n"
    @"     var s=Math.max(0,idx-150);\n"
    @"     ctx=t.substring(s,idx+200);\n"
    @"   }\n"
    @"   window.webkit.messageHandlers.i17c.postMessage({\n"
    @"    t:'detail',u:location.href,title:title,price:price,ctx:ctx\n"
    @"   });\n"
    @"  }catch(e){}\n"
    @" },2000);\n"
    @"})();";


#pragma mark - 消息处理器

@interface MsgHandler : NSObject <WKScriptMessageHandler>
@end

@implementation MsgHandler

- (void)userContentController:(WKUserContentController *)ctl
      didReceiveScriptMessage:(WKScriptMessage *)msg {
    
    if (![msg.body isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *b = msg.body;
    
    DeviceInfo *di = [[DeviceInfo alloc] init];
    di.title = b[@"title"] ?: @"未知";
    di.price = b[@"price"] ?: @"";
    di.detailURL = b[@"u"] ?: @"";
    di.iosVer = TARGET_IOS;
    di.context = b[@"ctx"] ?: @"";
    
    // 来源
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    di.source = [bid containsString:@"zhuanzhuan"] ? @"转转" :
                [bid containsString:@"aihuishou"] ? @"爱回收" : bid;
    
    // 时间
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    df.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    di.time = [df stringFromDate:[NSDate date]];
    
    // 过滤：必须有实质内容
    if (di.title.length < 2 || [di.title isEqualToString:@"未知"]) {
        // 尝试从 context 提取
        NSArray *models = @[@"iPhone", @"iPad", @"iPod"];
        for (NSString *m in models) {
            NSRange r = [di.context rangeOfString:m options:NSCaseInsensitiveSearch];
            if (r.location != NSNotFound) {
                NSUInteger end = MIN(r.location + 30, di.context.length);
                di.title = [di.context substringWithRange:
                    NSMakeRange(r.location, end - r.location)];
                break;
            }
        }
    }
    
    // 尝试提取 infoId (从 URL 中)
    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:@"infoId=(\\d+)" options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:di.detailURL
        options:0 range:NSMakeRange(0, di.detailURL.length)];
    if (m && m.numberOfRanges > 1) {
        di.infoId = [di.detailURL substringWithRange:[m rangeAtIndex:1]];
    }
    
    // 确保 JS 已注入
    [self ensureJS:ctl];
    
    // 上传
    [[Uploader shared] upload:di];
}

// 防重复注入
- (void)ensureJS:(WKUserContentController *)ctl {
    static NSMutableSet *done;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ done = [NSMutableSet set]; });
    
    NSValue *k = [NSValue valueWithNonretainedObject:ctl];
    @synchronized(done) {
        if ([done containsObject:k]) return;
        [done addObject:k];
    }
    
    // 注册 handler
    [ctl addScriptMessageHandler:self name:@"i17c"];
    
    // 注入扫描脚本
    WKUserScript *s1 = [[WKUserScript alloc]
        initWithSource:kScanJS
        injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
        forMainFrameOnly:YES];
    [ctl addUserScript:s1];
    
    // 注入详情脚本
    WKUserScript *s2 = [[WKUserScript alloc]
        initWithSource:kDetailJS
        injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
        forMainFrameOnly:YES];
    [ctl addUserScript:s2];
}

@end


#pragma mark - Hook WKUserContentController

static MsgHandler *gHandler = nil;

static IMP _orig_addScriptMessageHandler;
static void _hook_addScriptMessageHandler(id self, SEL _cmd,
    id<WKScriptMessageHandler> handler, NSString *name) {
    
    if (!gHandler) {
        gHandler = [[MsgHandler alloc] init];
        [gHandler ensureJS:self];
    }
    
    if (_orig_addScriptMessageHandler) {
        ((void(*)(id,SEL,id,NSString*))_orig_addScriptMessageHandler)(self,_cmd,handler,name);
    }
}

static IMP _orig_addUserScript;
static void _hook_addUserScript(id self, SEL _cmd, WKUserScript *script) {
    if (gHandler) [gHandler ensureJS:self];
    if (_orig_addUserScript) {
        ((void(*)(id,SEL,WKUserScript*))_orig_addUserScript)(self,_cmd,script);
    }
}


#pragma mark - Hook: NSURLSession

@interface NSObject (iOS17C_APIHook)
- (void)_parseAPIResponse:(NSData *)data url:(NSString *)url;
@end

// ======================== NSURLSession Hook ========================

static IMP _orig_dataTaskWithReq;
static NSURLSessionDataTask* _hook_dataTaskWithReq(
    id self, SEL _cmd, NSURLRequest *req,
    void(^handler)(NSData*,NSURLResponse*,NSError*)) {
    
    NSString *u = req.URL.absoluteString;
    
    // 拦截搜索/详情 API
    if ([u containsString:@"transfer/search"] ||
        [u containsString:@"getfeedflowinfo"] ||
        [u containsString:@"new-goods-detail"]) {
        
        void(^wrapped)(NSData*,NSURLResponse*,NSError*) =
            ^(NSData *d, NSURLResponse *r, NSError *e) {
            if (d && !e) {
                NSString *s = [[NSString alloc] initWithData:d
                    encoding:NSUTF8StringEncoding];
                // 仅当响应中提到 iOS 版本时才处理
                if (s && ([s containsString:@"17.0"] ||
                          [s rangeOfString:@"iOS 17" 
                              options:NSCaseInsensitiveSearch].location != NSNotFound)) {
                    [(NSObject*)self _parseAPIResponse:d url:u];
                }
            }
            if (handler) handler(d, r, e);
        };
        
        return ((id(*)(id,SEL,id,id))_orig_dataTaskWithReq)(self,_cmd,req,wrapped);
    }
    
    return ((id(*)(id,SEL,id,id))_orig_dataTaskWithReq)(self,_cmd,req,handler);
}


@implementation NSObject (iOS17C_APIHook)

- (void)_parseAPIResponse:(NSData *)data url:(NSString *)url {
    @try {
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
            options:0 error:nil];
        if (!json) return;
        
        // 提取商品列表
        NSArray *infos = json[@"respData"][@"infos"] ?:
                         json[@"data"][@"list"] ?:
                         json[@"data"][@"infos"];
        if (![infos isKindOfClass:[NSArray class]]) return;
        
        for (NSDictionary *info in infos) {
            NSString *title = info[@"title"] ?: info[@"infoDesc"] ?: @"";
            NSString *infoId = info[@"infoId"] ?: info[@"strInfoId"] ?:
                               [info[@"infoId"] description] ?: @"";
            NSString *jumpUrl = info[@"jumpUrl"] ?: @"";
            
            NSDictionary *pi = info[@"priceInfo"];
            NSString *price = pi[@"priceText"] ?:
                [NSString stringWithFormat:@"%@", pi[@"value"]];
            
            if (title.length > 3) {
                // API 数据中没有 iOS 版本，标记为"待确认"
                // 仅上传明确的 iPhone 机型 (减少噪音)
                if (![title.lowercaseString hasPrefix:@"iphone"] &&
                    ![title.lowercaseString hasPrefix:@"ipad"]) continue;
                
                DeviceInfo *di = [[DeviceInfo alloc] init];
                di.title = title;
                di.price = price ?: @"";
                di.infoId = infoId;
                di.detailURL = jumpUrl.length > 0 ? jumpUrl : url;
                di.iosVer = [NSString stringWithFormat:@"%@?", TARGET_IOS];
                di.context = @"[API capture - verify iOS version]";
                
                NSDateFormatter *df = [[NSDateFormatter alloc] init];
                df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
                di.time = [df stringFromDate:[NSDate date]];
                
                NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
                di.source = [bid containsString:@"zhuanzhuan"] ? @"转转" : @"爱回收";
                
                [[Uploader shared] upload:di];
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[iOS17Col] Parse error: %@", e);
    }
}

@end


#pragma mark - 初始化

__attribute__((constructor))
static void _init(void) {
    @autoreleasepool {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.5 * NSEC_PER_SEC),
            dispatch_get_main_queue(), ^{
            
            [[Uploader shared] log:@"🚀 插件已加载"];
            [[Uploader shared] log:[NSString stringWithFormat:
                @"目标: iOS %@, 上传: %@", TARGET_IOS, UPLOAD_URL]];
            
            // Hook 1: WKUserContentController
            Class c = NSClassFromString(@"WKUserContentController");
            if (c) {
                Method m1 = class_getInstanceMethod(c,
                    @selector(addScriptMessageHandler:name:));
                if (m1) {
                    _orig_addScriptMessageHandler = method_getImplementation(m1);
                    method_setImplementation(m1,
                        (IMP)_hook_addScriptMessageHandler);
                    [[Uploader shared] log:@"✅ Hooked WKUserContentController"];
                }
                
                Method m2 = class_getInstanceMethod(c,
                    @selector(addUserScript:));
                if (m2) {
                    _orig_addUserScript = method_getImplementation(m2);
                    method_setImplementation(m2, (IMP)_hook_addUserScript);
                }
            }
            
            // Hook 2: NSURLSession (备选)
            Class sc = NSClassFromString(@"NSURLSession");
            if (sc) {
                Method m3 = class_getInstanceMethod(sc,
                    @selector(dataTaskWithRequest:completionHandler:));
                if (m3) {
                    _orig_dataTaskWithReq = method_getImplementation(m3);
                    method_setImplementation(m3, (IMP)_hook_dataTaskWithReq);
                    [[Uploader shared] log:@"✅ Hooked NSURLSession"];
                }
            }
        });
    }
}
