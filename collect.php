<?php
/**
 * collect.php - 接收设备采集数据
 * POST JSON: {title, price, ios_ver, url, info_id, time, source, context}
 */
header('Content-Type: application/json; charset=utf-8');

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') { http_response_code(200); exit; }
if ($_SERVER['REQUEST_METHOD'] !== 'POST') { echo json_encode(['code'=>-1,'msg'=>'POST only']); exit; }

$raw = file_get_contents('php://input');
$data = json_decode($raw, true);
if (!$data || empty($data['title'])) { echo json_encode(['code'=>-1,'msg'=>'invalid']); exit; }

// 版本校验
$ver = $data['ios_ver'] ?? '';
if ($ver === '?' || $ver === 'API') {
    // 待处理 / API来源，放行
} elseif (!preg_match('/^\d+\.\d+/', $ver)) {
    echo json_encode(['code'=>0,'msg'=>'no version']); exit;
}

// 阈值标记
$cfg = json_decode(file_exists(__DIR__.'/config.json') ? file_get_contents(__DIR__.'/config.json') : '{}', true) ?: [];
$thresholds = $cfg['thresholds'] ?? [];
foreach (['lt','eq','gt'] as $op) {
    $tv = $thresholds[$op]['version'] ?? '17.0';
    if (version_compare($ver, $tv, $op) && ($thresholds[$op]['enabled'] ?? false)) {
        $data['threshold_op'] = "$op$tv";
        break;
    }
}

// 存储
$dataFile = __DIR__ . '/data/collected.json';
$all = [];
if (file_exists($dataFile)) $all = json_decode(file_get_contents($dataFile), true) ?: [];

// 24h去重
$now = time();
$key = ($data['title']??'').'|'.($data['info_id']??'').'|'.$ver;
foreach ($all as $item) {
    $ik = ($item['title']??'').'|'.($item['info_id']??'').'|'.($item['ios_ver']??'');
    if ($ik === $key && $now - strtotime($item['time'] ?? '') < 86400) {
        echo json_encode(['code'=>0,'msg'=>'dup']); exit;
    }
}

$data['server_time'] = date('Y-m-d H:i:s');
$all[] = $data;

if (!is_dir(__DIR__.'/data')) mkdir(__DIR__.'/data', 0777, true);
file_put_contents($dataFile, json_encode($all, JSON_UNESCAPED_UNICODE|JSON_PRETTY_PRINT));

echo json_encode(['code'=>1,'msg'=>'ok','total'=>count($all)]);
