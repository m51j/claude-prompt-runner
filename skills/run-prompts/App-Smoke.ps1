<#
.SYNOPSIS
    Launch, inspect, drive and screenshot a Windows desktop app (WPF or WinForms) for verification.

.DESCRIPTION
    One helper shared by Run-Prompts.ps1 and by the agent sessions, so that "run the app and check
    it works" means the same thing every time instead of being reinvented per task.

    It always prints a single JSON object on stdout (the LAST line) and exits 0 on success, 1 on
    failure, so both a script and an agent can consume it. Artifacts (screenshots, UI Automation
    dumps, log tails) land in -OutDir.

    Scenarios
      Start           launch, wait for a main window, assert still alive, collect artifacts, kill
      SecondInstance  launch twice; the SECOND copy must exit quickly (single-instance guards)
      Inspect         dump the UI Automation element tree of a running app's windows as text
      Invoke/SetText  act on a control by AutomationId or by its visible label
      Click           a real cursor click at screen coordinates
      Hover           move the real cursor onto an element (by AutomationId/Name) or to -X/-Y; no click
      Keys            focus the app's main window and send keystrokes
      Screenshot      full-screen PNG (open it with the Read tool - it renders images)
      Kill            kill every running copy

.NOTES
    This drives whatever app you point -Exe at; it knows nothing about any particular one.

    Honest limits: if the app cannot start for its own reasons - a missing licence, an unreachable
    database, absent third-party controls - then a failing Start means the app is broken, not the
    change under test. Prove Start works on a clean tree before trusting any of this.

    A LOCKED WORKSTATION defeats every scenario that clicks or types: synthesized input cannot
    reach a locked desktop. Toggling a network adapter needs admin rights and is deliberately not
    scripted here.

.EXAMPLE
    App-Smoke.ps1 -Scenario Start -Exe 'C:\App\bin\Debug\App.exe' -KeepRunning
    App-Smoke.ps1 -Scenario Inspect
    App-Smoke.ps1 -Scenario SetText -AutomationId 'UserBox' -Text 'admin'
    App-Smoke.ps1 -Scenario Invoke  -Name 'Save'
    App-Smoke.ps1 -Scenario Hover   -AutomationId 'Card_1'
    App-Smoke.ps1 -Scenario Start -Exe ... -EnvVars @{ MYAPP_DATA_ROOT = 'C:\temp\data' }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Start', 'SecondInstance', 'Inspect', 'Keys', 'Invoke', 'SetText', 'Click', 'Hover', 'Screenshot', 'Kill')]
    [string]$Scenario,

    # The executable to drive. Required for Start and SecondInstance; the other scenarios find the
    # already-running process, so they only need it to derive the process name.
    [string]$Exe,

    # Environment variables to set for the launched process, e.g.
    #   -EnvVars @{ MYAPP_DATA_ROOT = 'C:\temp\run1'; MYAPP_SCREENSHOT_DIR = 'C:\temp\shots' }
    # Many apps expose a switch that redirects their data folder or dumps their own screenshots;
    # if yours does, this is how a run points it somewhere disposable. Cleared again on exit.
    [hashtable]$EnvVars,

    # Searched for recent *.log files alongside the executable's own folder.
    [string]$LogDir,

    [int]$WaitSeconds = 40,

    # Inspect: window name substring filter. Empty = every top-level window of the process.
    [string]$Title,

    # Keys: SendKeys syntax, e.g. '{DOWN}{ENTER}' or '1234{ENTER}'
    [string]$Send,

    # Invoke/SetText/Hover: which element, by AutomationId (preferred) or by visible Name.
    [string]$AutomationId,
    [string]$Name,

    # SetText: the value to write into the element.
    [string]$Text,

    # Click, and Hover when no element is named: absolute screen coordinates.
    [int]$X,
    [int]$Y,

    # Start: the app exiting on its own is an ACCEPTABLE outcome (gates that expect a blocking
    # dialog, e.g. the P10 activation gate refusing an unactivated install).
    [switch]$AllowExit,

    # Leave the process running for a follow-up Inspect/Keys/Screenshot call.
    [switch]$KeepRunning,

    [string]$OutDir
)

$ErrorActionPreference = 'Stop'

# يجب أن يقع هذا قبل أيّ قراءة إحداثيّات أو التقاط صورة. بلا وعيٍ بكثافة النقاط يُشغَّل
# PowerShell موهوماً: يُسلّم UI Automation إحداثيّات منطقيّة، ويُسلّم SetCursorPos إحداثيّات
# فيزيائية، ويُرجع CopyFromScreen صورةً مُمدَّدة — فالضغط يقع بعيداً عن هدفه على شاشة مقيسة،
# أو على شاشة ثانية بمقياس مختلف. أعراضه أنّ الضغطة «تنجح» ولا يحدث شيء.
try {
	Add-Type -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
'@ -Name 'Win32Dpi' -Namespace '' -ErrorAction Stop
	# DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
	[void][Win32Dpi]::SetProcessDpiAwarenessContext([IntPtr]::new(-4))
}
catch {
	# ويندوز أقدم من 1703، أو رُفض لأنّ الوعي مضبوط سلفاً: تُستأنف الأمور بالسلوك القديم.
}

if ($Scenario -in 'Start', 'SecondInstance' -and -not $Exe) {
    throw "-Exe is required for the $Scenario scenario."
}
if (-not $OutDir) {
    $OutDir = Join-Path ([System.IO.Path]::GetTempPath()) ('app-smoke\{0}' -f $Scenario)
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# The scenarios that act on an already-running app find it by process name. With no -Exe, fall
# back to the single running candidate if there is exactly one.
$procName = if ($Exe) { [System.IO.Path]::GetFileNameWithoutExtension($Exe) } else { $null }
if (-not $procName) {
    $running = @(Get-Process | Where-Object { $_.MainWindowHandle -ne 0 -and $_.Path } )
    if ($running.Count -eq 1) { $procName = $running[0].ProcessName }
    else { throw '-Exe is required: cannot tell which running process you mean.' }
}

$result = [ordered]@{
    scenario   = $Scenario
    ok         = $false
    exe        = $Exe
    outDir     = $OutDir
    notes      = @()
    artifacts  = @()
}

function Add-Note([string]$text) { $script:result.notes += $text }
function Add-Artifact([string]$path) { if (Test-Path $path) { $script:result.artifacts += (Resolve-Path $path).Path } }

function Stop-AllCopies {
    Get-Process -Name $procName -ErrorAction SilentlyContinue | ForEach-Object {
        try { $_.Kill() } catch { }
    }
    Start-Sleep -Milliseconds 500
}

function Start-App {
    param([string]$Label = 'app')

    if ($EnvVars) {
        foreach ($k in @($EnvVars.Keys)) {
            Set-Item -Path ('Env:\' + $k) -Value $EnvVars[$k]
            Add-Note "env $k set"
        }
    }

    if (-not (Test-Path $Exe)) { throw "app not built: $Exe" }

    $p = Start-Process -FilePath $Exe -WorkingDirectory (Split-Path -Parent $Exe) -PassThru
    Add-Note "$Label started pid=$($p.Id)"
    return $p
}

# Polls for either a main window or process exit. Returns 'window' | 'exited' | 'timeout'.
function Wait-ForWindowOrExit {
    param([System.Diagnostics.Process]$Process, [int]$Seconds)

    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if ($Process.HasExited) { return 'exited' }
        $Process.Refresh()
        if ($Process.MainWindowHandle -ne 0) { return 'window' }
        Start-Sleep -Milliseconds 400
    }
    return 'timeout'
}

# Tail whatever the app logged. Apps put logs in different places and often move them between
# versions, so probe rather than hardcode: -LogDir when you know it, and the executable's own
# folder, which is where most desktop apps start out writing.
function Get-LogTail {
    $roots = @(
        $LogDir,
        $(if ($Exe) { Split-Path -Parent $Exe })
    ) | Where-Object { $_ -and (Test-Path $_) }

    $logs = foreach ($r in $roots) {
        Get-ChildItem -Path $r -Recurse -Filter '*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-10) }
    }

    $tails = foreach ($f in ($logs | Sort-Object LastWriteTime -Descending | Select-Object -First 3)) {
        "===== $($f.FullName) ====="
        Get-Content -Path $f.FullName -Tail 60 -ErrorAction SilentlyContinue
    }
    return $tails
}

function Get-UiaDump {
    param([int]$ProcessId, [string]$NameFilter)

    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction Stop
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $ProcessId)
    $windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)

    $lines = New-Object System.Collections.Generic.List[string]

    function Walk($element, $depth) {
        if ($depth -gt 8) { return }
        $pad = ' ' * ($depth * 2)
        $c = $element.Current
        $lines.Add(('{0}{1} "{2}"{3}{4}' -f $pad,
            $c.ControlType.ProgrammaticName.Replace('ControlType.', ''),
            $c.Name,
            $(if ($c.AutomationId) { " id=$($c.AutomationId)" } else { '' }),
            $(if (-not $c.IsEnabled) { ' [disabled]' } else { '' })))
        $kids = $element.FindAll([System.Windows.Automation.TreeScope]::Children,
            [System.Windows.Automation.Condition]::TrueCondition)
        foreach ($k in $kids) { Walk $k ($depth + 1) }
    }

    foreach ($w in $windows) {
        if ($NameFilter -and $w.Current.Name -notlike "*$NameFilter*") { continue }
        $lines.Add("--- window: $($w.Current.Name) ---")
        Walk $w 1
    }
    if ($lines.Count -eq 0) { $lines.Add('(no top-level windows matched)') }
    return $lines
}

# Finds one element anywhere under the process's windows, by AutomationId or by Name. Descendants
# scope rather than Children: WinForms dialogs nest controls several panels deep, and a caller
# should not have to know the container hierarchy to press a button.
function Find-Element {
    param([int]$ProcessId, [string]$ById, [string]$ByName)

    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction Stop
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $procCond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $ProcessId)
    $windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $procCond)

    $cond = if ($ById) {
        New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $ById)
    }
    elseif ($ByName) {
        New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::NameProperty, $ByName)
    }
    else { throw 'pass -AutomationId or -Name' }

    foreach ($w in $windows) {
        $hit = $w.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
        if ($hit) { return $hit }
    }
    return $null
}

function Save-Screenshot([string]$path) {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing -ErrorAction Stop
    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
}

$sig = @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, int extra);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
'@

function Set-Foreground([IntPtr]$Handle) {
    if (-not ('Win32Fg' -as [type])) {
        Add-Type -MemberDefinition $sig -Name 'Win32Fg' -Namespace '' | Out-Null
    }
    # SW_RESTORE فقط على نافذة مُصغَّرة. تطبيقه على نافذة <em>مكبَّرة</em> يُلغي التكبير،
    # فتتحرّك كلّ عناصرها قبل الضغط مباشرةً — وهذا ما جعل ضغطةً على شريط الحالة «تنجح» ولا
    # تصيب شيئاً: الإحداثيّات قُرئت والنافذة مكبَّرة، ثمّ أُعيدت إلى حجمها قبل وصول المؤشّر.
    if ([Win32Fg]::IsIconic($Handle)) {
        [Win32Fg]::ShowWindow($Handle, 9) | Out-Null   # SW_RESTORE
    }
    [Win32Fg]::SetForegroundWindow($Handle) | Out-Null
    Start-Sleep -Milliseconds 400
}

try {
    switch ($Scenario) {

        'Kill' {
            Stop-AllCopies
            $result.ok = $true
            Add-Note 'all copies killed'
        }

        'Start' {
            Stop-AllCopies
            $p = Start-App
            $outcome = Wait-ForWindowOrExit -Process $p -Seconds $WaitSeconds
            $result.outcome = $outcome
            $result.exitCode = $(if ($p.HasExited) { $p.ExitCode } else { $null })

            if ($outcome -eq 'window') {
                # The app presented a window - that IS the assertion. Screenshots and the UIA dump
                # are artifacts for a human to look at, and CopyFromScreen throws "handle is
                # invalid" whenever the desktop session is momentarily unavailable (lock screen,
                # session switch, RDP reconnect). Letting that flake fail the gate costs a whole
                # retry session for nothing, so collect them best-effort.
                $result.ok = $true
                try {
                    $shot = Join-Path $OutDir 'screen.png'
                    Save-Screenshot $shot; Add-Artifact $shot
                }
                catch { Add-Note "screenshot failed (non-fatal): $($_.Exception.Message)" }
                try {
                    $uia = Join-Path $OutDir 'uia.txt'
                    (Get-UiaDump -ProcessId $p.Id -NameFilter $Title) | Set-Content -Path $uia -Encoding UTF8
                    Add-Artifact $uia
                }
                catch { Add-Note "uia dump failed (non-fatal): $($_.Exception.Message)" }
            }
            elseif ($outcome -eq 'exited' -and $AllowExit) {
                $result.ok = $true
                Add-Note "app exited with code $($p.ExitCode) - accepted (-AllowExit)"
            }
            else {
                Add-Note "app did not present a window (outcome=$outcome)"
            }

            $tail = Join-Path $OutDir 'log-tail.txt'
            (Get-LogTail) | Set-Content -Path $tail -Encoding UTF8
            Add-Artifact $tail

            if (-not $KeepRunning) { Stop-AllCopies }
        }

        'SecondInstance' {
            Stop-AllCopies
            $first = Start-App -Label 'first'
            $firstOutcome = Wait-ForWindowOrExit -Process $first -Seconds $WaitSeconds
            if ($firstOutcome -ne 'window') {
                Add-Note "first copy never presented a window (outcome=$firstOutcome) - cannot test the mutex"
                Stop-AllCopies
                break
            }

            $second = Start-App -Label 'second'
            $deadline = (Get-Date).AddSeconds(25)
            while (-not $second.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 400 }

            $result.firstAlive = -not $first.HasExited
            $result.secondExited = $second.HasExited
            $result.secondExitCode = $(if ($second.HasExited) { $second.ExitCode } else { $null })

            # The refusal shows an Arabic message box; capture whatever is on screen either way.
            # Best-effort: the verdict below rests on the two process states, not on the picture.
            try {
                $shot = Join-Path $OutDir 'second-instance.png'
                Save-Screenshot $shot; Add-Artifact $shot
            }
            catch { Add-Note "screenshot failed (non-fatal): $($_.Exception.Message)" }

            if ($second.HasExited -and -not $first.HasExited) {
                $result.ok = $true
                Add-Note 'second copy of the same install was refused; first still running'
            }
            else {
                Add-Note 'second copy was NOT refused (or the first died) - per-install mutex is not holding'
            }
            Stop-AllCopies
        }

        'Inspect' {
            $p = Get-Process -Name $procName -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $p) { throw "no running copy of $procName" }
            $uia = Join-Path $OutDir 'uia.txt'
            (Get-UiaDump -ProcessId $p.Id -NameFilter $Title) | Set-Content -Path $uia -Encoding UTF8
            Add-Artifact $uia
            $result.ok = $true
        }

        'Keys' {
            if (-not $Send) { throw '-Send is required for the Keys scenario' }
            $p = Get-Process -Name $procName -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $p) { throw "no running copy of $procName" }
            $p.Refresh()
            if ($p.MainWindowHandle -eq 0) { throw 'app has no main window to focus' }
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
            Set-Foreground $p.MainWindowHandle
            [System.Windows.Forms.SendKeys]::SendWait($Send)
            Start-Sleep -Milliseconds 1200
            $shot = Join-Path $OutDir 'after-keys.png'
            Save-Screenshot $shot; Add-Artifact $shot
            $result.ok = $true
            Add-Note "sent: $Send"
        }

        'Invoke' {
            $p = Get-Process -Name $procName -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $p) { throw "no running copy of $procName" }
            $el = Find-Element -ProcessId $p.Id -ById $AutomationId -ByName $Name
            if (-not $el) { throw "no element matching id='$AutomationId' name='$Name'" }

            # InvokePattern is what a button exposes. Controls that toggle or select instead
            # (checkbox, radio, list item) expose Toggle/SelectionItem, so fall back to those
            # rather than reporting a bare "pattern not supported" a caller cannot act on.
            $invoked = $false
            foreach ($pair in @(
                    @([System.Windows.Automation.InvokePattern]::Pattern, 'Invoke'),
                    @([System.Windows.Automation.TogglePattern]::Pattern, 'Toggle'),
                    @([System.Windows.Automation.SelectionItemPattern]::Pattern, 'Select'))) {
                $pattern = $null
                if ($el.TryGetCurrentPattern($pair[0], [ref]$pattern)) {
                    switch ($pair[1]) {
                        'Invoke' { $pattern.Invoke() }
                        'Toggle' { $pattern.Toggle() }
                        'Select' { $pattern.Select() }
                    }
                    Add-Note "$($pair[1])d '$($el.Current.Name)'"
                    $invoked = $true
                    break
                }
            }
            if (-not $invoked) { throw "element '$($el.Current.Name)' supports no invokable pattern" }

            Start-Sleep -Milliseconds 900
            try {
                $shot = Join-Path $OutDir 'after-invoke.png'
                Save-Screenshot $shot; Add-Artifact $shot
            }
            catch { Add-Note "screenshot failed (non-fatal): $($_.Exception.Message)" }
            $result.ok = $true
        }

        'SetText' {
            $p = Get-Process -Name $procName -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $p) { throw "no running copy of $procName" }
            $el = Find-Element -ProcessId $p.Id -ById $AutomationId -ByName $Name
            if (-not $el) { throw "no element matching id='$AutomationId' name='$Name'" }

            $vp = $null
            if (-not $el.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) {
                throw "element '$($el.Current.Name)' is not a value control"
            }
            if ($vp.Current.IsReadOnly) { throw "element '$($el.Current.Name)' is read-only" }
            $vp.SetValue($Text)
            Add-Note "set '$($el.Current.Name)'"
            $result.ok = $true
        }

        'Click' {
            # ضغطة مؤشّر حقيقية عند إحداثيّات الشاشة. عناصر أشرطة DevExpress لا تُعرّفها
            # UI Automation باسم (تظهر جميعها "Static" بلا عنوان) ولا تستجيب لرسائل
            # WM_LBUTTONDOWN المُرسَلة — فحصُ الإصابة عندها يقرأ حالة المؤشّر الفعلية. هذا هو
            # ما تعطّل في P16: لا لأنّ الطريقة خاطئة، بل لأنّ سطح المكتب كان مقفلاً، ومؤشّرٌ
            # مُصطنَع لا يصل إلى سطح مكتب مقفل.
            if (-not ('Win32Fg' -as [type])) {
                Add-Type -MemberDefinition $sig -Name 'Win32Fg' -Namespace '' | Out-Null
            }
            $p = Get-Process -Name $procName -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($p) { $p.Refresh(); if ($p.MainWindowHandle -ne 0) { Set-Foreground $p.MainWindowHandle } }

            [Win32Fg]::SetCursorPos($X, $Y) | Out-Null
            Start-Sleep -Milliseconds 250
            [Win32Fg]::mouse_event(0x0002, 0, 0, 0, 0)   # LEFTDOWN
            Start-Sleep -Milliseconds 90
            [Win32Fg]::mouse_event(0x0004, 0, 0, 0, 0)   # LEFTUP
            Start-Sleep -Milliseconds 1200

            try {
                $shot = Join-Path $OutDir 'after-click.png'
                Save-Screenshot $shot; Add-Artifact $shot
            }
            catch { Add-Note "screenshot failed (non-fatal): $($_.Exception.Message)" }
            Add-Note "clicked ($X,$Y)"
            $result.ok = $true
        }

        'Hover' {
            # مثل Click تماماً لكن بلا ضغط: تُنقل الفأرة إلى مركز العنصر وتبقى هناك. هذا ما
            # تحتاجه معاينةُ التحويم: حدث MouseEnter لا يصل إلاّ من مؤشّرٍ حقيقي، والضغطُ
            # يفتح الفيديو بدل أن يعاينه.
            if (-not ('Win32Fg' -as [type])) {
                Add-Type -MemberDefinition $sig -Name 'Win32Fg' -Namespace '' | Out-Null
            }
            $p = Get-Process -Name $procName -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $p) { throw "no running copy of $procName" }
            $p.Refresh()
            if ($p.MainWindowHandle -ne 0) { Set-Foreground $p.MainWindowHandle }

            $targetX = $X
            $targetY = $Y
            if ($AutomationId -or $Name) {
                $el = Find-Element -ProcessId $p.Id -ById $AutomationId -ByName $Name
                if (-not $el) { throw "no element matching id='$AutomationId' name='$Name'" }
                $r = $el.Current.BoundingRectangle
                if ($r.Width -le 0 -or $r.Height -le 0) {
                    throw "element '$($el.Current.Name)' has no on-screen rectangle to hover"
                }
                $targetX = [int]($r.X + $r.Width / 2)
                $targetY = [int]($r.Y + $r.Height / 2)
                Add-Note "hover target '$($el.Current.Name)' at ($targetX,$targetY)"
            }
            elseif (-not $PSBoundParameters.ContainsKey('X') -and -not $PSBoundParameters.ContainsKey('Y')) {
                throw 'pass -AutomationId, -Name, or -X/-Y for the Hover scenario'
            }

            # خطوتان: الأولى بعيدة عن الهدف كي يُطلَق MouseLeave لما كان تحت المؤشّر، ثمّ
            # الاستقرار على الهدف. مؤشّرٌ يقفز داخل البطاقة نفسها لا يولّد MouseEnter جديداً.
            [Win32Fg]::SetCursorPos(($targetX + 140), ($targetY + 140)) | Out-Null
            Start-Sleep -Milliseconds 150
            [Win32Fg]::SetCursorPos($targetX, $targetY) | Out-Null
            Start-Sleep -Milliseconds 1500

            try {
                $shot = Join-Path $OutDir 'after-hover.png'
                Save-Screenshot $shot; Add-Artifact $shot
            }
            catch { Add-Note "screenshot failed (non-fatal): $($_.Exception.Message)" }
            Add-Note "hovered ($targetX,$targetY)"
            $result.ok = $true
        }

        'Screenshot' {
            $shot = Join-Path $OutDir 'screen.png'
            Save-Screenshot $shot; Add-Artifact $shot
            $result.ok = $true
        }
    }
}
catch {
    Add-Note "ERROR: $($_.Exception.Message)"
    $result.ok = $false
    if ($Scenario -in @('Start', 'SecondInstance')) { Stop-AllCopies }
}
finally {
    # Leave the shell as we found it: a data-root override that outlives the run would silently
    # redirect the next one.
    if ($EnvVars) {
        foreach ($k in @($EnvVars.Keys)) {
            Remove-Item -Path ('Env:\' + $k) -ErrorAction SilentlyContinue
        }
    }
}

$result | ConvertTo-Json -Depth 6 -Compress | Write-Output
exit $(if ($result.ok) { 0 } else { 1 })
