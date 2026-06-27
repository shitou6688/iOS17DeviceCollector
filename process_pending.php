<?php
/**
 * process_pending.php - 服务端处理待提取iOS版本号的列表数据
 * 
 * 用法: php process_pending.php
 * cron: */5 * * * * php /path/to/process_pending.php
 * 
 * 策略:
 *   1. 尝试用 infoId 调用详情API
 *   2. 采集HTML页面,解析嵌入式JSON中的版本号
 *   3. 兜底: 正则匹配页面中所有版本号
 */

$dataFile = __DIR__ . '/data/collected.json';
if (!file_exists($dataFile)) { echo "No data file\n"; exit; }

$all = json_decode(file_get_contents($dataFile), true) ?: [];
$updated = false;

foreach ($all as $i => &$item) {
    $ver = $item['ios_ver'] ?? '';
    if ($ver !== '?') continue; // 已处理的跳过
    
    $url = $item['url'] ?? '';
    $infoId = $item['info_id'] ?? '';
    $title = $item['title'] ?? '';
    
    echo "Processing: $title (infoId=$infoId)\n";
    
    $iosVer = extractIOSVersion($url, $infoId, $title);
    
    if ($iosVer) {
        $item['ios_ver'] = $iosVer;
        $item['context'] = ($item['context'] ?? '') . ' | server_filled';
        $updated = true;
        echo "  => iOS $iosVer\n";
    } else {
        // 标记已尝试，24小时后重试
        if (!isset($item['_retry_count'])) $item['_retry_count'] = 0;
        if ($item['_retry_count'] < 3) {
            $item['_retry_count']++;
        } else {
            $item['ios_ver'] = 'N/A'; // 放弃
        }
        $updated = true;
        echo "  => FAILED (retry {$item['_retry_count']}/3)\n";
    }
    
    // 限速
    usleep(500000); // 0.5s
}

if ($updated) {
    file_put_contents($dataFile, json_encode($all, JSON_UNESCAPED_UNICODE|JSON_PRETTY_PRINT));
    echo "Saved.\n";
}

/**
 * 三级策略提取iOS版本号
 */
function extractIOSVersion($url, $infoId, $title) {
    // 策略1: 尝试详情API (用infoId)
    if ($infoId) {
        $ver = tryDetailAPI($infoId, $url);
        if ($ver) return $ver;
    }
    
    // 策略2: 抓取详情页HTML,搜索嵌入式JSON
    if ($url) {
        $ver = tryHTMLPage($url);
        if ($ver) return $ver;
    }
    
    return null;
}

/**
 * 策略1: POST 详情API
 */
function tryDetailAPI($infoId, $jumpUrl) {
    $endpoints = [
        ['url' => 'https://app.zhuanzhuan.com/zz/transfer/getitemdetail', 'method' => 'POST'],
        ['url' => 'https://app.zhuanzhuan.com/zz/v2/zzlogic/getiteminfo', 'method' => 'POST'],
        ['url' => 'https://app.zhuanzhuan.com/zz/v2/zzlogic/getgoodsinfo', 'method' => 'POST'],
    ];
    
    foreach ($endpoints as $ep) {
        $ch = curl_init();
        curl_setopt_array($ch, [
            CURLOPT_URL => $ep['url'],
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_TIMEOUT => 10,
            CURLOPT_FOLLOWLOCATION => true,
            CURLOPT_HTTPHEADER => [
                'User-Agent: zhuanzhuan/12.11.6 (iPhone; iOS 16.1; Scale/2.00)',
                'Content-Type: application/x-www-form-urlencoded',
                'Accept: application/json',
                'Accept-Language: zh-Hans-CN;q=1',
            ],
            CURLOPT_POST => true,
            CURLOPT_POSTFIELDS => "infoId={$infoId}&needVideo=0",
        ]);
        
        $resp = curl_exec($ch);
        $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
        curl_close($ch);
        
        if ($httpCode == 200 && $resp) {
            $ver = extractVersionFromText($resp);
            if ($ver) return $ver;
        }
    }
    
    return null;
}

/**
 * 策略2: 抓取HTML页面, 搜索嵌入式JSON + 可见文本
 */
function tryHTMLPage($url) {
    $ch = curl_init();
    curl_setopt_array($ch, [
        CURLOPT_URL => $url,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT => 15,
        CURLOPT_FOLLOWLOCATION => true,
        CURLOPT_HTTPHEADER => [
            'User-Agent: Mozilla/5.0 (iPhone; CPU iPhone OS 16_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148',
            'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Accept-Language: zh-Hans-CN;q=1',
        ],
    ]);
    
    $html = curl_exec($ch);
    $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    
    if ($httpCode != 200 || !$html) return null;
    
    // 尝试提取嵌入式JSON (SSR数据 / __NEXT_DATA__ / __NUXT__ / initialState)
    $jsonPatterns = [
        '/<script[^>]*id="__NEXT_DATA__"[^>]*>(.*?)<\/script>/s',
        '/<script[^>]*>window\.__NUXT__\s*=\s*({.*?})<\/script>/s',
        '/<script[^>]*>window\.__INITIAL_STATE__\s*=\s*({.*?})<\/script>/s',
        '/<script[^>]*type="application\/json"[^>]*>(.*?)<\/script>/s',
        '/"(?:iOS|ios|系统|版本|systemVersion|osVersion|iosVersion)"\s*[:=]\s*"?(\d{1,2}\.\d{1,2}(?:\.\d{1,2})?)"?/i',
    ];
    
    foreach ($jsonPatterns as $pattern) {
        if (preg_match($pattern, $html, $m)) {
            if (count($m) >= 2) {
                $block = $m[1];
                // 在JSON块中搜索版本号
                $ver = extractVersionFromText($block);
                if ($ver) return $ver;
            }
        }
    }
    
    // 兜底: 正则搜整个页面文本
    return extractVersionFromText($html);
}

/**
 * 从文本中提取iOS版本号
 */
function extractVersionFromText($text) {
    $patterns = [
        // JSON格式: "iosVersion":"17.0" 或 "systemVersion":"17.0.1"
        '/"(?:iosVersion|systemVersion|osVersion|iOSVersion|firmwareVersion|productVersion)"\s*:\s*"(\d{1,2}\.\d{1,2}(?:\.\d{1,2})?)"/i',
        // 键值对: systemVersion = "17.0"
        '/(?:iOS|ios|系统|版本|systemVersion|osVersion)\s*[:=]\s*"?(\d{1,2}\.\d{1,2}(?:\.\d{1,2})?)"?/i',
        // 纯文本: iOS 17.0.1
        '/(?:iOS|ios|系统版本)\s*(\d{1,2}\.\d{1,2}(?:\.\d{1,2})?)/i',
        // 中文: 系统版本：17.0、版本:17.0
        '/(?:系统版本|操作系统|固件版本|版本)[：:]\s*(\d{1,2}\.\d{1,2}(?:\.\d{1,2})?)/u',
    ];
    
    foreach ($patterns as $re) {
        if (preg_match($re, $text, $m)) {
            return $m[1];
        }
    }
    
    return null;
}
