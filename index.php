<?php
$configFile = __DIR__ . '/config.json';
$cfg = json_decode(file_exists($configFile) ? file_get_contents($configFile) : '{}', true) ?: [];
$th = $cfg['thresholds'] ?? ['lt'=>['enabled'=>true,'version'=>'17.0'],'eq'=>['enabled'=>true,'version'=>'17.0'],'gt'=>['enabled'=>false,'version'=>'17.0']];

// 保存设置
$saved = false;
if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['save'])) {
    foreach (['lt','eq','gt'] as $op) {
        $v = trim($_POST["ver_$op"] ?? '');
        if (preg_match('/^\d+\.\d+(\.\d+)?$/', $v)) $th[$op]['version'] = $v;
        $th[$op]['enabled'] = isset($_POST["en_$op"]);
    }
    $cfg['thresholds'] = $th;
    file_put_contents($configFile, json_encode($cfg, JSON_UNESCAPED_UNICODE|JSON_PRETTY_PRINT));
    $saved = true;
}

// 读取采集数据
$dataFile = __DIR__ . '/data/collected.json';
$devices = [];
if (file_exists($dataFile)) $devices = json_decode(file_get_contents($dataFile), true) ?: [];
$devices = array_reverse($devices);
$total = count($devices);

// 统计
$counts = ['lt'=>0,'eq'=>0,'gt'=>0,'API'=>0];
foreach ($devices as $d) {
    $v = $d['ios_ver'] ?? 'API';
    $op = $d['threshold_op'] ?? '';
    if (strpos($op, 'lt')===0) $counts['lt']++;
    elseif (strpos($op, 'eq')===0) $counts['eq']++;
    elseif (strpos($op, 'gt')===0) $counts['gt']++;
    else $counts['API']++;
}
?>
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>iOS设备采集后台</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#0f1117;color:#e1e4e8;padding:20px}
.header{text-align:center;padding:30px 0 20px}
.header h1{font-size:24px;background:linear-gradient(135deg,#667eea,#764ba2);-webkit-background-clip:text;-webkit-text-fill-color:transparent}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));gap:10px;max-width:700px;margin:0 auto 20px}
.stat{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:14px;text-align:center}
.stat .n{font-size:28px;font-weight:700;color:#58a6ff}
.stat .l{font-size:12px;color:#8b949e;margin-top:2px}
.card{max-width:700px;margin:0 auto 20px;background:#161b22;border:1px solid #30363d;border-radius:10px;padding:20px}
.card h3{font-size:16px;margin-bottom:14px;color:#e1e4e8}
.row{display:flex;align-items:center;gap:10px;margin-bottom:10px;flex-wrap:wrap}
.row label{width:60px;color:#8b949e;font-size:14px}
.row select,.row input{padding:6px 10px;border-radius:6px;border:1px solid #30363d;background:#0d1117;color:#e1e4e8;font-size:14px}
.row input[type=text]{width:70px;text-align:center}
.row .op{color:#58a6ff;font-weight:700;width:20px;text-align:center}
.toggle{position:relative;display:inline-block;width:44px;height:24px}
.toggle input{opacity:0;width:0;height:0}
.slider{position:absolute;cursor:pointer;top:0;left:0;right:0;bottom:0;background:#30363d;border-radius:12px;transition:.2s}
.slider:before{content:"";position:absolute;height:18px;width:18px;left:3px;bottom:3px;background:#8b949e;border-radius:50%;transition:.2s}
input:checked+.slider{background:#238636}
input:checked+.slider:before{transform:translateX(20px);background:#fff}
.btn{padding:8px 20px;border-radius:6px;border:none;background:#238636;color:#fff;font-size:14px;cursor:pointer}
.btn:hover{background:#2ea043}
.toast{color:#3fb950;font-size:13px;display:none}.toast.show{display:inline}
table{width:100%;border-collapse:collapse;background:#161b22;border:1px solid #30363d;border-radius:8px;overflow:hidden}
th,td{padding:10px 12px;text-align:left;border-bottom:1px solid #21262d;font-size:13px}
th{background:#21262d;color:#8b949e;font-weight:600}
tr:hover td{background:#1c2128}
td a{color:#58a6ff;text-decoration:none}
.b{display:inline-block;padding:2px 7px;border-radius:8px;font-size:11px}
.blt{background:#da363322;color:#f78166;border:1px solid #da363344}
.beq{background:#23863622;color:#3fb950;border:1px solid #23863644}
.bgt{background:#1f6feb22;color:#58a6ff;border:1px solid #1f6feb44}
.bapi{background:#6e768122;color:#8b949e;border:1px solid #6e768144}
.empty{text-align:center;padding:60px;color:#484f58}
</style>
</head>
<body>

<div class="header">
    <h1>📱 iOS 设备采集后台</h1>
</div>

<!-- 设置面板 -->
<div class="card">
    <h3>⚙️ 采集阈值设置</h3>
    <form method="post">
        <?php 
        $labels = ['lt'=>'&lt;','eq'=>'=','gt'=>'&gt;'];
        foreach (['lt','eq','gt'] as $op): 
            $en = $th[$op]['enabled'] ?? ($op !== 'gt');
            $ver = $th[$op]['version'] ?? '17.0';
        ?>
        <div class="row">
            <label class="toggle">
                <input type="checkbox" name="en_<?=$op?>" <?=$en?'checked':''?>>
                <span class="slider"></span>
            </label>
            <span class="op">iOS <?=$labels[$op]?></span>
            <input type="text" name="ver_<?=$op?>" value="<?=htmlspecialchars($ver)?>">
            <span style="font-size:12px;color:#8b949e">版本</span>
        </div>
        <?php endforeach; ?>
        <div style="margin-top:12px">
            <button class="btn" type="submit" name="save" value="1">💾 保存设置</button>
            <?php if($saved): ?><span class="toast show">✅ 已保存! 重启转转App生效</span><?php endif; ?>
            <span style="font-size:11px;color:#484f58;margin-left:10px">修改后需重启App</span>
        </div>
    </form>
</div>

<!-- 统计 -->
<div class="stats">
    <div class="stat"><div class="n"><?=$total?></div><div class="l">总数</div></div>
    <div class="stat"><div class="n" style="color:#f78166"><?=$counts['lt']?></div><div class="l">&lt;阈值</div></div>
    <div class="stat"><div class="n" style="color:#3fb950"><?=$counts['eq']?></div><div class="l">=阈值</div></div>
    <div class="stat"><div class="n" style="color:#58a6ff"><?=$counts['gt']?></div><div class="l">&gt;阈值</div></div>
</div>

<!-- 数据列表 -->
<div class="card">
    <?php if(empty($devices)): ?>
    <div class="empty">📭 暂无采集数据</div>
    <?php else: ?>
    <table>
        <thead><tr><th>机型</th><th>价格</th><th>iOS</th><th>阈值</th><th>来源</th><th>时间</th><th>操作</th></tr></thead>
        <tbody>
        <?php foreach(array_slice($devices,0,50) as $d):
            $v = $d['ios_ver'] ?? '?';
            $op = $d['threshold_op'] ?? '';
            $bc = strpos($op,'lt')===0?'blt':(strpos($op,'eq')===0?'beq':(strpos($op,'gt')===0?'bgt':'bapi'));
            $opLabel = strpos($op,'lt')===0?'&lt;':(strpos($op,'eq')===0?'=':(strpos($op,'gt')===0?'&gt;':'?'));
        ?>
        <tr>
            <td><strong><?=htmlspecialchars($d['title']??'?')?></strong></td>
            <td style="color:#3fb950"><?=($d['price']??'')?"¥{$d['price']}":'—'?></td>
            <td>iOS <?=htmlspecialchars($v)?></td>
            <td><span class="b <?=$bc?>"><?=$opLabel?></span></td>
            <td><?=htmlspecialchars($d['source']??'?')?></td>
            <td style="font-size:11px;color:#8b949e"><?=htmlspecialchars(substr($d['time']??'',5,11))?></td>
            <td><a href="<?=htmlspecialchars($d['url']??'#')?>" target="_blank">详情</a></td>
        </tr>
        <?php endforeach; ?>
        </tbody>
    </table>
    <?php endif; ?>
</div>

<script>setTimeout(function(){location.reload()},60000);</script>
</body>
</html>
