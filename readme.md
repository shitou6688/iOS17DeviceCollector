# iOS17DeviceCollector

巨魔注入插件 — 转转/爱回收 iOS 17.0 设备自动采集，上传到自有服务器。

## 原理

```
搜"15pro" → WebView 加载结果 → JS 扫描 "iOS 17.0" → 提取机型/价格/链接 → POST 服务器
```

## 编译 (GitHub Actions)

推送自动编译，产物在 Actions → Artifacts 下载。

## 注入

巨魔注入器 → 把 `iOS17DeviceCollector.dylib` 注入到转转 IPA `/Frameworks/`

## 服务器

`collect.php` 放到服务器 `api/collect.php`

## 定制

编辑 `ios17devicecollector.m`:

```objc
#define UPLOAD_URL   @"http://你的服务器/api/collect.php"
#define TARGET_IOS   @"17.0"
```
