<?php
/**
 * 保存配置
 * POST: { target_ios: "17.0" }
 */
header('Content-Type: application/json');

$configFile = __DIR__ . '/../config.json';

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    echo json_encode(['code' => -1, 'msg' => '仅支持 POST']);
    exit;
}

$raw = file_get_contents('php://input');
$data = json_decode($raw, true);

if (!$data || !isset($data['target_ios'])) {
    echo json_encode(['code' => -1, 'msg' => '缺少 target_ios']);
    exit;
}

$version = trim($data['target_ios']);
if (!preg_match('/^\d+\.\d+(\.\d+)?$/', $version)) {
    echo json_encode(['code' => -1, 'msg' => '版本格式无效，如 17.0']);
    exit;
}

$config = json_decode(file_exists($configFile) ? file_get_contents($configFile) : '{}', true) ?: [];
$config['target_ios'] = $version;

file_put_contents($configFile, json_encode($config, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));

echo json_encode(['code' => 1, 'msg' => "已更新为 iOS $version"]);
