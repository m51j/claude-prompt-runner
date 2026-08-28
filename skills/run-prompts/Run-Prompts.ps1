<#
.SYNOPSIS
    Run a numbered prompt set, one fresh `claude -p` session per prompt, gated and committed.

.DESCRIPTION
    The engine. It knows nothing about any particular project - everything project-specific lives
    in manifest.psd1 beside the prompts.

    Per prompt:
      1. record the repo's HEAD as the rollback point
      2. pipe the prompt file into a NEW session (--session-id), cwd = the repo the manifest names,
         every other repo attached with --add-dir for reference
      3. run the manifest's gates OURSELVES - so a session that overstates its success is caught
         rather than believed
      4. green -> commit + tag; red -> one retry session fed the verbatim failure, then
         `git reset --hard` back to the rollback point and stop
      5. tiers that need a person stop for sign-off after their machine gates pass

.EXAMPLE
    .\Run-Prompts.ps1 -Preflight
    .\Run-Prompts.ps1 -DryRun
    .\Run-Prompts.ps1 -Only P01
    .\Run-Prompts.ps1
    .\Run-Prompts.ps1 -Signoff P05 -Result pass
    .\Run-Prompts.ps1 -Status
    .\Run-Prompts.ps1 -Report
#>
[CmdletBinding()]
param(
    # Folder holding manifest.psd1 (defaults to the current directory).
    [string]$SetPath = '.',

    [switch]$Preflight,
    [Alias('WhatIf')][switch]$DryRun,
    [switch]$Status,
    [switch]$Report,
    [string]$Only,
    [string]$From,
    [string]$To,
    [string]$Signoff,
    [ValidateSet('pass', 'fail')][string]$Result = 'pass',
    [switch]$NoCommit,
    [switch]$Force,
    [int]$MaxAttempts = 2
)

$ErrorActionPreference = 'Stop'
$SkillDir    = $PSScriptRoot
$SetRoot     = (Resolve-Path $SetPath).Path
$ManifestPath = Join-Path $SetRoot 'manifest.psd1'
if (-not (Test-Path $ManifestPath)) { throw "no manifest.psd1 in $SetRoot" }

$M = Import-PowerShellDataFile $ManifestPath

$PromptsDir = if ($M.PromptsDir) { Join-Path $SetRoot $M.PromptsDir } else { Join-Path $SetRoot 'prompts' }
$StateFile  = Join-Path $SetRoot 'state\state.json'
$ResultsDir = Join-Path $SetRoot 'results'
$LogsDir    = Join-Path $SetRoot 'logs'
$SmokeScript = Join-Path $SkillDir 'App-Smoke.ps1'

foreach ($d in @((Split-Path -Parent $StateFile), $ResultsDir, $LogsDir)) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

$PrimaryRepo = if ($M.PrimaryRepo) { $M.PrimaryRepo } else { ($M.Repos.Keys | Select-Object -First 1) }

# The set's own folder usually lives inside the repo being changed. Its state/logs/results are run
# artifacts, so they never count as a dirty tree and are never swept into a prompt's commit.
$SetPathspec = $null
$PrimaryPath = $M.Repos[$PrimaryRepo]
if ($SetRoot.StartsWith($PrimaryPath, [StringComparison]::OrdinalIgnoreCase)) {
    $SetPathspec = $SetRoot.Substring($PrimaryPath.Length).TrimStart('\', '/').Replace('\', '/')
}

# ---------------------------------------------------------------- console

function Say([string]$text, [string]$colour = 'Gray') { Write-Host $text -ForegroundColor $colour }
function Rule([string]$text) {
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
    Write-Host $text -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
}

# ---------------------------------------------------------------- state

function Get-State {
    if (Test-Path $StateFile) { return Get-Content -Raw $StateFile | ConvertFrom-Json -AsHashtable }
    return @{ started = (Get-Date).ToString('o'); name = $M.Name; branch = $M.Branch; prompts = @{} }
}
function Save-State($state) { $state | ConvertTo-Json -Depth 8 | Set-Content -Path $StateFile -Encoding UTF8 }
function Get-PromptState($state, [string]$id) {
    if (-not $state.prompts.ContainsKey($id)) { $state.prompts[$id] = @{ status = 'PENDING'; attempts = 0 } }
    return $state.prompts[$id]
}

# ---------------------------------------------------------------- git

# NOTE: this is an advanced function, so PowerShell tries to bind every leading-dash token as a
# parameter name before the remaining-arguments catch-all. A git short flag that prefix-matches a
# common parameter is a silent trap - `-e` is ambiguous between -ErrorAction and -ErrorVariable and
# throws instead of reaching git. When a flag is ambiguous, bind the array explicitly:
#   Invoke-Git -RepoPath $x -GitArgs @('clean','-fd','-e','some/path')
function Invoke-Git {
    param([string]$RepoPath, [Parameter(ValueFromRemainingArguments)][string[]]$GitArgs)
    $out = & git -C $RepoPath @GitArgs 2>&1
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out -join "`n") }
}
function Get-Head([string]$RepoPath) { (Invoke-Git -RepoPath $RepoPath rev-parse HEAD).Output.Trim() }

function Test-CleanTree([string]$RepoPath) {
    # -uall matters: without it git collapses an untracked directory to a single "?? Prompts/"
    # entry, which does not match the set's own pathspec ("Prompts/demo") and so makes the set's
    # state/logs/results look like a dirty tree on the very first run.
    $lines = (Invoke-Git -RepoPath $RepoPath status --porcelain -uall).Output -split "`r?`n" |
        Where-Object { $_ -and (-not $SetPathspec -or ($_ -notmatch [regex]::Escape($SetPathspec))) }
    return -not $lines
}

function Confirm-Branch([string]$RepoPath) {
    if (-not $M.Branch) { return }
    $current = (Invoke-Git -RepoPath $RepoPath rev-parse --abbrev-ref HEAD).Output.Trim()
    if ($current -eq $M.Branch) { return }
    $exists = (Invoke-Git -RepoPath $RepoPath rev-parse --verify --quiet $M.Branch).ExitCode -eq 0
    $r = if ($exists) { Invoke-Git -RepoPath $RepoPath checkout $M.Branch }
         else { Say "  creating branch $($M.Branch) in $RepoPath" 'DarkGray'
                Invoke-Git -RepoPath $RepoPath checkout -b $M.Branch }
    if ($r.ExitCode -ne 0) { throw "git checkout failed in ${RepoPath}: $($r.Output)" }
}

# ---------------------------------------------------------------- gates

function New-GateResult([string]$name, [bool]$ok, [string]$detail) {
    [pscustomobject]@{ Name = $name; Ok = $ok; Detail = $detail }
}

function Invoke-Shell {
    param([string]$WorkDir, [string]$CommandLine, [string]$LogPath)
    Push-Location $WorkDir
    try {
        $output = & cmd /c "$CommandLine 2>&1" | Out-String
        $code = $LASTEXITCODE
    }
    finally { Pop-Location }
    if ($LogPath) { $output | Set-Content -Path $LogPath -Encoding UTF8 }
    $tail = ($output -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 12) -join "`n"
    return [pscustomobject]@{ ExitCode = $code; Output = $output; Tail = $tail }
}

function Resolve-RepoPath($key) {
    if (-not $key) { return $M.Repos[$PrimaryRepo] }
    if ($M.Repos.ContainsKey($key)) { return $M.Repos[$key] }
    return $key
}

function Get-SearchFiles([string]$Root, [string[]]$Include) {
    $inc = if ($Include) { $Include } else { @('*.cs','*.ts','*.tsx','*.js','*.jsx','*.py','*.go','*.rs',
        '*.csproj','*.sln','*.json','*.xml','*.bat','*.sh','*.props','*.sql','*.yml','*.yaml') }
    Get-ChildItem -Path $Root -Recurse -File -ErrorAction SilentlyContinue -Include $inc |
        Where-Object { $_.FullName -notmatch '\\(bin|obj|node_modules|dist|\.git|\.next|target)\\' -and
                       (-not $SetPathspec -or $_.FullName -notmatch [regex]::Escape($SetPathspec.Replace('/','\'))) }
}

function Invoke-Gate {
    param($Gate, $Prompt, [string]$RepoPath, [string]$GateLogDir, [string]$BaseCommit)

    switch ($Gate.Type) {

        # The only gate that reads the CHANGE rather than the result. Build, tests and greps all
        # answer "does the tree satisfy these assertions" - none of them notices a session that did
        # what was asked AND quietly refactored half the codebase on the way, or that satisfied the
        # letter of an assertion while missing the point. A separate session, which never saw the
        # implementer's reasoning, reads the diff against the prompt and answers three questions:
        # did it do what was asked, did it do MORE than was asked, did it do LESS.
        'DiffReview' {
            if (-not $BaseCommit) { return New-GateResult 'DiffReview' $true 'no base commit - skipped' }

            # -N so newly created files appear in the diff; the runner stages everything a moment
            # later anyway, and a rollback resets the index with the tree.
            if ($SetPathspec) { Invoke-Git -RepoPath $RepoPath add -A -N -- . ":(exclude)$SetPathspec" | Out-Null }
            else { Invoke-Git -RepoPath $RepoPath add -A -N | Out-Null }

            $stat = (Invoke-Git -RepoPath $RepoPath diff $BaseCommit --stat).Output
            $diff = (Invoke-Git -RepoPath $RepoPath diff $BaseCommit).Output
            if (-not $diff.Trim()) { return New-GateResult 'DiffReview' $true 'no changes to review' }

            $cap = if ($Gate.MaxChars) { $Gate.MaxChars } else { 180000 }
            $truncated = ''
            if ($diff.Length -gt $cap) {
                $diff = $diff.Substring(0, $cap)
                $truncated = "`n`n[diff truncated at $cap characters - judge on what is shown]"
            }

            $promptFile = Get-ChildItem -Path $PromptsDir -Filter "$($Prompt.Id)-*.md" | Select-Object -First 1
            $brief = Get-Content -Raw $promptFile.FullName

            $ask = @"
You are reviewing someone else's change. You did not write it and you have none of their reasoning.

Below is the task they were given, then the complete diff they produced. Answer three questions:

1. Does the diff do what the task asked?
2. Does it do MORE than was asked - unrequested refactors, renames, reformatting, drive-by edits,
   files touched for no reason the task implies? That is scope creep and it is a FAILURE, however
   good the extra work looks. A change nobody asked for is a change nobody reviewed.
3. Does it do LESS - an acceptance criterion the diff plainly cannot satisfy?

Judge only the diff against the task. Do not run anything, do not open other files, do not fix
anything. Style you merely dislike is not a finding. Be specific: name files and say what is wrong.

verdict:
  ok         - does what was asked, nothing more, nothing less
  scope_creep- also changed things the task did not ask for
  incomplete - an acceptance criterion is plainly unmet by this diff
  wrong      - does something other than what the task asked

=== TASK ===
$brief

=== DIFF STAT ===
$stat

=== DIFF ===
$diff$truncated
"@

            $schema = '{"type":"object","properties":{"verdict":{"type":"string","enum":["ok","scope_creep","incomplete","wrong"]},"findings":{"type":"array","items":{"type":"string"}}},"required":["verdict","findings"]}'
            $model = if ($Gate.Model) { $Gate.Model } elseif ($M.ReviewModel) { $M.ReviewModel } else { 'sonnet' }

            $claude = Get-ClaudeExe
            $cli = @(
                '-p'
                '--model', $model
                '--effort', 'high'
                '--permission-mode', 'bypassPermissions'
                '--output-format', 'json'
                '--json-schema', $schema
                # A reviewer that can edit is not a reviewer.
                '--disallowed-tools', 'Edit', 'Write', 'NotebookEdit'
            )

            Push-Location $RepoPath
            try { $raw = $ask | & $claude @cli 2>&1 | Out-String } finally { Pop-Location }
            $raw | Set-Content -Path (Join-Path $GateLogDir 'diff-review.json') -Encoding UTF8

            $verdict = $null; $findings = @()
            try {
                $outer = $raw | ConvertFrom-Json
                $inner = if ($outer.result -is [string]) { $outer.result | ConvertFrom-Json } else { $outer.result }
                $verdict = $inner.verdict; $findings = @($inner.findings)
            }
            catch {
                if ($raw -match '"verdict"\s*:\s*"(\w+)"') { $verdict = $Matches[1] }
            }

            if (-not $verdict) { return New-GateResult 'DiffReview' $false 'the reviewer returned nothing usable' }
            $detail = "verdict=$verdict"
            if ($findings.Count) { $detail += "`n" + (($findings | ForEach-Object { "  - $_" }) -join "`n") }
            return New-GateResult 'DiffReview' ($verdict -eq 'ok') $detail
        }

        { $_ -in 'Build', 'Test', 'Lint', 'Typecheck' } {
            $line = $M.Commands[$Gate.Type]
            if (-not $line) { return New-GateResult $Gate.Type $false "manifest has no Commands.$($Gate.Type)" }
            $where = Resolve-RepoPath ($Gate.In)
            $log = Join-Path $GateLogDir ($Gate.Type.ToLower() + '.txt')
            $r = Invoke-Shell -WorkDir $where -CommandLine $line -LogPath $log

            # A generated-source error under an intermediate folder means a build racing something
            # that touched it, not broken source. A real compile error survives a second build.
            if ($r.ExitCode -ne 0 -and $Gate.Type -eq 'Build' -and $r.Output -match 'CS2001.*\.g\.cs') {
                Say '    (transient intermediate state - rebuilding once)' 'DarkGray'
                $r = Invoke-Shell -WorkDir $where -CommandLine $line -LogPath $log
            }
            return New-GateResult $Gate.Type ($r.ExitCode -eq 0) $r.Tail
        }

        'Cmd' {
            $where = Resolve-RepoPath ($Gate.In)
            $safe = ($Gate.Run -replace '[^A-Za-z0-9]', '_')
            $safe = $safe.Substring(0, [Math]::Min(40, $safe.Length))
            $r = Invoke-Shell -WorkDir $where -CommandLine $Gate.Run -LogPath (Join-Path $GateLogDir "cmd-$safe.txt")
            return New-GateResult "Cmd($($Gate.Run))" ($r.ExitCode -eq 0) $r.Tail
        }

        'FileExists' {
            $p = Join-Path (Resolve-RepoPath $Gate.In) $Gate.Path
            return New-GateResult "FileExists($($Gate.Path))" (Test-Path $p) $p
        }

        'FileGlob' {
            $hits = @(Get-ChildItem -Path (Join-Path (Resolve-RepoPath $Gate.In) $Gate.Pattern) -ErrorAction SilentlyContinue)
            return New-GateResult "FileGlob($($Gate.Pattern))" ($hits.Count -gt 0) ($hits.Name -join ', ')
        }

        'GrepAtLeast' {
            $target = Join-Path (Resolve-RepoPath $Gate.In) $Gate.Path
            if (-not (Test-Path $target)) { return New-GateResult "GrepAtLeast($($Gate.Pattern))" $false "path missing: $target" }
            $files = if (Test-Path $target -PathType Container) { Get-SearchFiles $target $Gate.Include } else { Get-Item $target }
            $hits = @($files | Select-String -Pattern $Gate.Pattern -ErrorAction SilentlyContinue)
            return New-GateResult "GrepAtLeast($($Gate.Pattern))" ($hits.Count -gt 0) "$($hits.Count) match(es)"
        }

        'GrepZero' {
            $target = Join-Path (Resolve-RepoPath $Gate.In) $Gate.Path
            $files = Get-SearchFiles $target $Gate.Include
            # Commented-out lines are stripped first: dead code left by a conversion carries the same
            # literals and would flag a file that is actually correct.
            $hits = @()
            foreach ($f in $files) {
                $text = (Get-Content $f.FullName -ErrorAction SilentlyContinue |
                    Where-Object { $_.TrimStart() -notmatch '^(//|#|--)' }) -join "`n"
                if ($text -match $Gate.Pattern) { $hits += $f.FullName }
            }
            $detail = if ($hits.Count) { ($hits | Select-Object -First 8) -join "`n" } else { 'no matches' }
            return New-GateResult "GrepZero($($Gate.Pattern))" ($hits.Count -eq 0) $detail
        }

        'Smoke' {
            if (-not $M.AppExe) { return New-GateResult 'Smoke' $false 'manifest has no AppExe' }
            $outDir = Join-Path $GateLogDir ('smoke-' + $Gate.Scenario)
            $exe = Join-Path (Resolve-RepoPath $null) $M.AppExe
            $smokeArgs = @('-NoProfile', '-File', $SmokeScript, '-Scenario', $Gate.Scenario, '-Exe', $exe, '-OutDir', $outDir)
            if ($Gate.AllowExit) { $smokeArgs += '-AllowExit' }
            $r = Invoke-Shell -WorkDir (Resolve-RepoPath $null) `
                -CommandLine ('pwsh ' + (($smokeArgs | ForEach-Object { '"' + $_ + '"' }) -join ' ')) `
                -LogPath (Join-Path $GateLogDir "smoke-$($Gate.Scenario).txt")
            return New-GateResult "Smoke($($Gate.Scenario))" ($r.ExitCode -eq 0) $r.Tail
        }

        'Signoff' { return New-GateResult 'Signoff' $true 'deferred to human' }

        default { return New-GateResult "Unknown($($Gate.Type))" $false 'unknown gate type' }
    }
}

function Test-ResultsFile([string]$id) {
    $f = Join-Path $ResultsDir "$id.json"
    if (-not (Test-Path $f)) { return New-GateResult 'ResultsFile' $false "missing $f - the session did not report" }

    $raw = Get-Content -Raw $f
    $malformed = ''
    $j = $null
    try { $j = $raw | ConvertFrom-Json }
    catch {
        # A hand-written report full of Windows paths invites exactly one mistake: an unescaped
        # backslash. That is a typo in a REPORT, not a defect in the work, and the gates that decide
        # correctness have already run. Read the verdict out of the text and carry the malformation
        # as a warning rather than throwing away good work.
        $malformed = 'malformed JSON; read leniently. '
        if ($raw -match '"status"\s*:\s*"(PASS|FAIL|BLOCKED)"') {
            $j = [pscustomobject]@{ status = $Matches[1]; unverified = @() }
        }
        else { return New-GateResult 'ResultsFile' $false "unparseable and no status found" }
    }

    $ok = $j.status -eq 'PASS'
    $detail = $malformed + "status=$($j.status)"
    if ($j.unverified) { $detail += '; unverified: ' + (@($j.unverified) -join ' | ') }
    return New-GateResult 'ResultsFile' $ok $detail
}

# ---------------------------------------------------------------- session

function Get-ClaudeExe {
    $c = Get-Command claude -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $fallback = Join-Path $env:USERPROFILE '.local\bin\claude'
    if (Test-Path $fallback) { return $fallback }
    throw 'claude CLI not found on PATH'
}

function Get-Protocol {
    param($Prompt, [int]$Index, [int]$Total, [string]$RepoPath, [string[]]$OtherRepos, [string]$ExtraFailure)

    $others = if ($OtherRepos) { $OtherRepos -join ', ' } else { '(none)' }
    $smokeLine = if ($M.AppExe) {
@"
- Where a prompt asks you to run the desktop app, call the shared helper rather than inventing your
  own launch/kill logic:
      pwsh -NoProfile -File "$SmokeScript" -Scenario Start
  Scenarios: Start [-KeepRunning] [-AllowExit] | SecondInstance | Inspect -Title <w>
             | Invoke -AutomationId <id> | Invoke -Name "<label>" | SetText -AutomationId <id> -Text "..."
             | Click -X <n> -Y <n> | Keys -Send "<sendkeys>" | Screenshot | Kill
  It prints one JSON line and writes screenshots and a UI Automation text dump into -OutDir. You can
  therefore drive a real dialog end to end: Start -KeepRunning, Inspect to read every AutomationId
  and label, Invoke/SetText against those ids, Inspect again to see what changed. Buttons labelled
  in any language are addressable by -Name. Toolbar/status-bar items that expose no name need
  Click at the centre of their UIA BoundingRectangle. Use this to VERIFY dialog flows rather than
  declaring them unverified.
"@
    } else {
@"
- Where a prompt asks you to exercise the running app, drive it yourself: start the dev server, use
  the browser tools to navigate, fill and assert, and read the console and network panes. Verify the
  behaviour the prompt names rather than declaring it unverified.
"@
    }

    $text = @"
RUNNER PROTOCOL - you are step $Index of $Total in an automated run.
Everything below overrides your own judgement about scope.

- Do EXACTLY the one prompt you were given. Do not start, preview or "prepare for" any other step.
- Your working repo is $RepoPath. Do NOT edit anything under: $others - those are attached only so
  you can READ reference material.
- Do NOT run: git commit, git tag, git branch, git checkout, git reset, git stash. The runner owns
  version control and commits for you once your work passes its gates. Leave changes in the tree.
- THE PROMPT MAY BE WRONG. It was written without reading every file. Its "Verified context" was
  checked when it was written; anything else is a starting hypothesis. If reality disagrees - a
  path moved, a function is named differently, the described approach does not fit - THE CODE WINS.
  Do the right thing and record what you changed in "deviations". Never bend the codebase to match
  a mistaken instruction, and never implement something you can see is wrong.
- Verify your own work against the prompt's acceptance criteria before you finish.
$smokeLine
- Your LAST action is to write $ResultsDir\$($Prompt.Id).json with exactly this shape:
  {
    "id": "$($Prompt.Id)",
    "status": "PASS" | "BLOCKED" | "FAIL",
    "summary": "one short paragraph on what you changed",
    "changed_files": ["repo-relative paths"],
    "verification_performed": ["what you actually ran, and what it reported"],
    "unverified": ["anything the prompt asked for that you could NOT prove on this machine"],
    "deviations": ["where the prompt was wrong and what you did instead"],
    "decisions": ["choices you made on the user's behalf, and the alternative you rejected"],
    "followups": ["things worth doing later, out of scope here"],
    "handoff": "what the next step's session needs to know"
  }
  It must be VALID JSON. Windows paths are the one thing that reliably breaks it: a bare
  "C:\Code\obj\x" is an illegal escape. Write forward slashes, or double every backslash.
  PASS only if you completed the prompt AND its verification passed. If you are blocked, write
  BLOCKED with the reason - do not half-do the work to reach PASS. Never list a verification you
  did not run; "unverified" is the honest place for it and costs you nothing. The runner
  independently re-runs the build, the tests and prompt-specific assertions afterwards, so an
  overstated PASS is caught rather than believed.
- "decisions" feeds the final report the user reads. Any choice you made without asking belongs
  there, with the option you did not take. Anything irreversible, destructive, or that materially
  changes the shape of the deliverable should have been a question instead - stop and ask.
"@

    if ($Prompt.Note) {
        $text += @"

STANDING DECISIONS - deliberate and authorised. Treat them as intended behaviour; do not "restore"
any earlier instruction they supersede.
$($Prompt.Note)
"@
    }

    if ($ExtraFailure) {
        $text += @"

RETRY - your previous session on this same prompt was rejected by the runner's gates:
$ExtraFailure
Fix ONLY what failed. Do not redo or expand the rest of the work, and do not revert it.
"@
    }
    return $text
}

function Invoke-PromptSession {
    param($Prompt, [int]$Index, [int]$Total, [string]$RepoPath, [string[]]$OtherRepos,
          [string]$SessionLog, [string]$ExtraFailure)

    $sessionId = [guid]::NewGuid().ToString()
    $promptFile = Get-ChildItem -Path $PromptsDir -Filter "$($Prompt.Id)-*.md" | Select-Object -First 1
    if (-not $promptFile) { throw "prompt file for $($Prompt.Id) not found in $PromptsDir" }

    $protocol = Get-Protocol -Prompt $Prompt -Index $Index -Total $Total -RepoPath $RepoPath `
        -OtherRepos $OtherRepos -ExtraFailure $ExtraFailure

    $model  = if ($Prompt.Model)  { $Prompt.Model }  elseif ($M.Model)  { $M.Model }  else { 'opus' }
    $effort = if ($Prompt.Effort) { $Prompt.Effort } elseif ($M.Effort) { $M.Effort } else { 'high' }

    $cli = @(
        '-p'
        '--model', $model
        '--effort', $effort
        '--permission-mode', 'bypassPermissions'
        '--output-format', 'json'
        '--session-id', $sessionId
        '--append-system-prompt', $protocol
    )
    foreach ($o in $OtherRepos) { $cli += @('--add-dir', $o) }
    if ($M.BudgetUsd) { $cli += @('--max-budget-usd', "$($M.BudgetUsd)") }

    $mcpConfig = Join-Path $RepoPath '.mcp.json'
    if (Test-Path $mcpConfig) { $cli += @('--strict-mcp-config', '--mcp-config', $mcpConfig) }

    Say "  session $sessionId" 'DarkGray'
    Say "  cwd     $RepoPath" 'DarkGray'
    Say "  model   $model / $effort" 'DarkGray'

    $claude = Get-ClaudeExe
    Push-Location $RepoPath
    try {
        $raw = Get-Content -Raw $promptFile.FullName | & $claude @cli 2>&1 | Out-String
        $code = $LASTEXITCODE
    }
    finally { Pop-Location }

    $raw | Set-Content -Path $SessionLog -Encoding UTF8
    $parsed = $null
    try { $parsed = $raw | ConvertFrom-Json } catch { }

    return [pscustomobject]@{
        SessionId = $sessionId
        ExitCode  = $code
        IsError   = if ($parsed) { [bool]$parsed.is_error } else { $code -ne 0 }
        CostUsd   = if ($parsed) { $parsed.total_cost_usd } else { $null }
        NumTurns  = if ($parsed) { $parsed.num_turns } else { $null }
        Model     = $model
        Effort    = $effort
    }
}

# ---------------------------------------------------------------- preflight

$script:PreflightOk = $true

function Invoke-Preflight {
    Rule 'PREFLIGHT'
    $script:PreflightOk = $true

    function Check([string]$name, [scriptblock]$test, [string]$hint) {
        try { $v = & $test } catch { $v = $false }
        if ($v) { Say ("  OK    {0}" -f $name) 'Green' }
        else { Say ("  FAIL  {0}  -> {1}" -f $name, $hint) 'Red'; $script:PreflightOk = $false }
    }

    Check 'claude CLI' { [bool](Get-Command claude -ErrorAction SilentlyContinue) } 'expose the claude CLI'
    Check 'prompts present' { (Get-ChildItem $PromptsDir -Filter 'P*.md' -ErrorAction SilentlyContinue).Count -eq $M.Prompts.Count } "expected $($M.Prompts.Count) files in $PromptsDir"
    foreach ($k in $M.Repos.Keys) {
        $path = $M.Repos[$k]
        Check "repo '$k'" { Test-Path $path } 'path in manifest.psd1 is wrong'
        Check "repo '$k' clean" { Test-CleanTree $path } 'commit or stash your work first'
    }

    foreach ($name in @('Build', 'Test', 'Lint', 'Typecheck')) {
        if ($M.Commands -and $M.Commands[$name]) {
            Say "  running Commands.$name ..." 'DarkGray'
            $r = Invoke-Shell -WorkDir (Resolve-RepoPath $null) -CommandLine $M.Commands[$name] `
                -LogPath (Join-Path $LogsDir "preflight-$name.txt")
            if ($r.ExitCode -eq 0) { Say "  OK    baseline $name" 'Green' }
            else { Say "  FAIL  baseline $name`n$($r.Tail)" 'Red'; $script:PreflightOk = $false }
        }
    }

    if ($M.AppExe) {
        Say '  launching the app (proves the GUI gates mean anything)...' 'DarkGray'
        $exe = Join-Path (Resolve-RepoPath $null) $M.AppExe
        $r = Invoke-Shell -WorkDir (Resolve-RepoPath $null) `
            -CommandLine ('pwsh -NoProfile -File "' + $SmokeScript + '" -Scenario Start -Exe "' + $exe + '" -OutDir "' + (Join-Path $LogsDir 'preflight-smoke') + '"') `
            -LogPath (Join-Path $LogsDir 'preflight-smoke.txt')
        if ($r.ExitCode -eq 0) { Say '  OK    app starts and presents a window' 'Green' }
        else {
            Say '  WARN  the app did not start cleanly. Smoke gates cannot prove anything until' 'Yellow'
            Say '        this works. Fix it before relying on any tier that runs the app.' 'Yellow'
        }
    }

    Say ''
    if ($script:PreflightOk) { Say '  preflight PASSED' 'Green' } else { Say '  preflight FAILED' 'Red' }
    return $script:PreflightOk
}

# ---------------------------------------------------------------- reporting

function Show-Status {
    $state = Get-State
    Rule "LEDGER - $($M.Name)"
    $i = 0
    foreach ($p in $M.Prompts) {
        $i++
        $ps = if ($state.prompts.ContainsKey($p.Id)) { $state.prompts[$p.Id] } else { @{ status = 'PENDING' } }
        $colour = switch ($ps.status) {
            'DONE' { 'Green' } 'FAILED' { 'Red' } 'AWAITING_SIGNOFF' { 'Yellow' } default { 'DarkGray' }
        }
        $sha = if ($ps.commit) { $ps.commit.Substring(0, 8) } else { '        ' }
        Say ('  {0,2}. {1}  {2,-16} tier {3}  {4}  {5}' -f $i, $p.Id, $ps.status, $p.Tier, $sha, $p.Title) $colour
    }
    $spent = 0
    foreach ($k in $state.prompts.Keys) { if ($state.prompts[$k].costUsd) { $spent += $state.prompts[$k].costUsd } }
    Say ''
    Say ('  recorded session cost: ${0:N2}' -f $spent) 'DarkGray'
}

function Show-SignoffChecklist($Prompt) {
    $file = Get-ChildItem -Path $PromptsDir -Filter "$($Prompt.Id)-*.md" | Select-Object -First 1
    $lines = Get-Content $file.FullName
    $start = ($lines | Select-String -Pattern '^##\s*Acceptance|^Verify' | Select-Object -First 1).LineNumber
    Rule "$($Prompt.Id) NEEDS YOUR SIGN-OFF - $($Prompt.Title)"
    Say '  The machine gates passed. This step''s acceptance test needs a person:' 'Yellow'
    Say ''
    if ($start) { $lines[($start - 1)..($lines.Count - 1)] | ForEach-Object { Say "    $_" 'White' } }
    Say ''
    Say "  Artifacts: $(Join-Path $LogsDir $Prompt.Id)" 'DarkGray'
    Say '  When done:' 'Cyan'
    Say "    .\Run-Prompts.ps1 -Signoff $($Prompt.Id) -Result pass" 'Cyan'
}

function Write-Report {
    $gen = Join-Path $SkillDir 'New-Report.ps1'
    $out = Join-Path $SetRoot 'report.html'
    & pwsh -NoProfile -File $gen -SetPath $SetRoot -Out $out
    Say "  report -> $out" 'Green'
    return $out
}

# ---------------------------------------------------------------- entry points

if ($Status)  { Show-Status; return }
if ($Report)  { Write-Report | Out-Null; return }
if ($Preflight) { if (-not (Invoke-Preflight)) { exit 1 }; return }

if ($Signoff) {
    $state = Get-State
    $prompt = $M.Prompts | Where-Object { $_.Id -eq $Signoff }
    if (-not $prompt) { throw "unknown prompt id: $Signoff" }
    $ps = Get-PromptState $state $Signoff
    if ($ps.status -ne 'AWAITING_SIGNOFF') { Say "  $Signoff is '$($ps.status)', nothing to sign off." 'Yellow'; return }
    if ($Result -eq 'pass') {
        $repoPath = Resolve-RepoPath $prompt.Repo
        if (-not $NoCommit -and -not (Test-CleanTree $repoPath)) {
            if ($SetPathspec) { Invoke-Git -RepoPath $repoPath add -A -- . ":(exclude)$SetPathspec" | Out-Null }
            else { Invoke-Git -RepoPath $repoPath add -A | Out-Null }
            $c = Invoke-Git -RepoPath $repoPath commit -m "$($prompt.Id): $($prompt.Title)"
            if ($c.ExitCode -ne 0) { throw "commit failed: $($c.Output)" }
            Invoke-Git -RepoPath $repoPath tag -f "$($M.Name)/$($prompt.Id)" | Out-Null
            $ps.commit = Get-Head $repoPath
        }
        $ps.status = 'DONE'; $ps.signedOff = (Get-Date).ToString('o')
        Say "  $Signoff signed off. Re-run to continue." 'Green'
    }
    else { $ps.status = 'FAILED'; Say "  $Signoff marked FAILED." 'Red' }
    Save-State $state
    return
}

# ---------------------------------------------------------------- selection

$selected = $M.Prompts
if ($Only) { $selected = $M.Prompts | Where-Object { $_.Id -eq $Only } }
else {
    if ($From) {
        $i = [array]::IndexOf([string[]]($selected.Id), $From)
        if ($i -lt 0) { throw "unknown -From id: $From" }
        $selected = @($selected)[$i..($selected.Count - 1)]
    }
    if ($To) {
        $j = [array]::IndexOf([string[]]($selected.Id), $To)
        if ($j -lt 0) { throw "unknown -To id: $To" }
        $selected = @($selected)[0..$j]
    }
}
if (-not $selected) { throw 'no prompts selected' }

if ($DryRun) {
    Rule "DRY RUN - $($M.Name) - nothing will be spawned"
    foreach ($p in $selected) {
        $repoPath = Resolve-RepoPath $p.Repo
        $others = $M.Repos.Keys | Where-Object { $M.Repos[$_] -ne $repoPath } | ForEach-Object { $M.Repos[$_] }
        $gates = ($p.Gates | ForEach-Object { if ($_.Scenario) { "$($_.Type):$($_.Scenario)" } else { $_.Type } }) -join ', '
        $model = if ($p.Model) { $p.Model } else { $M.Model }
        $effort = if ($p.Effort) { $p.Effort } else { $M.Effort }
        Say ''
        Say ("  {0}  tier {1}  {2}" -f $p.Id, $p.Tier, $p.Title) 'White'
        Say ("     cwd      {0}" -f $repoPath) 'DarkGray'
        Say ("     add-dir  {0}" -f (($others -join ', ') -replace '^$', '(none)')) 'DarkGray'
        Say ("     model    {0} / {1}" -f $model, $effort) 'DarkGray'
        Say ("     gates    ResultsFile, {0}" -f $gates) 'DarkGray'
        if ($p.Tier -in @('D', 'E')) { Say '     STOPS for human sign-off' 'Yellow' }
    }
    Say ''
    Say ("  {0} prompt(s). Sign-off stops: {1}" -f $selected.Count,
        ((($selected | Where-Object { $_.Tier -in @('D','E') }).Id -join ', ') -replace '^$', 'none')) 'Cyan'
    return
}

# ---------------------------------------------------------------- the run

$state = Get-State
foreach ($k in $M.Repos.Keys) { Confirm-Branch $M.Repos[$k] }

foreach ($prompt in $selected) {
    $index = [array]::IndexOf([string[]]($M.Prompts.Id), $prompt.Id) + 1
    $ps = Get-PromptState $state $prompt.Id
    $repoPath = Resolve-RepoPath $prompt.Repo
    $otherRepos = @($M.Repos.Keys | Where-Object { $M.Repos[$_] -ne $repoPath } | ForEach-Object { $M.Repos[$_] })

    if ($ps.status -eq 'DONE' -and -not $Force) { Say "  $($prompt.Id) already DONE - skipping" 'DarkGray'; continue }
    if ($ps.status -eq 'AWAITING_SIGNOFF') { Show-SignoffChecklist $prompt; Save-State $state; return }
    if ($ps.status -eq 'FAILED' -and -not $Force) {
        Say "  $($prompt.Id) is FAILED. Fix it and re-run with -Force, or roll back first." 'Red'; return
    }

    Rule ("[{0}/{1}]  {2}  tier {3}  -  {4}" -f $index, $M.Prompts.Count, $prompt.Id, $prompt.Tier, $prompt.Title)

    if (-not (Test-CleanTree $repoPath)) {
        Say "  $repoPath has uncommitted changes. Commit or stash them first." 'Red'; return
    }

    $ps.baseCommit = Get-Head $repoPath
    $ps.status = 'RUNNING'
    Save-State $state

    $gateLogDir = Join-Path $LogsDir $prompt.Id
    New-Item -ItemType Directory -Force -Path $gateLogDir | Out-Null
    Remove-Item (Join-Path $ResultsDir "$($prompt.Id).json") -ErrorAction SilentlyContinue

    $passed = $false
    $failureReport = $null

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Say ("  attempt {0}/{1}" -f $attempt, $MaxAttempts) 'DarkGray'
        $sessionLog = Join-Path $gateLogDir "session-$attempt.json"

        $session = Invoke-PromptSession -Prompt $prompt -Index $index -Total $M.Prompts.Count `
            -RepoPath $repoPath -OtherRepos $otherRepos -SessionLog $sessionLog -ExtraFailure $failureReport

        $ps.attempts = $attempt
        $ps.sessionId = $session.SessionId
        $ps.model = $session.Model
        if ($session.CostUsd) { $ps.costUsd = $session.CostUsd }
        Save-State $state

        if ($session.IsError) { Say "  session ended in error - see $sessionLog" 'Red' }
        Say ("  session done: {0} turns, {1}" -f $session.NumTurns,
            $(if ($session.CostUsd) { '${0:N2}' -f $session.CostUsd } else { 'cost n/a' })) 'DarkGray'

        $gateResults = @(Test-ResultsFile $prompt.Id)
        foreach ($g in $prompt.Gates) {
            $gateResults += Invoke-Gate -Gate $g -Prompt $prompt -RepoPath $repoPath `
                -GateLogDir $gateLogDir -BaseCommit $ps.baseCommit
        }

        Say ''
        foreach ($g in $gateResults) {
            if ($g.Ok) { Say ("    PASS  {0}" -f $g.Name) 'Green' }
            else { Say ("    FAIL  {0}" -f $g.Name) 'Red'; Say ("          {0}" -f $g.Detail) 'DarkRed' }
        }
        Say ''

        $failed = @($gateResults | Where-Object { -not $_.Ok })
        if ($failed.Count -eq 0) { $passed = $true; break }

        $failureReport = ($failed | ForEach-Object { "GATE {0} FAILED:`n{1}" -f $_.Name, $_.Detail }) -join "`n`n"
        $failureReport | Set-Content -Path (Join-Path $gateLogDir "gate-failure-$attempt.txt") -Encoding UTF8
    }

    if (-not $passed) {
        Say "  $($prompt.Id) failed its gates after $MaxAttempts attempt(s). Rolling back." 'Red'
        Invoke-Git -RepoPath $repoPath reset --hard $ps.baseCommit | Out-Null
        if ($SetPathspec) { Invoke-Git -RepoPath $repoPath -GitArgs @('clean', '-fd', '-e', $SetPathspec) | Out-Null }
        else { Invoke-Git -RepoPath $repoPath clean -fd | Out-Null }
        $ps.status = 'FAILED'
        Save-State $state
        Say ''
        Say "  Working tree restored to $($ps.baseCommit.Substring(0,8))." 'DarkGray'
        Say "  Inspect the session:  claude --resume $($ps.sessionId)" 'Cyan'
        Say "  Logs:                 $gateLogDir" 'Cyan'
        Say '  Nothing downstream will run - the chain depends on this step.' 'Red'
        Write-Report | Out-Null
        return
    }

    if (-not $NoCommit -and -not (Test-CleanTree $repoPath)) {
        if ($SetPathspec) { Invoke-Git -RepoPath $repoPath add -A -- . ":(exclude)$SetPathspec" | Out-Null }
        else { Invoke-Git -RepoPath $repoPath add -A | Out-Null }
        $c = Invoke-Git -RepoPath $repoPath commit -m "$($prompt.Id): $($prompt.Title)"
        if ($c.ExitCode -ne 0) { throw "commit failed in ${repoPath}: $($c.Output)" }
        Invoke-Git -RepoPath $repoPath tag -f "$($M.Name)/$($prompt.Id)" | Out-Null
        $ps.commit = Get-Head $repoPath
        Say "  committed $($ps.commit.Substring(0,8))" 'Green'
    }

    if ($prompt.Tier -in @('D', 'E')) {
        $ps.status = 'AWAITING_SIGNOFF'
        $ps.finished = (Get-Date).ToString('o')
        Save-State $state
        Show-SignoffChecklist $prompt
        Write-Report | Out-Null
        return
    }

    $ps.status = 'DONE'
    $ps.finished = (Get-Date).ToString('o')
    Save-State $state
    Say "  $($prompt.Id) DONE" 'Green'
}

Save-State $state
Show-Status
Write-Report | Out-Null
Say ''
Say '  run complete' 'Green'
