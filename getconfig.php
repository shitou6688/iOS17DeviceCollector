<?php
// 供 dylib 调用 - 返回当前阈值配置
header('Content-Type: application/json; charset=utf-8');
header('Access-Control-Allow-Origin: *');
readfile(__DIR__ . '/config.json');
