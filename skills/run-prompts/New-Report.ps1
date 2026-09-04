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

# ---------------------------------------------------------------- bilingual
#
# The sessions write English; a reader may want Arabic. A results file MAY carry
# a parallel `<field>_ar` beside any translatable field - a string for `summary`
# and `title`, an index-aligned array for the list fields. Everything below falls
# back to the English alone when the translation is missing, so a set that has
# never been translated renders exactly as it did before.

function ArOf($r, [string]$field) {
    if (-not $r) { return $null }
    $v = $r.PSObject.Properties[$field + '_ar']
    if ($v) { return $v.Value }
    return $null
}

function ArAt($r, [string]$field, [int]$i) {
    $arr = @(ArOf $r $field)
    if ($arr.Count -gt $i -and $arr[$i]) { return [string]$arr[$i] }
    return $null
}

# One content item in both languages. Only the active one is displayed - EXCEPT
# when there is no translation, where the English is marked `keep` and stays
# visible in both modes. Without that, a set that has never been translated would
# render an empty box for every item the moment the reader switched to Arabic.
function Bi([string]$en, [string]$ar) {
    if (-not $ar) { return "<div class=""en keep"">$(Esc $en)</div>" }
    "<div class=""en"">$(Esc $en)</div><div class=""ar"">$(Esc $ar)</div>"
}

# UI chrome in both languages, switched by the same control as the content.
function T([string]$ar, [string]$en) {
    "<span class=""ar"">$ar</span><span class=""en"">$(Esc $en)</span>"
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
$statusWordEn = @{
    DONE             = 'done'
    FAILED           = 'failed'
    AWAITING_SIGNOFF = 'awaiting your sign-off'
    RUNNING          = 'running'
    PENDING          = 'not started'
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
  .ar{direction:rtl;text-align:right;unicode-bidi:isolate}
  /* One switch drives the whole document: chrome and content alike. */
  body[data-lang="ar"] .en{display:none}
  body[data-lang="en"] .ar{display:none}
  /* Untranslated content: visible whichever language is selected. */
  body[data-lang="ar"] .en.keep{display:revert}
  th .en,th .ar,.pill .en,.pill .ar,.card .l .en,.card .l .ar,
  summary .en,summary .ar,h1 .en,h1 .ar,h2 .en,h2 .ar{display:inline}
  body[data-lang="ar"] th .en,body[data-lang="ar"] .pill .en,body[data-lang="ar"] .card .l .en,
  body[data-lang="ar"] summary .en,body[data-lang="ar"] h1 .en,body[data-lang="ar"] h2 .en{display:none}
  body[data-lang="en"] th .ar,body[data-lang="en"] .pill .ar,body[data-lang="en"] .card .l .ar,
  body[data-lang="en"] summary .ar,body[data-lang="en"] h1 .ar,body[data-lang="en"] h2 .ar{display:none}
  .langbar{display:flex;gap:8px;align-items:center;margin:0 0 18px}
  .langbtn{cursor:pointer;border:1px solid var(--line);background:var(--card);color:var(--muted);
           border-radius:999px;padding:6px 16px;font:inherit;font-size:14px;font-weight:600}
  .langbtn[aria-pressed="true"]{background:var(--accent);color:#fff;border-color:var(--accent)}
  body[data-lang="en"]{direction:ltr}
  body[data-lang="en"] .wrap{text-align:left}
  body[data-lang="en"] th,body[data-lang="en"] td{text-align:left}
  .note{background:var(--warnbg);color:var(--warn);border-radius:10px;padding:14px 18px;margin:18px 0;font-weight:600}
  .foot{color:var(--muted);font-size:13px;margin-top:56px;border-top:1px solid var(--line);padding-top:16px}
  details{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:10px 16px;margin:9px 0}
  summary{cursor:pointer;font-weight:600}
</style>
</head>
<body data-lang="ar"><div class="wrap">
<div class="langbar">
  <button class="langbtn" id="btn-ar" aria-pressed="true"  onclick="setLang('ar')">العربية</button>
  <button class="langbtn" id="btn-en" aria-pressed="false" onclick="setLang('en')">English</button>
</div>
<h1>$(T 'تقرير التنفيذ' 'Run report') — $(Esc $M.Name)</h1>
<p class="sub">$(T "وُلِّد في $(Get-Date -Format 'yyyy-MM-dd HH:mm') · $($M.Prompts.Count) خطوة" "Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') · $($M.Prompts.Count) steps")</p>
<script>
function setLang(l){
  document.body.dataset.lang = l;
  document.documentElement.lang = l;
  document.documentElement.dir = (l === 'ar') ? 'rtl' : 'ltr';
  document.getElementById('btn-ar').setAttribute('aria-pressed', String(l === 'ar'));
  document.getElementById('btn-en').setAttribute('aria-pressed', String(l === 'en'));
  try { localStorage.setItem('apa-report-lang', l); } catch (e) { /* private mode */ }
}
try {
  var saved = localStorage.getItem('apa-report-lang');
  if (saved === 'en' || saved === 'ar') { setLang(saved); }
} catch (e) { /* private mode: stay on the default */ }
</script>
"@)

if ($failed -gt 0) {
    $null = $sb.AppendLine('<div class="note">' + (T 'توقّف التنفيذ عند خطوة فاشلة. لا شيء بعدها نُفِّذ، لأن ما يليها يعتمد عليها.' 'The run stopped at a failed step. Nothing after it ran, because the chain depends on it.') + '</div>')
}
elseif ($waiting -gt 0) {
    $null = $sb.AppendLine('<div class="note">' + (T 'التنفيذ متوقّف بانتظار توقيعك على خطوة يحتاج قبولها إلى شخص.' 'The run is paused for your sign-off on a step that needs a person to accept it.') + '</div>')
}
elseif ($pending -gt 0) {
    $null = $sb.AppendLine('<div class="note">' + (T 'هذا تقرير جزئي: التنفيذ لم يبلغ نهايته بعد.' 'This is a partial report: the run has not reached its end yet.') + '</div>')
}

$null = $sb.AppendLine(@"
<div class="cards">
  <div class="card"><div class="n">$done</div><div class="l">$(T 'مكتمل' 'done')</div></div>
  <div class="card"><div class="n">$waiting</div><div class="l">$(T 'بانتظار توقيعك' 'awaiting sign-off')</div></div>
  <div class="card"><div class="n">$failed</div><div class="l">$(T 'فشل' 'failed')</div></div>
  <div class="card"><div class="n">$pending</div><div class="l">$(T 'لم يبدأ' 'not started')</div></div>
  <div class="card"><div class="n">$([Math]::Round($cost,2))$</div><div class="l">$(T 'كلفة الجلسات' 'session cost')</div></div>
</div>
"@)

# The sections below summarise what each STEP reported. The orchestrator driving the run also makes
# calls of its own - correcting a gate that asserts the wrong thing, signing off a stop on partial
# evidence, landing a defect fix beside the prompt commits - and those belong in the same lists, not
# only in a chat transcript the user never sees. An optional results/_orchestrator.json, in the same
# shape as a step's result file, is folded in under its own id. The numbered ledger above stays
# $M.Prompts alone: the orchestrator is not a step. A set without that file renders as before.
$aggEntries = @($M.Prompts)
if ($results.ContainsKey('_orchestrator')) {
    $aggEntries += [pscustomobject]@{ Id = '_orchestrator'; Title = 'the orchestrator, not a prompt' }
}

# ---- ledger
$null = $sb.AppendLine('<h2>' + (T 'الخطوات' 'Steps') + '</h2><table><tr><th>#</th><th>' + (T 'الحالة' 'status') + '</th><th>' + (T 'الخطوة' 'step') + '</th><th>' + (T 'ما جرى' 'what happened') + '</th><th>commit</th></tr>')
$i = 0
foreach ($p in $M.Prompts) {
    $i++
    $st = if ($state -and $state.prompts.($p.Id)) { $state.prompts.($p.Id) } else { $null }
    $s = if ($st.status) { $st.status } else { 'PENDING' }
    $wordAr = if ($statusWord[$s]) { $statusWord[$s] } else { $s }
    $wordEn = if ($statusWordEn[$s]) { $statusWordEn[$s] } else { $s }
    $word = T $wordAr $wordEn
    $r = $results[$p.Id]
    $sha = if ($st.commit) { '<code>' + $st.commit.Substring(0,8) + '</code>' } else { '—' }
    $sumEn = if ($r.summary) { $r.summary.Substring(0, [Math]::Min(320, $r.summary.Length)) } else { '' }
    $sumArFull = [string](ArOf $r 'summary')
    $sumAr = if ($sumArFull) { $sumArFull.Substring(0, [Math]::Min(320, $sumArFull.Length)) } else { $null }
    $titleAr = [string](ArOf $r 'title')
    $titleCell = if ($titleAr) { "<span class=""en"">$(Esc $p.Title)</span><span class=""ar"">$(Esc $titleAr)</span>" }
                 else { "<span class=""en keep"">$(Esc $p.Title)</span>" }
    $null = $sb.AppendLine("<tr><td>$i</td><td><span class=""pill s-$s"">$word</span></td>" +
        "<td><strong>$(Esc $p.Id)</strong><br>$titleCell</td>" +
        "<td>$(Bi $sumEn $sumAr)</td><td>$sha</td></tr>")
}
$null = $sb.AppendLine('</table>')

# ---- decisions taken without asking
$anyDecisions = $false
$decBlock = New-Object System.Text.StringBuilder
foreach ($p in $aggEntries) {
    $r = $results[$p.Id]
    $k = -1
    foreach ($d in @($r.decisions)) {
        $k++
        if (-not $d) { continue }
        $anyDecisions = $true
        $null = $decBlock.AppendLine("<div class=""item""><div class=""id"">$(Esc $p.Id)</div>$(Bi $d (ArAt $r 'decisions' $k))</div>")
    }
}
$null = $sb.AppendLine('<h2>' + (T 'قرارات اتُّخذت نيابةً عنك' 'Decisions taken on your behalf') + '</h2>')
if ($anyDecisions) {
    $null = $sb.AppendLine('<p class="sub">' + (T 'هذه قرارات لم تُطرح عليك أثناء التنفيذ لأنها قابلة للتراجع ولا تُغيّر شكل المُنتَج. كلٌّ منها يذكر البديل الذي لم يُؤخذ — راجعها، وأي واحد منها قابل للعكس الآن.' 'These were not put to you during the run because each is reversible and none changes the shape of the deliverable. Every one names the alternative that was rejected - review them; any of them can still be undone.') + '</p>')
    $null = $sb.Append($decBlock.ToString())
}
else { $null = $sb.AppendLine('<p class="sub">' + (T 'لا شيء — لم تُتَّخذ قرارات خارج ما نصّت عليه الخطوات.' 'Nothing - no decision was taken beyond what the steps specified.') + '</p>') }

# ---- deviations: where the prompt was wrong
$anyDev = $false
$devBlock = New-Object System.Text.StringBuilder
foreach ($p in $aggEntries) {
    $r = $results[$p.Id]
    $k = -1
    foreach ($d in @($r.deviations)) {
        $k++
        if (-not $d) { continue }
        $anyDev = $true
        $null = $devBlock.AppendLine("<div class=""item warn""><div class=""id"">$(Esc $p.Id)</div>$(Bi $d (ArAt $r 'deviations' $k))</div>")
    }
}
$null = $sb.AppendLine('<h2>' + (T 'مواضع خالف فيها الواقعُ البرومبت' 'Where reality contradicted the prompt') + '</h2>')
if ($anyDev) {
    $null = $sb.AppendLine('<p class="sub">' + (T 'البرومبتات كُتبت دون قراءة كل ملف، فبعض تفاصيلها كان فرضيةً لا حقيقة. هنا ما وجدته الجلسات مخالفاً، وما فعلته بدلاً منه.' 'The prompts were written without reading every file, so some of their detail was hypothesis rather than fact. Here is what the sessions found to be otherwise, and what they did instead.') + '</p>')
    $null = $sb.Append($devBlock.ToString())
}
else { $null = $sb.AppendLine('<p class="sub">' + (T 'لا شيء — لم تصطدم أي جلسة بخطأ في برومبتها.' 'Nothing - no session hit an error in its own prompt.') + '</p>') }

# ---- unverified
$anyUnv = $false
$unvBlock = New-Object System.Text.StringBuilder
foreach ($p in $aggEntries) {
    $r = $results[$p.Id]
    $k = -1
    foreach ($u in @($r.unverified)) {
        $k++
        if (-not $u) { continue }
        $anyUnv = $true
        $null = $unvBlock.AppendLine("<div class=""item bad""><div class=""id"">$(Esc $p.Id)</div>$(Bi $u (ArAt $r 'unverified' $k))</div>")
    }
}
$null = $sb.AppendLine('<h2>' + (T 'ما لم يُثبَت' 'What was not proven') + '</h2>')
if ($anyUnv) {
    $null = $sb.AppendLine('<p class="sub">' + (T 'كل جلسة مُلزَمة بأن تُصرّح بما عجزت عن إثباته. لا شيء ممّا هنا محسوبٌ منجزاً، وهو أصدق قسم في التقرير.' 'Every session is required to declare what it could not prove. Nothing here counts as done, and this is the most honest section of the report.') + '</p>')
    $null = $sb.Append($unvBlock.ToString())
}
else { $null = $sb.AppendLine('<p class="sub">' + (T 'لا شيء — كل ما طُلب أُثبت.' 'Nothing - everything asked for was proven.') + '</p>') }

# ---- followups
$anyFu = $false
$fuBlock = New-Object System.Text.StringBuilder
foreach ($p in $aggEntries) {
    $r = $results[$p.Id]
    $k = -1
    foreach ($f in @($r.followups)) {
        $k++
        if (-not $f) { continue }
        $anyFu = $true
        $null = $fuBlock.AppendLine("<div class=""item""><div class=""id"">$(Esc $p.Id)</div>$(Bi $f (ArAt $r 'followups' $k))</div>")
    }
}
if ($anyFu) {
    $null = $sb.AppendLine('<h2>' + (T 'خيارات وأعمال لاحقة' 'Options and later work') + '</h2>')
    $null = $sb.AppendLine('<p class="sub">' + (T 'أمور لاحظتها الجلسات وتركتها عمداً خارج نطاقها. لا شيء منها عاجل.' 'Things the sessions noticed and deliberately left out of scope. None of it is urgent.') + '</p>')
    $null = $sb.Append($fuBlock.ToString())
}

# ---- per-step detail
$null = $sb.AppendLine('<h2>' + (T 'تفصيل كل خطوة' 'Step by step') + '</h2>')
foreach ($p in $aggEntries) {
    $r = $results[$p.Id]
    if (-not $r) { continue }
    $st = if ($state -and $state.prompts.($p.Id)) { $state.prompts.($p.Id) } else { $null }
    $meta = @()
    if ($st.model) { $meta += (T "الموديل: $($st.model)" "model: $($st.model)") }
    if ($st.attempts) { $meta += (T "المحاولات: $($st.attempts)" "attempts: $($st.attempts)") }
    if ($st.costUsd) { $meta += (T ('الكلفة: ${0:N2}' -f $st.costUsd) ('cost: ${0:N2}' -f $st.costUsd)) }
    if ($st.sessionId) { $meta += (T "الجلسة: <code>$($st.sessionId)</code>" "session: <code>$($st.sessionId)</code>") }
    $tAr = [string](ArOf $r 'title')
    $sumTitle = if ($tAr) { "<span class=""en"">$(Esc $p.Title)</span><span class=""ar"">$(Esc $tAr)</span>" }
                else { "<span class=""en keep"">$(Esc $p.Title)</span>" }
    $null = $sb.AppendLine("<details><summary>$(Esc $p.Id) — $sumTitle</summary>")
    $null = $sb.AppendLine("<p class=""sub"">$($meta -join ' · ')</p>")
    if ($r.summary) { $null = $sb.AppendLine((Bi $r.summary ([string](ArOf $r 'summary')))) }
    if (@($r.verification_performed).Count) {
        $null = $sb.AppendLine('<p><strong>' + (T 'ما جرى التحقّق منه:' 'What was actually verified:') + '</strong></p>')
        # @($null).Count is 1, not 0 - filtering the empties is what makes the
        # "is there a translation" test actually mean that.
        $vAr = @(@(ArOf $r 'verification_performed') | Where-Object { $_ })
        $null = $sb.AppendLine($(if ($vAr.Count) { '<ul class="en">' } else { '<ul class="en keep">' }))
        foreach ($v in @($r.verification_performed)) { if ($v) { $null = $sb.AppendLine("<li>$(Esc $v)</li>") } }
        $null = $sb.AppendLine('</ul>')
        if ($vAr.Count) {
            $null = $sb.AppendLine('<ul class="ar">')
            foreach ($v in @(ArOf $r 'verification_performed')) { if ($v) { $null = $sb.AppendLine("<li>$(Esc $v)</li>") } }
            $null = $sb.AppendLine('</ul>')
        }
    }
    if (@($r.changed_files).Count) {
        $null = $sb.AppendLine('<p><strong>' + (T 'الملفّات:' 'Files:') + '</strong></p><ul class="en keep">')
        foreach ($c in @($r.changed_files)) { if ($c) { $null = $sb.AppendLine("<li><code>$(Esc $c)</code></li>") } }
        $null = $sb.AppendLine('</ul>')
    }
    $null = $sb.AppendLine('</details>')
}

$null = $sb.AppendLine(@"
<p class="foot"><span class="ar">وُلِّد هذا التقرير من <code>state/state.json</code> و<code>results/*.json</code>، وكلاهما يُكتب بعد كل خطوة —
فيمكن توليده في أي لحظة، ويبقى صادقاً حتى لو توقّف التنفيذ في منتصفه.<br>
لإعادة توليده: <code>Run-Prompts.ps1 -Report</code></span><span class="en">Derived from <code>state/state.json</code> and <code>results/*.json</code>, both written after every step, so it can be regenerated at any moment and stays honest even if the run stopped half way.<br>
To regenerate: <code>Run-Prompts.ps1 -Report</code></span></p>
</div></body></html>
"@)

Set-Content -Path $Out -Value $sb.ToString() -Encoding UTF8
Write-Output $Out
