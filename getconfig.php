<?php
/**
 * getconfig.php - 返回阈值配置给dylib
 */
header('Content-Type: application/json; charset=utf-8');
$cfgFile = __DIR__ . '/config.json';
$cfg = json_decode(file_exists($cfgFile) ? file_get_contents($cfgFile) : '{}', true) ?: [];
echo json_encode($cfg, JSON_UNESCAPED_UNICODE);
