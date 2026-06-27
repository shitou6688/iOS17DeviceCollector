<?php
/**
 * iOS17DeviceCollector - 服务端接收脚本
 * 
 * 部署: 放到 http://124.221.171.80/api/collect.php
 * 
 * 接收 POST JSON:
 * {
 *   "title": "iPhone 15 Pro 256G 白色钛金属",
 *   "price": "5800",
 *   "info_id": "20654190...",
 *   "url": "https://m.zhuanzhuan.com/...",
 *   "ios_ver": "17.0",
 *   "time": "2026-06-27 15:30:00",
 *   "source": "转转",
 *   "context": "...iOS 17.0..."
 * }
 */

header('Content-Type: application/json');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: POST, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type');

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    http_response_code(200);
    exit;
}

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    echo json_encode(['code' => -1, 'msg' => '仅支持 POST']);
    exit;
}

// 接收 JSON
$raw = file_get_contents('php://input');
$data = json_decode($raw, true);

if (!$data || empty($data['title'])) {
    echo json_encode(['code' => -1, 'msg' => '无效数据']);
    exit;
}

// 去重: 同 title + info_id 24小时内不重复
$dataFile = __DIR__ . '/../data/collected.json';
$allData = [];
if (file_exists($dataFile)) {
    $allData = json_decode(file_get_contents($dataFile), true) ?: [];
}

$dupKey = ($data['title'] ?? '') . '|' . ($data['info_id'] ?? '');
$now = time();
foreach ($allData as $item) {
    $itemKey = ($item['title'] ?? '') . '|' . ($item['info_id'] ?? '');
    $itemTime = strtotime($item['time'] ?? '');
    if ($itemKey === $dupKey && ($now - $itemTime) < 86400) {
        echo json_encode(['code' => 0, 'msg' => '已存在 (24h内重复)']);
        exit;
    }
}

// 保存到 JSON 文件
$data['server_time'] = date('Y-m-d H:i:s');
$allData[] = $data;

// 创建 data 目录
$dataDir = dirname($dataFile);
if (!is_dir($dataDir)) {
    mkdir($dataDir, 0755, true);
}

file_put_contents($dataFile, json_encode($allData, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));

// 可选: 发送邮件通知
$emailEnabled = ($data['also_email'] ?? false) || true;  // 默认开启
if ($emailEnabled) {
    $to = 'your-email@example.com';  // ← 改成你的邮箱
    $subject = "[iOS17采集] {$data['title']} - ¥{$data['price']}";
    $body = "新采集到 iOS 17.0 设备:\n\n"
          . "机型: {$data['title']}\n"
          . "价格: ¥{$data['price']}\n"
          . "iOS: {$data['ios_ver']}\n"
          . "链接: {$data['url']}\n"
          . "来源: {$data['source']}\n"
          . "时间: {$data['time']}\n"
          . "上下文: {$data['context']}\n";
    
    @mail($to, $subject, $body);
}

echo json_encode([
    'code' => 1,
    'msg' => '采集成功',
    'total' => count($allData)
]);
