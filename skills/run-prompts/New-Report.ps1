<#
.SYNOPSIS
    Build the Arabic HTML report for a prompt set.

.DESCRIPTION
    DERIVED, never accumulated: everything comes from state\state.json and results\*.json, both of
    which are written after every prompt. So the report is regenerable at any moment and survives a
    run that was interrupted, killed, or failed half way - you get an honest report of the first
    seven steps rather than nothing at all.

    It answers the four questions a person actually has after handing work to an agent:
      1. what got done
      2. what did it decide on my behalf without asking, and what did it reject
      3. where was the prompt wrong, and what did it do instead
      4. what is still NOT proven
#>
[CmdletBinding()]
param(
    [string]$SetPath = '.',
    [string]$Out
)

$ErrorActionPreference = 'Stop'
$SetRoot = (Resolve-Path $SetPath).Path
$M = Import-PowerShellDataFile (Join-Path $SetRoot 'manifest.psd1')
if (-not $Out) { $Out = Join-Path $SetRoot 'report.html' }

$statePath = Join-Path $SetRoot 'state\state.json'
$state = if (Test-Path $statePath) { Get-Content -Raw $statePath | ConvertFrom-Json } else { $null }

function Esc([string]$s) {
    if ($null -eq $s) { return '' }
    [System.Net.WebUtility]::HtmlEncode($s)
}

$results = @{}
foreach ($f in Get-ChildItem (Join-Path $SetRoot 'results') -Filter '*.json' -ErrorAction SilentlyContinue) {
    try { $results[$f.BaseName] = Get-Content -Raw $f.FullName | ConvertFrom-Json }
    catch {
        # A malformed report is itself worth showing rather than hiding.
        $results[$f.BaseName] = [pscustomobject]@{ status = 'UNREADABLE'; summary = 'تقرير الجلسة غير قابل للقراءة (JSON غير صالح).' }
    }
}

$done = 0; $failed = 0; $waiting = 0; $pending = 0; $cost = 0.0
foreach ($p in $M.Prompts) {
    $st = if ($state -and $state.prompts.($p.Id)) { $state.prompts.($p.Id) } else { $null }
    switch ($st.status) {
        'DONE' { $done++ } 'FAILED' { $failed++ } 'AWAITING_SIGNOFF' { $waiting++ } default { $pending++ }
    }
    if ($st.costUsd) { $cost += $st.costUsd }
}

$statusWord = @{
    DONE             = 'مكتمل'
    FAILED           = 'فشل'
    AWAITING_SIGNOFF = 'بانتظار توقيعك'
    RUNNING          = 'قيد التنفيذ'
    PENDING          = 'لم يبدأ'
}

$sb = New-Object System.Text.StringBuilder
$null = $sb.AppendLine(@"
<!doctype html>
<html lang="ar" dir="rtl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>تقرير: $(Esc $M.Name)</title>
<style>
  :root{
    --bg:#f6f7f9; --card:#fff; --ink:#16191d; --muted:#5c6570; --line:#e3e6ea;
    --ok:#1a7f4b; --okbg:#e8f5ee; --bad:#b3261e; --badbg:#fdecea;
    --warn:#8a6100; --warnbg:#fff4d6; --idle:#5c6570; --idlebg:#eef0f2; --accent:#1b4fd8;
  }
  @media (prefers-color-scheme:dark){
    :root:not([data-theme="light"]){
      --bg:#0f1216; --card:#171b21; --ink:#e8eaed; --muted:#9aa4b1; --line:#272d36;
      --ok:#5cd394; --okbg:#123024; --bad:#ff8a80; --badbg:#3a1512;
      --warn:#ffcf5c; --warnbg:#3a2e0c; --idle:#9aa4b1; --idlebg:#20262e; --accent:#8fb0ff;
    }
  }
  *{box-sizing:border-box}
  body{margin:0;padding:32px 20px 72px;background:var(--bg);color:var(--ink);
       font:16px/1.75 "Segoe UI","Noto Naskh Arabic",Tahoma,system-ui,sans-serif}
  .wrap{max-width:980px;margin:0 auto}
  h1{font-size:30px;margin:0 0 4px}
  h2{font-size:21px;margin:44px 0 14px;padding-bottom:8px;border-bottom:2px solid var(--line)}
  .sub{color:var(--muted);margin:0 0 26px}
  .cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin:22px 0 8px}
  .card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px 18px}
  .card .n{font-size:30px;font-weight:700;line-height:1.2}
  .card .l{color:var(--muted);font-size:14px}
  .pill{display:inline-block;padding:2px 11px;border-radius:999px;font-size:13px;font-weight:600;white-space:nowrap}
  .s-DONE{background:var(--okbg);color:var(--ok)}
  .s-FAILED{background:var(--badbg);color:var(--bad)}
  .s-AWAITING_SIGNOFF{background:var(--warnbg);color:var(--warn)}
  .s-PENDING,.s-RUNNING{background:var(--idlebg);color:var(--idle)}
  table{width:100%;border-collapse:collapse;background:var(--card);
        border:1px solid var(--line);border-radius:12px;overflow:hidden}
  th,td{padding:11px 14px;text-align:right;border-bottom:1px solid var(--line);vertical-align:top}
  th{background:var(--idlebg);font-size:14px;color:var(--muted);font-weight:600}
  tr:last-child td{border-bottom:0}
  code{font-family:"Cascadia Mono",Consolas,monospace;font-size:13px;
       background:var(--idlebg);padding:1px 6px;border-radius:5px;direction:ltr;display:inline-block}
  .item{background:var(--card);border:1px solid var(--line);border-left:4px solid var(--accent);
        border-radius:10px;padding:13px 16px;margin:9px 0}
  .item.warn{border-left-color:var(--warn)}
  .item.bad{border-left-color:var(--bad)}
  .item .id{font-size:12px;color:var(--muted);font-weight:700;letter-spacing:.4px}
  .en{direction:ltr;text-align:left;unicode-bidi:isolate}
  .note{background:var(--warnbg);color:var(--warn);border-radius:10px;padding:14px 18px;margin:18px 0;font-weight:600}
  .foot{color:var(--muted);font-size:13px;margin-top:56px;border-top:1px solid var(--line);padding-top:16px}
  details{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:10px 16px;margin:9px 0}
  summary{cursor:pointer;font-weight:600}
</style>
</head>
<body><div class="wrap">
<h1>تقرير التنفيذ — $(Esc $M.Name)</h1>
<p class="sub">وُلِّد في $(Get-Date -Format 'yyyy-MM-dd HH:mm') · $($M.Prompts.Count) خطوة</p>
"@)

if ($failed -gt 0) {
    $null = $sb.AppendLine('<div class="note">توقّف التنفيذ عند خطوة فاشلة. لا شيء بعدها نُفِّذ، لأن ما يليها يعتمد عليها.</div>')
}
elseif ($waiting -gt 0) {
    $null = $sb.AppendLine('<div class="note">التنفيذ متوقّف بانتظار توقيعك على خطوة يحتاج قبولها إلى شخص.</div>')
}
elseif ($pending -gt 0) {
    $null = $sb.AppendLine('<div class="note">هذا تقرير جزئي: التنفيذ لم يبلغ نهايته بعد.</div>')
}

$null = $sb.AppendLine(@"
<div class="cards">
  <div class="card"><div class="n">$done</div><div class="l">مكتمل</div></div>
  <div class="card"><div class="n">$waiting</div><div class="l">بانتظار توقيعك</div></div>
  <div class="card"><div class="n">$failed</div><div class="l">فشل</div></div>
  <div class="card"><div class="n">$pending</div><div class="l">لم يبدأ</div></div>
  <div class="card"><div class="n">$([Math]::Round($cost,2))$</div><div class="l">كلفة الجلسات</div></div>
</div>
"@)

# ---- ledger
$null = $sb.AppendLine('<h2>الخطوات</h2><table><tr><th>#</th><th>الحالة</th><th>الخطوة</th><th>ما جرى</th><th>commit</th></tr>')
$i = 0
foreach ($p in $M.Prompts) {
    $i++
    $st = if ($state -and $state.prompts.($p.Id)) { $state.prompts.($p.Id) } else { $null }
    $s = if ($st.status) { $st.status } else { 'PENDING' }
    $word = if ($statusWord[$s]) { $statusWord[$s] } else { $s }
    $r = $results[$p.Id]
    $sha = if ($st.commit) { '<code>' + $st.commit.Substring(0,8) + '</code>' } else { '—' }
    $summary = if ($r.summary) { Esc ($r.summary.Substring(0, [Math]::Min(320, $r.summary.Length))) } else { '' }
    $null = $sb.AppendLine("<tr><td>$i</td><td><span class=""pill s-$s"">$word</span></td>" +
        "<td><strong>$(Esc $p.Id)</strong><br><span class=""en"">$(Esc $p.Title)</span></td>" +
        "<td class=""en"">$summary</td><td>$sha</td></tr>")
}
$null = $sb.AppendLine('</table>')

# ---- decisions taken without asking
$anyDecisions = $false
$decBlock = New-Object System.Text.StringBuilder
foreach ($p in $M.Prompts) {
    $r = $results[$p.Id]
    foreach ($d in @($r.decisions)) {
        if (-not $d) { continue }
        $anyDecisions = $true
        $null = $decBlock.AppendLine("<div class=""item""><div class=""id"">$(Esc $p.Id)</div><div class=""en"">$(Esc $d)</div></div>")
    }
}
$null = $sb.AppendLine('<h2>قرارات اتُّخذت نيابةً عنك</h2>')
if ($anyDecisions) {
    $null = $sb.AppendLine('<p class="sub">هذه قرارات لم تُطرح عليك أثناء التنفيذ لأنها قابلة للتراجع ولا تُغيّر شكل المُنتَج. كلٌّ منها يذكر البديل الذي لم يُؤخذ — راجعها، وأي واحد منها قابل للعكس الآن.</p>')
    $null = $sb.Append($decBlock.ToString())
}
else { $null = $sb.AppendLine('<p class="sub">لا شيء — لم تُتَّخذ قرارات خارج ما نصّت عليه الخطوات.</p>') }

# ---- deviations: where the prompt was wrong
$anyDev = $false
$devBlock = New-Object System.Text.StringBuilder
foreach ($p in $M.Prompts) {
    $r = $results[$p.Id]
    foreach ($d in @($r.deviations)) {
        if (-not $d) { continue }
        $anyDev = $true
        $null = $devBlock.AppendLine("<div class=""item warn""><div class=""id"">$(Esc $p.Id)</div><div class=""en"">$(Esc $d)</div></div>")
    }
}
$null = $sb.AppendLine('<h2>مواضع خالف فيها الواقعُ البرومبت</h2>')
if ($anyDev) {
    $null = $sb.AppendLine('<p class="sub">البرومبتات كُتبت دون قراءة كل ملف، فبعض تفاصيلها كان فرضيةً لا حقيقة. هنا ما وجدته الجلسات مخالفاً، وما فعلته بدلاً منه.</p>')
    $null = $sb.Append($devBlock.ToString())
}
else { $null = $sb.AppendLine('<p class="sub">لا شيء — لم تصطدم أي جلسة بخطأ في برومبتها.</p>') }

# ---- unverified
$anyUnv = $false
$unvBlock = New-Object System.Text.StringBuilder
foreach ($p in $M.Prompts) {
    $r = $results[$p.Id]
    foreach ($u in @($r.unverified)) {
        if (-not $u) { continue }
        $anyUnv = $true
        $null = $unvBlock.AppendLine("<div class=""item bad""><div class=""id"">$(Esc $p.Id)</div><div class=""en"">$(Esc $u)</div></div>")
    }
}
$null = $sb.AppendLine('<h2>ما لم يُثبَت</h2>')
if ($anyUnv) {
    $null = $sb.AppendLine('<p class="sub">كل جلسة مُلزَمة بأن تُصرّح بما عجزت عن إثباته. لا شيء ممّا هنا محسوبٌ منجزاً، وهو أصدق قسم في التقرير.</p>')
    $null = $sb.Append($unvBlock.ToString())
}
else { $null = $sb.AppendLine('<p class="sub">لا شيء — كل ما طُلب أُثبت.</p>') }

# ---- followups
$anyFu = $false
$fuBlock = New-Object System.Text.StringBuilder
foreach ($p in $M.Prompts) {
    $r = $results[$p.Id]
    foreach ($f in @($r.followups)) {
        if (-not $f) { continue }
        $anyFu = $true
        $null = $fuBlock.AppendLine("<div class=""item""><div class=""id"">$(Esc $p.Id)</div><div class=""en"">$(Esc $f)</div></div>")
    }
}
if ($anyFu) {
    $null = $sb.AppendLine('<h2>خيارات وأعمال لاحقة</h2>')
    $null = $sb.AppendLine('<p class="sub">أمور لاحظتها الجلسات وتركتها عمداً خارج نطاقها. لا شيء منها عاجل.</p>')
    $null = $sb.Append($fuBlock.ToString())
}

# ---- per-step detail
$null = $sb.AppendLine('<h2>تفصيل كل خطوة</h2>')
foreach ($p in $M.Prompts) {
    $r = $results[$p.Id]
    if (-not $r) { continue }
    $st = if ($state -and $state.prompts.($p.Id)) { $state.prompts.($p.Id) } else { $null }
    $meta = @()
    if ($st.model) { $meta += "الموديل: $($st.model)" }
    if ($st.attempts) { $meta += "المحاولات: $($st.attempts)" }
    if ($st.costUsd) { $meta += ('الكلفة: ${0:N2}' -f $st.costUsd) }
    if ($st.sessionId) { $meta += "الجلسة: <code>$($st.sessionId)</code>" }
    $null = $sb.AppendLine("<details><summary>$(Esc $p.Id) — $(Esc $p.Title)</summary>")
    $null = $sb.AppendLine("<p class=""sub"">$($meta -join ' · ')</p>")
    if ($r.summary) { $null = $sb.AppendLine("<p class=""en"">$(Esc $r.summary)</p>") }
    if (@($r.verification_performed).Count) {
        $null = $sb.AppendLine('<p><strong>ما جرى التحقّق منه:</strong></p><ul class="en">')
        foreach ($v in @($r.verification_performed)) { if ($v) { $null = $sb.AppendLine("<li>$(Esc $v)</li>") } }
        $null = $sb.AppendLine('</ul>')
    }
    if (@($r.changed_files).Count) {
        $null = $sb.AppendLine('<p><strong>الملفّات:</strong></p><ul class="en">')
        foreach ($c in @($r.changed_files)) { if ($c) { $null = $sb.AppendLine("<li><code>$(Esc $c)</code></li>") } }
        $null = $sb.AppendLine('</ul>')
    }
    $null = $sb.AppendLine('</details>')
}

$null = $sb.AppendLine(@"
<p class="foot">وُلِّد هذا التقرير من <code>state/state.json</code> و<code>results/*.json</code>، وكلاهما يُكتب بعد كل خطوة —
فيمكن توليده في أي لحظة، ويبقى صادقاً حتى لو توقّف التنفيذ في منتصفه.<br>
لإعادة توليده: <code>Run-Prompts.ps1 -Report</code></p>
</div></body></html>
"@)

Set-Content -Path $Out -Value $sb.ToString() -Encoding UTF8
Write-Output $Out
