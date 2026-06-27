<?php
/**
 * iOS17DeviceCollector 后台面板
 * 部署: 放到服务器任意位置，如 /admin/index.php
 * 数据源: ../data/collected.json
 */

$configFile = __DIR__ . '/../config.json';
$config = json_decode(file_exists($configFile) ? file_get_contents($configFile) : '{}', true) ?: [];
$targetIOS = $config['target_ios'] ?? '17.0';

$dataFile = __DIR__ . '/../data/collected.json';
$devices = [];
if (file_exists($dataFile)) {
    $devices = json_decode(file_get_contents($dataFile), true) ?: [];
}
// 倒序 (最新的在前)
$devices = array_reverse($devices);

// 处理保存设置
$saved = false;
if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['target_ios'])) {
    $v = trim($_POST['target_ios']);
    if (preg_match('/^\d+\.\d+/', $v)) {
        $config['target_ios'] = $v;
        file_put_contents($configFile, json_encode($config, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));
        $targetIOS = $v;
        $saved = true;
    }
}

// 统计
$totalCount = count($devices);
$sources = ['转转' => 0, '爱回收' => 0];
$models = [];
foreach ($devices as $d) {
    $src = $d['source'] ?? '未知';
    $sources[$src] = ($sources[$src] ?? 0) + 1;
    
    // 提取机型关键词
    $title = $d['title'] ?? '';
    if (preg_match('/(iPhone\s*\d+\s*(Pro|Max|Plus|mini)?)/i', $title, $m)) {
        $model = $m[1];
    } elseif (preg_match('/(iPad\s*\w*)/i', $title, $m)) {
        $model = $m[1];
    } else {
        $model = mb_substr($title, 0, 15) ?: '其他';
    }
    $models[$model] = ($models[$model] ?? 0) + 1;
}
arsort($models);

// 价格统计
$prices = array_filter(array_map(function($d) {
    $p = str_replace(',', '', $d['price'] ?? '');
    return is_numeric($p) ? (float)$p / 100 : 0;
}, $devices), function($p) { return $p > 0; });
$avgPrice = count($prices) > 0 ? round(array_sum($prices) / count($prices), 2) : 0;

// URL 清洗
function cleanUrl($url) {
    $url = urldecode($url);
    return htmlspecialchars($url, ENT_QUOTES, 'UTF-8');
}
?>
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>iOS17 设备采集后台</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #0f1117; color: #e1e4e8; padding: 20px; }
        .header { text-align: center; padding: 40px 0 30px; }
        .header h1 { font-size: 28px; background: linear-gradient(135deg, #667eea, #764ba2); -webkit-background-clip: text; -webkit-text-fill-color: transparent; }
        .header p { color: #8b949e; margin-top: 8px; }
        .settings { max-width: 600px; margin: 0 auto 20px; background: #161b22; border: 1px solid #30363d; border-radius: 10px; padding: 20px; display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
        .settings label { color: #8b949e; font-size: 14px; white-space: nowrap; }
        .settings input { padding: 8px 12px; border-radius: 6px; border: 1px solid #30363d; background: #0d1117; color: #e1e4e8; font-size: 16px; width: 80px; text-align: center; }
        .settings button { padding: 8px 18px; border-radius: 6px; border: none; background: #238636; color: #fff; font-size: 14px; cursor: pointer; }
        .settings button:hover { background: #2ea043; }
        .settings .toast { color: #3fb950; font-size: 13px; display: none; }
        .settings .toast.show { display: inline; }
        .stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 15px; max-width: 900px; margin: 0 auto 30px; }
        .stat { background: #161b22; border: 1px solid #30363d; border-radius: 10px; padding: 18px; text-align: center; }
        .stat .num { font-size: 32px; font-weight: 700; color: #58a6ff; }
        .stat .label { font-size: 13px; color: #8b949e; margin-top: 4px; }
        .container { max-width: 1200px; margin: 0 auto; }
        .toolbar { display: flex; gap: 10px; margin-bottom: 15px; flex-wrap: wrap; }
        .toolbar input, .toolbar button { padding: 8px 14px; border-radius: 6px; border: 1px solid #30363d; background: #161b22; color: #e1e4e8; font-size: 14px; }
        .toolbar input { flex: 1; min-width: 200px; }
        .toolbar button { cursor: pointer; background: #238636; border-color: #238636; }
        .toolbar button:hover { background: #2ea043; }
        .model-tags { display: flex; flex-wrap: wrap; gap: 6px; margin-bottom: 15px; }
        .model-tag { padding: 4px 10px; border-radius: 14px; background: #21262d; border: 1px solid #30363d; font-size: 12px; cursor: pointer; color: #8b949e; transition: all 0.2s; }
        .model-tag:hover, .model-tag.active { background: #1f6feb; border-color: #1f6feb; color: #fff; }
        .model-tag .count { color: #58a6ff; margin-left: 4px; }
        .model-tag.active .count { color: #fff; }
        table { width: 100%; border-collapse: collapse; background: #161b22; border: 1px solid #30363d; border-radius: 10px; overflow: hidden; }
        th, td { padding: 12px 14px; text-align: left; border-bottom: 1px solid #21262d; font-size: 14px; }
        th { background: #21262d; color: #8b949e; font-weight: 600; position: sticky; top: 0; cursor: pointer; }
        th:hover { color: #fff; }
        tr:hover td { background: #1c2128; }
        td a { color: #58a6ff; text-decoration: none; }
        td a:hover { text-decoration: underline; }
        .price { color: #3fb950; font-weight: 600; }
        .badge { display: inline-block; padding: 2px 8px; border-radius: 10px; font-size: 12px; }
        .badge-zz { background: #1f6feb22; color: #58a6ff; border: 1px solid #1f6feb44; }
        .badge-ahs { background: #3fb95022; color: #3fb950; border: 1px solid #3fb95044; }
        .empty { text-align: center; padding: 60px 20px; color: #484f58; }
        .empty svg { width: 60px; height: 60px; margin-bottom: 15px; opacity: 0.3; }
        .footer { text-align: center; padding: 30px; color: #484f58; font-size: 12px; }
        @media (max-width: 600px) { .header h1 { font-size: 22px; } .stats { grid-template-columns: repeat(2, 1fr); } }
    </style>
</head>
<body>

<div class="header">
    <h1>📱 iOS 17.0 设备采集后台</h1>
    <p>自动从转转/爱回收采集 → 实时更新</p>
</div>

<div class="stats">
    <div class="stat">
        <div class="num"><?= $totalCount ?></div>
        <div class="label">采集总数</div>
    </div>
    <div class="stat">
        <div class="num">¥<?= $avgPrice ?></div>
        <div class="label">平均价格</div>
    </div>
    <div class="stat">
        <div class="num"><?= $sources['转转'] ?? 0 ?></div>
        <div class="label">转转来源</div>
    </div>
    <div class="stat">
        <div class="num"><?= $sources['爱回收'] ?? 0 ?></div>
        <div class="label">爱回收来源</div>
    </div>
</div>

<div class="container">
    <div class="model-tags">
        <span class="model-tag active" onclick="filterModel('all')">全部<span class="count"><?= $totalCount ?></span></span>
        <?php foreach (array_slice($models, 0, 12) as $m => $c): ?>
        <span class="model-tag" onclick="filterModel('<?= htmlspecialchars($m) ?>')"><?= htmlspecialchars($m) ?><span class="count"><?= $c ?></span></span>
        <?php endforeach; ?>
    </div>

    <div class="toolbar">
        <input type="text" id="search" placeholder="搜索机型/价格..." oninput="filterTable()">
        <button onclick="location.reload()">🔄 刷新</button>
        <span style="font-size:12px;color:#8b949e;display:flex;align-items:center">最近50条 (共<?= $totalCount ?>条)</span>
    </div>

    <?php if (empty($devices)): ?>
    <div class="empty">
        <div style="font-size:48px;margin-bottom:10px">📭</div>
        <p>暂无采集数据</p>
        <p style="font-size:12px;margin-top:8px">在转转/爱回收中搜索 iPhone，插件会自动采集 iOS 17.0 设备</p>
    </div>
    <?php else: ?>
    <table>
        <thead>
            <tr>
                <th style="width:40%">机型</th>
                <th style="width:12%">价格</th>
                <th style="width:12%">iOS</th>
                <th style="width:12%">来源</th>
                <th style="width:14%">时间</th>
                <th style="width:10%">操作</th>
            </tr>
        </thead>
        <tbody>
        <?php 
        $shown = array_slice($devices, 0, 50);
        foreach ($shown as $d): 
            $title = htmlspecialchars($d['title'] ?? '未知', ENT_QUOTES, 'UTF-8');
            $price = htmlspecialchars($d['price'] ?? '', ENT_QUOTES, 'UTF-8');
            $ios = htmlspecialchars($d['ios_ver'] ?? '17.0', ENT_QUOTES, 'UTF-8');
            $src = htmlspecialchars($d['source'] ?? '未知', ENT_QUOTES, 'UTF-8');
            $time = htmlspecialchars($d['time'] ?? '', ENT_QUOTES, 'UTF-8');
            $url = cleanUrl($d['url'] ?? '#');
            $ctx = htmlspecialchars(mb_substr($d['context'] ?? '', 0, 80), ENT_QUOTES, 'UTF-8');
            $srcBadge = $src === '转转' ? 'badge-zz' : 'badge-ahs';
        ?>
            <tr data-model="<?= htmlspecialchars($title) ?>">
                <td>
                    <div style="font-weight:500;margin-bottom:2px"><?= $title ?></div>
                    <div style="font-size:11px;color:#484f58" title="<?= htmlspecialchars($d['context'] ?? '') ?>"><?= $ctx ?: '—' ?></div>
                </td>
                <td class="price"><?= $price ? "¥$price" : '—' ?></td>
                <td><span class="badge badge-zz">iOS <?= $ios ?></span></td>
                <td><span class="badge <?= $srcBadge ?>"><?= $src ?></span></td>
                <td style="font-size:12px;color:#8b949e"><?= $time ?></td>
                <td><a href="<?= $url ?>" target="_blank" rel="noopener">查看详情</a></td>
            </tr>
        <?php endforeach; ?>
        </tbody>
    </table>
    <?php endif; ?>
</div>

<div class="footer">
    自动刷新: 每 60 秒 &nbsp;|&nbsp; 
    <a href="javascript:void(0)" onclick="location.href='?export=1'" style="color:#58a6ff">导出 JSON</a>
</div>

<script>
let activeModel = 'all';
function filterModel(m) {
    activeModel = m;
    document.querySelectorAll('.model-tag').forEach(t => t.classList.remove('active'));
    event.target.classList.add('active');
    filterTable();
}
function filterTable() {
    const search = document.getElementById('search').value.toLowerCase();
    document.querySelectorAll('tbody tr').forEach(tr => {
        const text = tr.textContent.toLowerCase();
        const model = tr.dataset.model.toLowerCase();
        const matchModel = activeModel === 'all' || model.includes(activeModel.toLowerCase());
        const matchSearch = !search || text.includes(search);
        tr.style.display = matchModel && matchSearch ? '' : 'none';
    });
}
// 自动刷新
setTimeout(() => location.reload(), 60000);
</script>

<?php
// 导出功能
if (isset($_GET['export'])) {
    header('Content-Type: application/json');
    header('Content-Disposition: attachment; filename="collected_' . date('Ymd_His') . '.json"');
    echo json_encode($devices, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT);
    exit;
}
?>
</body>
</html>
