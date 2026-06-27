<?php
/**
 * 读取配置 - 供 dylib 调用
 * GET 返回: {"target_ios":"17.0","upload_url":"http://..."}
 */
header('Content-Type: application/json');
header('Access-Control-Allow-Origin: *');

$configFile = __DIR__ . '/../config.json';

if (!file_exists($configFile)) {
    echo json_encode(['target_ios' => '17.0']);
    exit;
}

$config = json_decode(file_get_contents($configFile), true) ?: [];
echo json_encode($config);
