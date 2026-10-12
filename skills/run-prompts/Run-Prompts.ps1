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
      5. INDEPENDENT AUDIT (on by default): a fresh read-only session hunts for real defects in the
         committed step; a fix session reproduces each one with a failing test, fixes it or drops
         it; the gates re-run and the fixes land in their own `fix(Pxx-audit)` commit
      6. tiers that need a person stop for sign-off after their machine gates pass

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
    # Skip the independent audit for this invocation. On a step left in AUDIT_FAILED it accepts the
    # step as it stands (the orchestrator fixed or judged the findings by hand).
    [switch]$NoAudit,
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
# Just the folder name, forward-slashed, for use in a git pathspec (see the DiffReview gate).
$PromptsDirName = if ($M.PromptsDir) { $M.PromptsDir } else { 'prompts' }
$PromptsDirName = $PromptsDirName.Replace('\', '/').Trim('/')
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

# `claude -p` runs with 2>&1, so anything the CLI prints on stderr before its JSON result (a
# workspace-trust warning, a deprecation notice) lands in front of the object and made every
# ConvertFrom-Json fail: session costs were recorded as null and DiffReview lost its findings,
# leaving the scope trim and the retry with nothing but "verdict=scope_creep" to act on.
function ConvertFrom-ClaudeOutput([string]$raw) {
    if (-not $raw) { return $null }
    try { return $raw | ConvertFrom-Json } catch { }
    $lines = $raw -split "`r?`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].TrimStart().StartsWith('{')) {
            try { return (($lines[$i..($lines.Count - 1)]) -join "`n") | ConvertFrom-Json } catch { }
        }
    }
    return $null
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
    # The default list is what a directory-scoped Grep gate can SEE. An extension missing from it
    # does not narrow the gate, it silences it: GrepAtLeast fails over a folder it never opened, and
    # - far worse - GrepZero passes over one, reporting "0 matches" for a file it never read. On
    # Windows repos that bit .ps1/.cmd (deployment scripts) and .md (documentation), where a gate
    # asserting "this sentence is gone" was green because it had searched nothing at all.
    $inc = if ($Include) { $Include } else { @('*.cs','*.ts','*.tsx','*.js','*.jsx','*.py','*.go','*.rs',
        '*.csproj','*.sln','*.json','*.xml','*.bat','*.sh','*.props','*.sql','*.yml','*.yaml',
        '*.ps1','*.psm1','*.psd1','*.cmd','*.md') }
    Get-ChildItem -Path $Root -Recurse -File -ErrorAction SilentlyContinue -Include $inc |
        Where-Object { $_.FullName -notmatch '\\(bin|obj|node_modules|dist|\.git|\.next|target)\\' -and
                       # A git worktree under .claude (or any tool's dot-folder: .kilo, .cursor...)
                       # is a second full checkout this run never edits; without this a repo-rooted
                       # GrepZero can never go green - and a retry session "fixes" the foreign
                       # checkout to pass it (seen with .kilo/worktrees in web-accounts P06).
                       $_.FullName -notmatch '\\\.[^\\]+\\worktrees\\' -and
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

            # The set folder is excluded from every commit (see the `add -A` calls above), so an
            # edit a session makes to its own prompt file stays in the working tree for the rest of
            # the run and leaks into EVERY later step's diff - where it reads to the reviewer as
            # unrequested work by that later step. Exclude the prompts/ subfolder here for that
            # reason - but ONLY that subfolder: a set can carry real deliverables next to the
            # prompts (SMOKE.md, a checklist), and a prompt that asks for one has an acceptance
            # criterion the reviewer must be able to see, or it returns 'incomplete' for a file
            # that was in fact written. state/, results/ and logs/ are usually gitignored already.
            #
            # A NEW deliverable there is untracked, and the `add -N` above leaves the set folder
            # out, so it never reached the diff (a review file, an audit report: 'incomplete' for a
            # file that was written). Mark the set's untracked files intent-to-add only while the
            # diff is taken, then take them out of the index again: `reset --hard` on a rollback
            # DELETES intent-to-add files from disk, and the set folder must survive a rollback.
            if ($SetPathspec) {
                $ex = ":(exclude)$SetPathspec/$PromptsDirName"
                $setNew = @((Invoke-Git -RepoPath $RepoPath -GitArgs @('ls-files', '--others', '--exclude-standard', '--',
                    $SetPathspec, $ex, ":(exclude)$SetPathspec/state", ":(exclude)$SetPathspec/results",
                    ":(exclude)$SetPathspec/logs", ":(exclude)$SetPathspec/report.html")).Output -split "`r?`n" |
                    Where-Object { $_ })
                if ($setNew.Count) { Invoke-Git -RepoPath $RepoPath -GitArgs (@('add', '-N', '--') + $setNew) | Out-Null }
                try {
                    $stat = (Invoke-Git -RepoPath $RepoPath diff $BaseCommit --stat -- . $ex).Output
                    $diff = (Invoke-Git -RepoPath $RepoPath diff $BaseCommit -- . $ex).Output
                }
                finally {
                    if ($setNew.Count) { Invoke-Git -RepoPath $RepoPath -GitArgs (@('reset', '-q', '--') + $setNew) | Out-Null }
                }
            }
            else {
                $stat = (Invoke-Git -RepoPath $RepoPath diff $BaseCommit --stat).Output
                $diff = (Invoke-Git -RepoPath $RepoPath diff $BaseCommit).Output
            }
            if (-not $diff.Trim()) { return New-GateResult 'DiffReview' $true 'no changes to review' }

            $cap = if ($Gate.MaxChars) { $Gate.MaxChars } else { 180000 }
            $truncated = ''
            if ($diff.Length -gt $cap) {
                $diff = $diff.Substring(0, $cap)
                $truncated = "`n`n[diff truncated at $cap characters - judge on what is shown]"
            }

            $promptFile = Get-ChildItem -Path $PromptsDir -Filter "$($Prompt.Id)-*.md" | Select-Object -First 1
            $brief = Get-Content -Raw $promptFile.FullName

            # The reviewer must see the same standing decisions the implementer was given. Without
            # this it fails a session for obeying a Note that deliberately supersedes the prompt -
            # which is exactly what Note is for, so the gate contradicted the manifest.
            $noteBlock = if ($Prompt.Note) { @"

=== STANDING DECISIONS - authorised AFTER the task was written; they SUPERSEDE it ===
Everything below was decided deliberately after this task was authored. It is PART OF THE TASK: a
diff that follows it is correct, not scope creep. A diff that ignores it is incomplete.
$($Prompt.Note)
"@ } else { '' }

            # The implementer's own report - summary, changed files, deviations, decisions and (after
            # a scope trim) scope_justification - is what tells a reviewer that an edit outside the
            # prompt's expected folders was the wiring the asked work could not function without (a
            # DI registration, a route mapping, a shared record) rather than a drive-by. Without it,
            # four of eight steps in one real run were failed for exactly such edits, each costing a
            # full re-gate cycle. The reviewer is told these are claims to check against the diff.
            $notesBlock = ''
            $resultFile = Join-Path $ResultsDir "$($Prompt.Id).json"
            if (Test-Path $resultFile) {
                try {
                    $rj = Get-Content -Raw $resultFile | ConvertFrom-Json
                    $lines = @()
                    if ($rj.summary)             { $lines += "summary: $($rj.summary)" }
                    if ($rj.changed_files)       { $lines += 'changed_files: ' + (@($rj.changed_files) -join ', ') }
                    if ($rj.deviations)          { $lines += "deviations:`n" + ((@($rj.deviations) | ForEach-Object { "  - $_" }) -join "`n") }
                    if ($rj.decisions)           { $lines += "decisions:`n" + ((@($rj.decisions) | ForEach-Object { "  - $_" }) -join "`n") }
                    if ($rj.scope_justification) { $lines += "scope_justification (why out-of-fence edits were kept):`n" + ((@($rj.scope_justification) | ForEach-Object { "  - $_" }) -join "`n") }
                    if ($lines.Count) {
                        $notesBlock = "`n=== IMPLEMENTER'S REPORT - their claims; check each against the diff, do not take it on faith ===`n" + ($lines -join "`n") + "`n"
                    }
                }
                catch { }
            }

            $ask = @"
You are reviewing someone else's change. You did not write it and you have none of their reasoning.

Below is the task they were given, then the complete diff they produced. Answer three questions:

1. Does the diff do what the task asked?
2. Does it do MORE than was asked? Two things look alike here and only one is a failure:
   - NECESSARY WIRING: an edit outside the folders the task names that the asked work cannot
     function without - a DI registration, a route mapping, a shared record or contract, a guard
     test updated because the task changed what it pins, a test fixture. Minimal, in plain service
     of the task, and explained in the implementer's report. That is NOT scope creep: name it in
     findings and still return ok.
   - SCOPE CREEP: unrequested refactors, renames, reformatting, "while I was here" fixes, behaviour
     changes to things the task did not name, files touched for no reason the task implies. That is
     a FAILURE however good the extra work looks - a change nobody asked for is a change nobody
     reviewed. When the report claims an edit was necessary and the diff shows it was not, it is
     creep; say which.
3. Does it do LESS - an acceptance criterion the diff plainly cannot satisfy?

Judge only the diff against the task. Do not run anything, do not open other files, do not fix
anything. Style you merely dislike is not a finding. Be specific: name files and say what is wrong,
and for scope_creep name EVERY file or hunk that must go - a trim pass will act on your list.

verdict:
  ok         - does what was asked, plus at most the necessary wiring above
  scope_creep- also changed things the task neither asked for nor needed
  incomplete - an acceptance criterion is plainly unmet by this diff
  wrong      - does something other than what the task asked

=== TASK ===
$brief
$noteBlock$notesBlock

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
                $outer = ConvertFrom-ClaudeOutput $raw
                if (-not $outer) { throw 'reviewer output is not JSON' }
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

            # The same transient the Build gate retries. It belongs here too: `Commands` holds one
            # Build line, so a set spanning two solutions gates the second with Cmd - and then
            # loses a whole attempt to a race that has nothing to do with the change under test.
            if ($r.ExitCode -ne 0 -and $r.Output -match 'CS2001.*\.g\.cs') {
                Say '    (transient intermediate state - re-running once)' 'DarkGray'
                $r = Invoke-Shell -WorkDir $where -CommandLine $Gate.Run -LogPath (Join-Path $GateLogDir "cmd-$safe.txt")
            }
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
            # literals and would flag a file that is actually correct. Block-comment bodies count as
            # comments too - a JSDoc line stating the very rule a GrepZero enforces ("cmd.exe is never
            # used", "never disable TLS verification") is prose, not a violation, and stripping only
            # `//` made such a file fail the gate it actually complies with.
            $hits = @()
            foreach ($f in $files) {
                $text = (Get-Content $f.FullName -ErrorAction SilentlyContinue |
                    Where-Object { $_.TrimStart() -notmatch '^(//|#|--|\*|/\*)' }) -join "`n"
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
- CONTEXT DISCIPLINE. Everything you pull into this conversation is re-sent on EVERY later turn, so
  a session's cost and its attention both degrade with what it has swallowed, not with what it
  wrote (measured on real runs of this harness: over 90% of the spend was re-reading context, the
  output under 5%). So: (1) delegate bulk reading to subagents - the Agent tool, an Explore agent
  for searches - and take back a short answer: a codebase survey, a long log, a set of reference
  scripts, a screenshot folder; (2) never print a build or test log into the conversation -
  redirect it to a file and read its tail or grep it for the failures; (3) while iterating, run the
  narrowest test filter that covers what you changed, and the full suite once at the end; (4) do
  not re-read a file you already read unless you changed it; (5) open a screenshot only when the
  prompt asks you to judge what it shows. None of this lowers the bar - the gates, the full suite
  and the diff review still run on the finished tree - it keeps your attention on the work.
$smokeLine
- ONE SHOT - THERE IS NO WAKE-UP. You are a single non-interactive run. Nothing will wake you and
  there is no turn after the one you end: when you stop, the SESSION ENDS, and every background
  task still running is killed with it (print mode terminates them at a ceiling anyway). So never
  start a long command in the background and end your turn to wait for it, never arm a scheduled
  wake-up, a timer or a monitor, and never finish a turn saying you will continue "when X reports".
  A long build or test suite is either run in the FOREGROUND and waited for, or handed to a
  subagent - a subagent returns its answer inside your turn, a background task does not. A session
  that does all of the work and then ends without writing its results file has FAILED the step, and
  the work is rolled back: this is the single most expensive way to lose a step.
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
Your results file, however, REPLACES the previous one rather than adding to it, and the user's
report is built from it - so write it for the WHOLE step, not for this retry. "summary" describes
everything the step now delivers (read the previous results file first and carry its substance
forward), "changed_files" lists every file the step touched, and "decisions" and "deviations" keep
the earlier entries as well as anything this pass added. A summary that reads "fixed the two review
findings" tells the person reading the report nothing about what the step was for.
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
    $parsed = ConvertFrom-ClaudeOutput $raw

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

# The scope-trim session. Deliberately NOT the prompt's model/effort: the work is finished and
# green, and the whole job is to delete or justify the hunks the reviewer named. It is handed the
# prompt (so it knows what was asked), the reviewer's findings, and the base commit to diff against.
function Invoke-TrimSession {
    param($Prompt, [string]$RepoPath, [string[]]$OtherRepos, [string]$SessionLog,
          [string]$BaseCommit, [string]$Findings)

    $sessionId = [guid]::NewGuid().ToString()
    $promptFile = Get-ChildItem -Path $PromptsDir -Filter "$($Prompt.Id)-*.md" | Select-Object -First 1
    $others = if ($OtherRepos) { $OtherRepos -join ', ' } else { '(none)' }
    $resultFile = Join-Path $ResultsDir "$($Prompt.Id).json"

    $protocol = @"
SCOPE TRIM - an automated run. The work for step $($Prompt.Id) is DONE: it passes the build, the tests
and every prompt-specific assertion. An independent reviewer, reading only the diff against the
task, failed it for SCOPE CREEP with the findings below. You are a cheap, narrow pass whose only job
is to make the diff match the task - not to redo, improve or extend anything.

- Working repo: $RepoPath. Base commit: $BaseCommit. Do NOT edit anything under: $others.
- Read the findings, then ``git diff $BaseCommit`` (read-only git only: diff, show, status, log).
- For EACH finding, do exactly one of:
  (a) REVERT it. When a whole file's change is creep, ``git checkout $BaseCommit -- <file>`` (delete
      the file instead if it did not exist at the base). When only a hunk is creep, edit it back by
      hand to the base version. Then re-run the build and the tests named in the task's
      verification baseline to prove the revert broke nothing.
  (b) KEEP it, ONLY because the asked work cannot function without it (a DI registration, a route
      mapping, a shared contract, a guard the task itself changed). Then add or extend a
      ``scope_justification`` array in $resultFile with one sentence per kept item naming what
      breaks without it. Vague justifications ("it is cleaner") do not count - revert instead.
- Touch nothing the findings do not name. Do NOT run: git commit, git tag, git branch, git reset,
  git stash. Then RECONCILE $resultFile with the tree you are leaving behind: update
  ``changed_files``, and correct ``summary``, ``verification_performed``, ``decisions`` and
  ``deviations`` so that NOTHING in that file still describes work you reverted. This matters more
  than it looks: the runner re-runs the reviewer after you, the reviewer is handed this file
  alongside the diff, and a report claiming a file or a fix that is no longer in the diff reads to
  it as a job half done - which fails the step for the opposite reason it was failed the first
  time. Add one ``deviations`` line naming what you reverted and why. Keep ``status`` as is. The
  runner re-runs every gate after you.

=== REVIEWER FINDINGS ===
$Findings
"@

    $model = if ($M.TrimModel) { $M.TrimModel } else { 'sonnet' }
    $cli = @(
        '-p'
        '--model', $model
        '--effort', 'medium'
        '--permission-mode', 'bypassPermissions'
        '--output-format', 'json'
        '--session-id', $sessionId
        '--append-system-prompt', $protocol
    )
    foreach ($o in $OtherRepos) { $cli += @('--add-dir', $o) }

    Say "  trim session $sessionId ($model / medium)" 'DarkGray'
    $claude = Get-ClaudeExe
    Push-Location $RepoPath
    try {
        $raw = Get-Content -Raw $promptFile.FullName | & $claude @cli 2>&1 | Out-String
        $code = $LASTEXITCODE
    }
    finally { Pop-Location }

    $raw | Set-Content -Path $SessionLog -Encoding UTF8
    $parsed = $null
    $parsed = ConvertFrom-ClaudeOutput $raw

    return [pscustomobject]@{
        SessionId = $sessionId
        ExitCode  = $code
        IsError   = if ($parsed) { [bool]$parsed.is_error } else { $code -ne 0 }
        CostUsd   = if ($parsed) { $parsed.total_cost_usd } else { $null }
        NumTurns  = if ($parsed) { $parsed.num_turns } else { $null }
    }
}

# ---------------------------------------------------------------- independent audit
#
# Why this exists. The gates answer "does the tree satisfy these assertions" and DiffReview answers
# "does the diff match the task". Neither asks whether the code is RIGHT. On one long project the
# orchestrator audited every committed step by hand with a fresh read-only agent and found real
# defects in almost every step the gates had passed - data loss, wrong calculations, undo that did
# not undo, migrations that broke old files, tests that asserted nothing - while sets run without
# that audit committed the same classes of defect silently. So the audit is part of the runner and
# on by default:
#
#   audit session  read-only, fresh, never saw the implementer's reasoning; returns structured
#                  findings, each with file:line and a concrete reproduction. Zero is a valid answer.
#   fix session    reproduces each finding with a failing test FIRST, then fixes it - or DROPS it
#                  with a reason when it cannot be reproduced. That is the guard against an auditor
#                  that invents defects to have something to say.
#   gates          every gate of the step re-runs (DiffReview and Signoff excepted: the fix is not
#                  the task's diff, and the person signs the audited result).
#   commit         the fixes land in their own `fix(Pxx-audit)` commit beside the step's commit, so
#                  either can be reverted alone.
#
# Off for one step with  Audit = $false; AuditSkip = '<why>'  on its manifest entry, for the whole
# set with  Audit = $false  at the top, for one invocation with -NoAudit. A step whose change is
# documentation only is skipped automatically.

# Files whose change is never code. A step that touched only these has nothing for an auditor to run.
$AuditDocsOnly = '\.(md|markdown|txt|rst|adoc|png|jpe?g|gif|webp|bmp|ico|pdf)$'

function Get-AuditPlan($Prompt) {
    $plan = [ordered]@{
        On        = $true
        Why       = ''
        Model     = if ($M.AuditModel)     { $M.AuditModel }     else { 'opus' }
        Effort    = if ($M.AuditEffort)    { $M.AuditEffort }    else { 'high' }
        FixModel  = if ($M.AuditFixModel)  { $M.AuditFixModel }  else { 'opus' }
        FixEffort = if ($M.AuditFixEffort) { $M.AuditFixEffort } else { 'high' }
    }
    if ($NoAudit) { $plan.On = $false; $plan.Why = 'turned off for this invocation (-NoAudit)' }
    elseif ($M.ContainsKey('Audit') -and -not $M.Audit) { $plan.On = $false; $plan.Why = 'turned off for the whole set (manifest Audit = $false)' }
    elseif ($Prompt.ContainsKey('Audit') -and -not $Prompt.Audit) {
        $plan.On = $false
        $plan.Why = if ($Prompt.AuditSkip) { "turned off for this step: $($Prompt.AuditSkip)" } else { 'turned off for this step (Audit = $false)' }
    }
    elseif ($NoCommit) { $plan.On = $false; $plan.Why = 'no commit to audit (-NoCommit)' }
    return [pscustomobject]$plan
}

# Repo-relative files changed between two commits, minus the set's own folder.
function Get-ChangedFiles([string]$RepoPath, [string]$From, [string]$To) {
    @((Invoke-Git -RepoPath $RepoPath diff --name-only $From $To).Output -split "`r?`n" |
        Where-Object { $_ -and (-not $SetPathspec -or -not $_.StartsWith($SetPathspec, [StringComparison]::OrdinalIgnoreCase)) })
}

# Stage a step's work for a commit. The set's own folder is excluded; its real deliverables (SMOKE.md,
# a checklist, the sessions' corrections to their prompt files) are committed with the step that
# wrote them, its state/logs/results and the report never are.
function Add-StepChanges([string]$RepoPath, [switch]$WithSetDeliverables) {
    if ($SetPathspec) {
        Invoke-Git -RepoPath $RepoPath add -A -- . ":(exclude)$SetPathspec" | Out-Null
        if ($WithSetDeliverables) {
            Invoke-Git -RepoPath $RepoPath -GitArgs @(
                'add', '-A', '--', $SetPathspec,
                ":(exclude)$SetPathspec/state", ":(exclude)$SetPathspec/results",
                ":(exclude)$SetPathspec/logs", ":(exclude)$SetPathspec/report.html") | Out-Null
        }
    }
    else { Invoke-Git -RepoPath $RepoPath add -A | Out-Null }
}

# Put the tree back exactly at a commit, leaving the set's folder alone.
function Reset-Tree([string]$RepoPath, [string]$Commit) {
    Invoke-Git -RepoPath $RepoPath reset -q --hard $Commit | Out-Null
    if ($SetPathspec) { Invoke-Git -RepoPath $RepoPath -GitArgs @('clean', '-fdq', '-e', $SetPathspec) | Out-Null }
    else { Invoke-Git -RepoPath $RepoPath clean -fdq | Out-Null }
}

function Show-GateResults($GateResults) {
    Say ''
    foreach ($g in $GateResults) {
        if ($g.Ok) { Say ("    PASS  {0}" -f $g.Name) 'Green' }
        else { Say ("    FAIL  {0}" -f $g.Name) 'Red'; Say ("          {0}" -f $g.Detail) 'DarkRed' }
    }
    Say ''
}

function Get-CommandsText {
    if (-not $M.Commands -or -not $M.Commands.Count) { return '  (the manifest names none - find the project''s own)' }
    (($M.Commands.Keys | Sort-Object | ForEach-Object { "  $_ : $($M.Commands[$_])" }) -join "`n")
}

# Run one `claude -p` with everything on stdin (a long findings list does not fit the 32k Windows
# command line that --append-system-prompt has to share) and return the parsed result.
function Invoke-ClaudeJob {
    param([string]$Text, [string[]]$Cli, [string]$RepoPath, [string]$SessionLog)
    $claude = Get-ClaudeExe
    Push-Location $RepoPath
    try { $raw = $Text | & $claude @Cli 2>&1 | Out-String; $code = $LASTEXITCODE }
    finally { Pop-Location }
    $raw | Set-Content -Path $SessionLog -Encoding UTF8
    $parsed = ConvertFrom-ClaudeOutput $raw
    $structured = $null
    if ($parsed) {
        if ($parsed.structured_output) { $structured = $parsed.structured_output }
        elseif ($parsed.result -is [string]) { try { $structured = $parsed.result | ConvertFrom-Json } catch { } }
        elseif ($parsed.result) { $structured = $parsed.result }
    }
    return [pscustomobject]@{
        ExitCode   = $code
        IsError    = if ($parsed) { [bool]$parsed.is_error } else { $code -ne 0 }
        CostUsd    = if ($parsed) { $parsed.total_cost_usd } else { $null }
        NumTurns   = if ($parsed) { $parsed.num_turns } else { $null }
        Structured = $structured
    }
}

function Invoke-AuditSession {
    param($Prompt, $Plan, [string]$RepoPath, [string[]]$OtherRepos, [string]$BaseCommit,
          [string]$Head, [string[]]$Files, [string]$GateLogDir)

    $promptFile = Get-ChildItem -Path $PromptsDir -Filter "$($Prompt.Id)-*.md" | Select-Object -First 1
    $brief = Get-Content -Raw $promptFile.FullName
    $resultFile = Join-Path $ResultsDir "$($Prompt.Id).json"
    $scratch = Join-Path $GateLogDir 'audit-scratch'
    New-Item -ItemType Directory -Force -Path $scratch | Out-Null
    $others = if ($OtherRepos) { $OtherRepos -join ', ' } else { '(none)' }
    $gates = (@($Prompt.Gates) | ForEach-Object { $_.Type }) -join ', '
    $stat = (Invoke-Git -RepoPath $RepoPath diff --stat $BaseCommit $Head).Output

    $noteBlock = if ($Prompt.Note) { "`n=== STANDING DECISIONS - authorised after the task was written; they SUPERSEDE it ===`n$($Prompt.Note)`n" } else { '' }
    $projectBlock = ''
    if ($M.AuditBrief) {
        $bp = Join-Path $SetRoot $M.AuditBrief
        if (Test-Path $bp) { $projectBlock = "`n=== PROJECT-SPECIFIC AUDIT NOTES (from the set's author) ===`n" + (Get-Content -Raw $bp) + "`n" }
    }

    $ask = @"
You are auditing ONE committed step of an automated prompt run. You did not write this code and you
have none of its author's reasoning.

A separate session implemented the step from the task below. The runner's gates already passed
(ResultsFile, $gates), and where a DiffReview gate is listed a reviewer confirmed the diff matches the
task's scope. Gates prove assertions, not correctness. In real runs of this harness, independent
audits found real defects in almost every step the gates had passed: data the user loses, wrong
calculations, undo that does not undo, migrations that break old files, UI states that crash, tests
that assert nothing, docs describing behaviour the code does not have. Find those - and only those.

== Where things are ==
- Repo: $RepoPath. The step's change is ``git diff $BaseCommit $Head`` ($($Files.Count) files, stat
  below). Read the code AROUND the change, not only the hunks: defects live where new code meets old.
- The task is below. The implementer's report (claims to check, not facts): $resultFile
- Project instructions: CLAUDE.md / AGENTS.md at the repo root, if present.
- The project's commands:
$(Get-CommandsText)
- Other repos, reference only: $others

== Rules ==
- READ-ONLY. You cannot edit files. You MAY run the build, the tests, and small scripts that confirm a
  suspicion. Every scratch file goes under $scratch - never inside the repo. No git command that
  changes state (commit, checkout, reset, stash, clean, branch, tag). Never delete anything outside
  $scratch.
- Windows: in Node or Python scripts write drive paths (D:/...); a /c/... path resolves to \c on the
  current drive.
- ONE SHOT: you are a single non-interactive run. No background tasks, no waiting for a wake-up.
  Subagents only in the foreground - delegate bulk reading to them and take back short answers.
  Never print a whole build or test log into the conversation; redirect it to a file under $scratch.

== What to look for, most valuable first ==
1. Wrong behaviour: wrong results or units, edge cases (empty, zero, one, very large, duplicates,
   unicode / right-to-left text, concurrent edits), data the user loses (save/load round-trips,
   migrations, undo/redo, deletes, caches), validation bypassed, security holes (injection, missing
   authorisation, secrets in code or logs).
2. Acceptance criteria of the task the change does not actually meet, claims in the report that are
   not true in the code, and tests that would still pass if the feature were broken.
3. Crashes and broken states: errors swallowed, empty / loading / error states, resources not released.
4. Regressions in existing behaviour the change touches.
5. Documentation that disagrees with the code.

NOT findings: style, naming, "could be refactored", features the task did not ask for, work a later
step of the set plainly owns, and anything you merely suspect but could not pin down.

Every finding is concrete: file and line, what is wrong, a reproduction (input or state -> wrong
output; say whether you confirmed it by running something), and the fix you suggest.

ZERO FINDINGS IS A VALID RESULT. Do not invent defects to have something to report: a fixer will try
to reproduce every finding with a failing test and drops any it cannot, so an invented finding only
wastes a session. Put what you checked and found correct in checked_ok.

Severity: high = data loss, wrong results a user relies on, a security hole, a crash in a main path;
medium = wrong in a less common path, or an acceptance criterion not met; low = minor but real.
Number the findings A1, A2, ... most severe first.
$projectBlock
=== TASK ===
$brief
$noteBlock
=== DIFF STAT ===
$stat
"@

    $schema = '{"type":"object","properties":{"findings":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"severity":{"type":"string","enum":["high","medium","low"]},"title":{"type":"string"},"file":{"type":"string"},"line":{"type":"integer"},"problem":{"type":"string"},"reproduction":{"type":"string"},"suggested_fix":{"type":"string"}},"required":["id","severity","title","file","problem","reproduction","suggested_fix"]}},"checked_ok":{"type":"array","items":{"type":"string"}}},"required":["findings","checked_ok"]}'
    $cli = @(
        '-p'
        '--model', $Plan.Model
        '--effort', $Plan.Effort
        '--permission-mode', 'bypassPermissions'
        '--output-format', 'json'
        '--json-schema', $schema
        # An auditor that can edit is not an auditor.
        '--disallowed-tools', 'Edit', 'Write', 'NotebookEdit'
    )
    foreach ($o in $OtherRepos) { $cli += @('--add-dir', $o) }
    if ($M.BudgetUsd) { $cli += @('--max-budget-usd', "$($M.BudgetUsd)") }

    Say "  audit session ($($Plan.Model) / $($Plan.Effort)) over $($Files.Count) file(s)" 'DarkGray'
    return Invoke-ClaudeJob -Text $ask -Cli $cli -RepoPath $RepoPath -SessionLog (Join-Path $GateLogDir 'audit-session.json')
}

function Invoke-AuditFixSession {
    param($Prompt, $Plan, [string]$RepoPath, [string[]]$OtherRepos, [string]$Head,
          [string]$FindingsJson, [string]$SessionLog, [string]$ExtraFailure)

    $promptFile = Get-ChildItem -Path $PromptsDir -Filter "$($Prompt.Id)-*.md" | Select-Object -First 1
    $brief = Get-Content -Raw $promptFile.FullName
    $fixFile = Join-Path $ResultsDir "$($Prompt.Id)-fix.json"
    $others = if ($OtherRepos) { $OtherRepos -join ', ' } else { '(none)' }
    $scratch = Join-Path (Join-Path $LogsDir $Prompt.Id) 'audit-scratch'

    $retryBlock = if ($ExtraFailure) { @"

RETRY - your previous fix pass on these same findings was rejected by the runner's gates:
$ExtraFailure
The tree still holds that pass's work. Fix ONLY what failed, then rewrite $fixFile for the whole pass.
"@ } else { '' }

    $ask = @"
AUDIT FIX - an automated run. Step $($Prompt.Id) is committed ($Head) and passed its gates. An
independent auditor, reading the change cold, reported the findings below. Your job is to fix the
REAL ones, test first, and nothing else.

- Working repo: $RepoPath. Do NOT edit anything under: $others.
- For EACH finding, in order:
  1. REPRODUCE it with an automated test that FAILS on the current code - in the project's own test
     framework, beside the existing tests of that code, named after the behaviour. Run it and see it
     fail. Where that layer truly has no test harness, a reproduction script under $scratch, run
     before and after the fix, is acceptable; say so.
  2. If you cannot reproduce it, or the code is in fact right and the auditor misread it, DROP it:
     change nothing for it and give the reason. A dropped finding is a correct outcome, not a failure
     - auditors are wrong sometimes, and a "fix" for a non-defect is a regression.
  3. If it reproduces: make the smallest change that fixes it, and the test now passes.
- Touch nothing the findings do not need: no refactors, no renames, no improvements of your own.
- Do NOT run: git commit, git tag, git branch, git checkout, git reset, git stash, git clean. The
  runner commits your work after its gates pass, in its own commit beside the step's.
- Context: delegate bulk reading to foreground subagents, never print a whole build or test log into
  the conversation (redirect it to a file and read the tail), run narrow tests while iterating and the
  full suite once at the end. ONE SHOT: no background tasks, nothing waits for a wake-up; long commands
  run in the foreground.
- The project's commands - run the full set before you finish:
$(Get-CommandsText)
- Your LAST action is to write $fixFile as valid JSON (forward slashes in paths):
  {
    "id": "$($Prompt.Id)",
    "fixed":   [ { "id": "A1", "test": "file and test name that reproduces it", "change": "one sentence" } ],
    "dropped": [ { "id": "A2", "reason": "why it is not a defect or could not be reproduced" } ],
    "changed_files": ["repo-relative paths"],
    "verification_performed": ["what you ran, and what it reported"]
  }
  EVERY finding id appears in exactly one of "fixed" or "dropped". The runner checks this.
$retryBlock

=== AUDIT FINDINGS ===
$FindingsJson

=== THE STEP'S TASK (for context - it is done; do not redo or extend it) ===
$brief
"@

    $cli = @(
        '-p'
        '--model', $Plan.FixModel
        '--effort', $Plan.FixEffort
        '--permission-mode', 'bypassPermissions'
        '--output-format', 'json'
    )
    foreach ($o in $OtherRepos) { $cli += @('--add-dir', $o) }
    if ($M.BudgetUsd) { $cli += @('--max-budget-usd', "$($M.BudgetUsd)") }
    $mcpConfig = Join-Path $RepoPath '.mcp.json'
    if (Test-Path $mcpConfig) { $cli += @('--strict-mcp-config', '--mcp-config', $mcpConfig) }

    Say "  fix session ($($Plan.FixModel) / $($Plan.FixEffort))" 'DarkGray'
    return Invoke-ClaudeJob -Text $ask -Cli $cli -RepoPath $RepoPath -SessionLog $SessionLog
}

function Test-FixResultsFile([string]$Id, [string[]]$FindingIds) {
    $f = Join-Path $ResultsDir "$Id-fix.json"
    if (-not (Test-Path $f)) { return New-GateResult 'FixResultsFile' $false "missing $f - the fix session did not report" }
    try { $j = Get-Content -Raw $f | ConvertFrom-Json }
    catch { return New-GateResult 'FixResultsFile' $false "unparseable JSON in $f" }
    $seen = @(@($j.fixed) + @($j.dropped) | Where-Object { $_ } | ForEach-Object { [string]$_.id })
    $missing = @($FindingIds | Where-Object { $_ -notin $seen })
    if ($missing.Count) { return New-GateResult 'FixResultsFile' $false ('neither fixed nor dropped: ' + ($missing -join ', ')) }
    return New-GateResult 'FixResultsFile' $true ("fixed {0}, dropped {1}" -f @($j.fixed | Where-Object { $_ }).Count, @($j.dropped | Where-Object { $_ }).Count)
}

# The audit of one committed step. Returns $true when the run may go on, $false when it must stop.
function Invoke-AuditPhase {
    param($Prompt, $Ps, $State, [string]$RepoPath, [string[]]$OtherRepos, [string]$GateLogDir)

    $plan = Get-AuditPlan $Prompt
    $id = $Prompt.Id
    if (-not $Ps.audit) { $Ps.audit = @{} }

    if (-not $plan.On) {
        $Ps.audit = @{ status = 'skipped'; why = $plan.Why }
        Save-State $State
        Say "  audit skipped - $($plan.Why)" 'DarkGray'
        return $true
    }

    $head = Get-Head $RepoPath
    $files = Get-ChangedFiles $RepoPath $Ps.baseCommit $head
    if (-not $files.Count) {
        $Ps.audit = @{ status = 'skipped'; why = 'the step changed nothing in the repo' }
        Save-State $State; Say '  audit skipped - nothing changed' 'DarkGray'; return $true
    }
    $code = @($files | Where-Object { $_ -notmatch $AuditDocsOnly })
    if (-not $code.Count) {
        $Ps.audit = @{ status = 'skipped'; why = "documentation only ($($files.Count) file(s))" }
        Save-State $State; Say '  audit skipped - documentation only' 'DarkGray'; return $true
    }

    $Ps.status = 'AUDITING'
    Save-State $State
    Say ''
    Say "  AUDIT  $id  ($($Ps.baseCommit.Substring(0,8))..$($head.Substring(0,8)))" 'Cyan'

    $auditFile = Join-Path $ResultsDir "$id-audit.json"
    $findings = $null

    # A resumed audit reuses the findings it already has, as long as nothing was committed since.
    if ($Ps.audit.auditedHead -eq $head -and (Test-Path $auditFile)) {
        try { $findings = @((Get-Content -Raw $auditFile | ConvertFrom-Json).findings | Where-Object { $_ }) } catch { $findings = $null }
        if ($null -ne $findings) { Say "  reusing $($findings.Count) finding(s) from $auditFile" 'DarkGray' }
    }

    if ($null -eq $findings) {
        $a = Invoke-AuditSession -Prompt $Prompt -Plan $plan -RepoPath $RepoPath -OtherRepos $OtherRepos `
            -BaseCommit $Ps.baseCommit -Head $head -Files $files -GateLogDir $GateLogDir
        if ($a.CostUsd) { $Ps.costUsd = [double]$Ps.costUsd + $a.CostUsd; $Ps.auditCostUsd = [double]$Ps.auditCostUsd + $a.CostUsd }
        Say ("  audit done: {0} turns, {1}" -f $a.NumTurns, $(if ($a.CostUsd) { '${0:N2}' -f $a.CostUsd } else { 'cost n/a' })) 'DarkGray'

        # The auditor cannot edit, but it can run builds and scripts; whatever it left behind goes.
        if (-not (Test-CleanTree $RepoPath)) {
            Say '  the audit session left changes in the tree - discarding them' 'Yellow'
            Reset-Tree $RepoPath $head
        }

        if (-not $a.Structured -or $null -eq $a.Structured.findings) {
            $Ps.audit = @{ status = 'audit-error'; why = 'the audit session returned nothing usable' }
            $Ps.status = 'AUDIT_FAILED'
            Save-State $State
            Say "  the audit session returned nothing usable - see $(Join-Path $GateLogDir 'audit-session.json')" 'Red'
            Say "  Re-run to audit again, or -Only $id -NoAudit to accept the step without an audit." 'Cyan'
            Write-Report | Out-Null
            return $false
        }
        $findings = @($a.Structured.findings | Where-Object { $_ })
        [ordered]@{
            id         = $id
            base       = $Ps.baseCommit
            head       = $head
            model      = "$($plan.Model) / $($plan.Effort)"
            findings   = $findings
            checked_ok = @($a.Structured.checked_ok)
        } | ConvertTo-Json -Depth 6 | Set-Content -Path $auditFile -Encoding UTF8
        $Ps.audit = @{ status = 'audited'; auditedHead = $head; findings = $findings.Count }
        Save-State $State
    }

    if (-not $findings.Count) {
        $Ps.audit.status = 'clean'
        Save-State $State
        Say '  audit: no defects found' 'Green'
        return $true
    }

    foreach ($f in $findings) { Say ("    {0}  [{1}]  {2}" -f $f.id, $f.severity, $f.title) 'Yellow' }

    $findingIds = @($findings | ForEach-Object { [string]$_.id })
    $findingsJson = $findings | ConvertTo-Json -Depth 6
    Remove-Item (Join-Path $ResultsDir "$id-fix.json") -ErrorAction SilentlyContinue
    $fixGates = @($Prompt.Gates | Where-Object { $_.Type -notin @('DiffReview', 'Signoff') })
    $failure = $null
    $ok = $false

    for ($n = 1; $n -le 2; $n++) {
        $fx = Invoke-AuditFixSession -Prompt $Prompt -Plan $plan -RepoPath $RepoPath -OtherRepos $OtherRepos `
            -Head $head -FindingsJson $findingsJson -SessionLog (Join-Path $GateLogDir "audit-fix-$n.json") -ExtraFailure $failure
        if ($fx.CostUsd) { $Ps.costUsd = [double]$Ps.costUsd + $fx.CostUsd; $Ps.auditCostUsd = [double]$Ps.auditCostUsd + $fx.CostUsd }
        Save-State $State
        if ($fx.IsError) { Say "  fix session ended in error - see audit-fix-$n.json" 'Red' }
        Say ("  fix done: {0} turns, {1}" -f $fx.NumTurns, $(if ($fx.CostUsd) { '${0:N2}' -f $fx.CostUsd } else { 'cost n/a' })) 'DarkGray'

        $results = @(Test-FixResultsFile $id $findingIds)
        foreach ($g in $fixGates) {
            $results += Invoke-Gate -Gate $g -Prompt $Prompt -RepoPath $RepoPath -GateLogDir $GateLogDir -BaseCommit $Ps.baseCommit
        }
        Show-GateResults $results
        $failed = @($results | Where-Object { -not $_.Ok })
        if (-not $failed.Count) { $ok = $true; break }
        $failure = ($failed | ForEach-Object { "GATE {0} FAILED:`n{1}" -f $_.Name, $_.Detail }) -join "`n`n"
        $failure | Set-Content -Path (Join-Path $GateLogDir "audit-fix-failure-$n.txt") -Encoding UTF8
    }

    if (-not $ok) {
        Add-StepChanges $RepoPath
        $snap = Join-Path $GateLogDir ('audit-fix-rollback-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.patch')
        (Invoke-Git -RepoPath $RepoPath diff --cached $head --binary).Output | Set-Content -Path $snap -Encoding UTF8
        Reset-Tree $RepoPath $head
        $Ps.audit.status = 'fix-failed'
        $Ps.status = 'AUDIT_FAILED'
        Save-State $State
        Say "  the audit's fixes failed the gates twice - rolled back to $($head.Substring(0,8)) (the step itself stays committed)." 'Red'
        Say "  Findings: $auditFile" 'Cyan'
        Say "  Fix attempt saved: $snap" 'Cyan'
        Say "  Fix them by hand and commit, then -Only $id -NoAudit to accept; or re-run to let a new fix session try." 'Cyan'
        Write-Report | Out-Null
        return $false
    }

    $fix = Get-Content -Raw (Join-Path $ResultsDir "$id-fix.json") | ConvertFrom-Json
    $fixed = @($fix.fixed | Where-Object { $_ })
    $dropped = @($fix.dropped | Where-Object { $_ })
    $Ps.audit.fixed = $fixed.Count
    $Ps.audit.dropped = $dropped.Count

    if (-not $fixed.Count) {
        # Nothing reproduced. Whatever the session left (a reproduction attempt) is not a fix.
        if (-not (Test-CleanTree $RepoPath)) { Reset-Tree $RepoPath $head }
        $Ps.audit.status = 'all-dropped'
        Save-State $State
        Say "  audit: all $($dropped.Count) finding(s) dropped as not reproducible" 'Green'
        return $true
    }

    if (Test-CleanTree $RepoPath) {
        $Ps.audit.status = 'fixed-no-diff'
        Save-State $State
        Say '  the fix session reported fixes but left no change in the tree - recorded, not committed' 'Yellow'
        return $true
    }

    $byId = @{}; foreach ($f in $findings) { $byId[[string]$f.id] = $f }
    $lines = @("fix($id-audit): $($fixed.Count) defect(s) found by the independent audit", '')
    foreach ($x in $fixed) {
        $f = $byId[[string]$x.id]
        $lines += if ($f) { "- $($x.id) [$($f.severity)] $($f.title)" } else { "- $($x.id) $($x.change)" }
    }
    if ($dropped.Count) { $lines += ''; $lines += "Dropped as not reproducible: " + (($dropped | ForEach-Object { $_.id }) -join ', ') }
    $msgFile = Join-Path $GateLogDir 'audit-commit-message.txt'
    $lines -join "`n" | Set-Content -Path $msgFile -Encoding UTF8
    Add-StepChanges $RepoPath
    $c = Invoke-Git -RepoPath $RepoPath commit -q -F $msgFile
    if ($c.ExitCode -ne 0) { throw "audit fix commit failed in ${RepoPath}: $($c.Output)" }
    $Ps.audit.fixCommit = Get-Head $RepoPath
    $Ps.audit.status = 'fixed'
    Save-State $State
    Say ("  audit: fixed {0}, dropped {1} - committed {2}" -f $fixed.Count, $dropped.Count, $Ps.audit.fixCommit.Substring(0, 8)) 'Green'
    return $true
}

# A step whose work (and audit) is finished: stop for a person on tiers D/E, otherwise DONE.
# Returns $true when the run may go on.
function Complete-Step($Prompt, $Ps, $State) {
    if ($Prompt.Tier -in @('D', 'E')) {
        $Ps.status = 'AWAITING_SIGNOFF'
        $Ps.finished = (Get-Date).ToString('o')
        Save-State $State
        Show-SignoffChecklist $Prompt
        Write-Report | Out-Null
        return $false
    }
    $Ps.status = 'DONE'
    $Ps.finished = (Get-Date).ToString('o')
    Save-State $State
    Say "  $($Prompt.Id) DONE" 'Green'
    return $true
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
            'DONE' { 'Green' } 'FAILED' { 'Red' } 'AUDIT_FAILED' { 'Red' }
            'AWAITING_SIGNOFF' { 'Yellow' } 'AUDITING' { 'Yellow' } default { 'DarkGray' }
        }
        $sha = if ($ps.commit) { $ps.commit.Substring(0, 8) } else { '        ' }
        $aud = ''
        if ($ps.audit -and $ps.audit.status) {
            $aud = "  [audit: $($ps.audit.status)"
            if ($ps.audit.findings) { $aud += ", $($ps.audit.findings) found" }
            if ($null -ne $ps.audit.fixed) { $aud += ", $($ps.audit.fixed) fixed" }
            $aud += ']'
        }
        Say ('  {0,2}. {1}  {2,-16} tier {3}  {4}  {5}{6}' -f $i, $p.Id, $ps.status, $p.Tier, $sha, $p.Title, $aud) $colour
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
        $ap = Get-AuditPlan $p
        if ($ap.On) { Say ("     audit    on ({0} / {1}; fixes {2} / {3}) - skipped by itself if the step changes docs only" -f $ap.Model, $ap.Effort, $ap.FixModel, $ap.FixEffort) 'DarkGray' }
        else { Say ("     audit    OFF - {0}" -f $ap.Why) 'Yellow' }
        if ($p.Tier -in @('D', 'E')) { Say '     STOPS for human sign-off' 'Yellow' }
    }
    Say ''
    Say ("  {0} prompt(s). Sign-off stops: {1}" -f $selected.Count,
        ((($selected | Where-Object { $_.Tier -in @('D','E') }).Id -join ', ') -replace '^$', 'none')) 'Cyan'
    return
}

# ---------------------------------------------------------------- the run

$state = Get-State
# Only branch the repos a prompt actually EDITS. A repo listed purely as reference material is
# attached read-only with --add-dir, and checking a branch out inside it moves whatever the user
# had uncommitted there onto a branch of this set's name - a visible edit to a repo the prompts
# declare untouchable.
$editedRepos = @($M.Prompts | ForEach-Object { Resolve-RepoPath $_.Repo } | Sort-Object -Unique)
foreach ($r in $editedRepos) { Confirm-Branch $r }

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

    # The step is committed; only its audit is outstanding (interrupted, or its fixes failed). Never
    # re-run the prompt for that - resume the audit, or with -NoAudit accept the step as it stands.
    if ($ps.status -in @('AUDITING', 'AUDIT_FAILED')) {
        Rule ("[{0}/{1}]  {2}  -  audit of the committed step" -f $index, $M.Prompts.Count, $prompt.Id)
        if (-not (Test-CleanTree $repoPath)) {
            Say "  $repoPath has uncommitted changes. Commit what you fixed by hand (then -NoAudit to accept), or discard it." 'Red'; return
        }
        $gateLogDir = Join-Path $LogsDir $prompt.Id
        New-Item -ItemType Directory -Force -Path $gateLogDir | Out-Null
        if ($NoAudit) {
            if (-not $ps.audit) { $ps.audit = @{} }
            $ps.audit.status = 'accepted-by-orchestrator'
            $ps.audit.why = 'accepted with -NoAudit after the audit stopped'
            Say '  audit accepted as it stands (-NoAudit)' 'Yellow'
        }
        elseif (-not (Invoke-AuditPhase -Prompt $prompt -Ps $ps -State $state -RepoPath $repoPath `
                        -OtherRepos $otherRepos -GateLogDir $gateLogDir)) { return }
        if (-not (Complete-Step $prompt $ps $state)) { return }
        continue
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
        # Accumulate: a rolled-back attempt still cost money, and the ledger/report are what
        # the user reads to understand spend. Overwriting hid every failed attempt. The per-attempt
        # list is what answers "how much did the retry cost" without opening the session logs.
        if ($session.CostUsd) { $ps.costUsd = [double]$ps.costUsd + $session.CostUsd }
        $ps.attemptCosts = @(@($ps.attemptCosts) + @([double]$session.CostUsd))
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

        # SCOPE TRIM. When the ONLY failure is the reviewer's scope_creep verdict - every mechanical
        # gate is green, the work is done - a full retry session at the prompt's model and effort is
        # the wrong tool: it re-reads the whole prompt and codebase to delete a few hunks. A cheap
        # trim session removes exactly what the reviewer named, or justifies what has to stay, and
        # the gates re-run. One trim per prompt; if it does not settle the verdict, the ordinary
        # retry follows with the verbatim failure as before.
        $onlyCreep = ($failed.Count -eq 1) -and ($failed[0].Name -eq 'DiffReview') -and
                     ($failed[0].Detail -match '^verdict=scope_creep')
        if ($onlyCreep -and -not $ps.trimmed) {
            $ps.trimmed = $true
            Say '  only DiffReview failed (scope_creep) - running a scope trim instead of a full retry' 'Yellow'
            $trimLog = Join-Path $gateLogDir "trim-$attempt.json"
            $failed[0].Detail | Set-Content -Path (Join-Path $gateLogDir "scope-creep-$attempt.txt") -Encoding UTF8

            $trim = Invoke-TrimSession -Prompt $prompt -RepoPath $repoPath -OtherRepos $otherRepos `
                -SessionLog $trimLog -BaseCommit $ps.baseCommit -Findings $failed[0].Detail
            if ($trim.CostUsd) {
                $ps.costUsd = [double]$ps.costUsd + $trim.CostUsd
                $ps.trimCostUsd = [double]$ps.trimCostUsd + $trim.CostUsd
            }
            Save-State $state
            if ($trim.IsError) { Say "  trim session ended in error - see $trimLog" 'Red' }
            Say ("  trim done: {0} turns, {1}" -f $trim.NumTurns,
                $(if ($trim.CostUsd) { '${0:N2}' -f $trim.CostUsd } else { 'cost n/a' })) 'DarkGray'

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
        }

        $failureReport = ($failed | ForEach-Object { "GATE {0} FAILED:`n{1}" -f $_.Name, $_.Detail }) -join "`n`n"
        $failureReport | Set-Content -Path (Join-Path $gateLogDir "gate-failure-$attempt.txt") -Encoding UTF8
    }

    if (-not $passed) {
        Say "  $($prompt.Id) failed its gates after $MaxAttempts attempt(s). Rolling back." 'Red'
        # Keep the rolled-back work as a patch: a step that failed only on a flaky live-site gate
        # is recoverable with `git apply` instead of a whole new session.
        if ($SetPathspec) { Invoke-Git -RepoPath $repoPath add -A -N -- . ":(exclude)$SetPathspec" | Out-Null }
        else { Invoke-Git -RepoPath $repoPath add -A -N | Out-Null }
        $snap = Join-Path $gateLogDir ('rollback-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.patch')
        (Invoke-Git -RepoPath $repoPath diff $ps.baseCommit --binary).Output | Set-Content -Path $snap -Encoding UTF8
        Say "  rolled-back work saved to $snap" 'DarkGray'
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
        # A set can hold real deliverables next to its bookkeeping - SMOKE.md, a checklist, the
        # sessions' corrections to their prompt files. Left uncommitted they stay in the working
        # tree for the whole run and reappear in every later step's diff as that step's work, so
        # commit them with the step that wrote them.
        Add-StepChanges $repoPath -WithSetDeliverables
        $c = Invoke-Git -RepoPath $repoPath commit -m "$($prompt.Id): $($prompt.Title)"
        if ($c.ExitCode -ne 0) { throw "commit failed in ${repoPath}: $($c.Output)" }
        Invoke-Git -RepoPath $repoPath tag -f "$($M.Name)/$($prompt.Id)" | Out-Null
        $ps.commit = Get-Head $repoPath
        Say "  committed $($ps.commit.Substring(0,8))" 'Green'
    }

    # The independent audit runs on the committed step, before a person is asked to sign it off -
    # they should judge the audited result, not the one the audit is about to change.
    if (-not (Invoke-AuditPhase -Prompt $prompt -Ps $ps -State $state -RepoPath $repoPath `
                -OtherRepos $otherRepos -GateLogDir $gateLogDir)) { return }

    if (-not (Complete-Step $prompt $ps $state)) { return }
}

Save-State $state
Show-Status
Write-Report | Out-Null
Say ''
Say '  run complete' 'Green'
