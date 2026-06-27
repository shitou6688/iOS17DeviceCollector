<?php
/**
 * 接收采集数据
 * POST JSON: {title, price, ios_ver, url, ...}
 */
header('Content-Type: application/json; charset=utf-8');

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') { http_response_code(200); exit; }
if ($_SERVER['REQUEST_METHOD'] !== 'POST') { echo json_encode(['code'=>-1,'msg'=>'POST only']); exit; }

$raw = file_get_contents('php://input');
$data = json_decode($raw, true);
if (!$data || empty($data['title'])) { echo json_encode(['code'=>-1,'msg'=>'invalid']); exit; }

// 过滤: 必须有 iOS 版本号
$ver = $data['ios_ver'] ?? '';
if ($ver === 'API') {
    // API 来源且版本未知, 仍然记录但不报警
} elseif (!preg_match('/^\d+\.\d+/', $ver)) {
    echo json_encode(['code'=>0,'msg'=>'no version']);
    exit;
}

// 按阈值标记
$configFile = __DIR__ . '/config.json';
$cfg = json_decode(file_exists($configFile) ? file_get_contents($configFile) : '{}', true) ?: [];
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

// 去重 24h
$now = time();
$key = ($data['title']??'').'|'.($data['info_id']??'').'|'.$ver;
foreach ($all as $item) {
    $ik = ($item['title']??'').'|'.($item['info_id']??'').'|'.($item['ios_ver']??'');
    if ($ik === $key && $now - strtotime($item['time'] ?? '') < 86400) {
        echo json_encode(['code'=>0,'msg'=>'dup']);
        exit;
    }
}

$data['server_time'] = date('Y-m-d H:i:s');
$all[] = $data;

if (!is_dir(__DIR__.'/data')) mkdir(__DIR__.'/data', 0777, true);
file_put_contents($dataFile, json_encode($all, JSON_UNESCAPED_UNICODE|JSON_PRETTY_PRINT));

echo json_encode(['code'=>1,'msg'=>'ok','total'=>count($all)]);
