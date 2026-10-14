$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/windows-startup.ps1"
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }

# Real disposable child process verifies exit status and timeout handling.
$powershell = (Get-Process -Id $PID).Path
$ok = Invoke-StartupProcess $powershell '-NoProfile -NonInteractive -Command "Write-Output synthetic-ok"' 5
Assert ($ok.Trim() -eq 'synthetic-ok') 'child output'
$watch = [Diagnostics.Stopwatch]::StartNew()
$failed = $false
try { Invoke-StartupProcess $powershell '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 30"' 1 } catch { $failed = $true }
Assert $failed 'hung child was accepted'
Assert ($watch.Elapsed.TotalSeconds -lt 5) 'child timeout not bounded'
$failed = $false
try { Invoke-StartupProcess $powershell '-NoProfile -NonInteractive -Command "exit 7"' 5 } catch { $failed = $true }
Assert $failed 'nonzero child was accepted'

# No WSL/Tailscale/HTTP calls reach the host in orchestration tests.
$script:mode = 'success'
$script:networkAttempts = 0
$script:httpCalls = 0
function Invoke-StartupProcess {
    param($File, $Arguments, $Seconds)
    if ($Arguments -eq '--list --quiet') {
        if ($script:mode -eq 'missing') { return 'OtherDistro' }
        return "FixtureDistro`n"
    }
    if ($Arguments -eq 'status --json') {
        $script:networkAttempts++
        if ($script:mode -eq 'offline' -or ($script:mode -eq 'delayed' -and $script:networkAttempts -lt 3)) { return '{"BackendState":"Starting"}' }
        return '{"BackendState":"Running"}'
    }
    if ($script:mode -eq 'helper-failed') { throw 'synthetic-secret' }
    return '{"status":"ready","scope":"wsl-local"}'
}
function Invoke-StartupHttp { param($Url,$Seconds) $script:httpCalls++ }
function Run-Fixture {
    Invoke-StackStartup FixtureDistro https://fixture.ts.net 20 /fixture/helper.py
}
$result = @(Run-Fixture)
Assert ($result[-1] -match '"status":"ready"') 'happy path failed'
Assert ($result[-1] -match '"phone_acceptance":"not_run"') 'phone falsely accepted'
$script:mode = 'delayed'
$script:networkAttempts = 0
$result = @(Run-Fixture)
Assert ($script:networkAttempts -eq 3) 'network was not retried'
Assert ($result[-1] -match '"status":"ready"') 'delayed network failed'

foreach ($mode in @('missing','offline','helper-failed')) {
    $script:mode = $mode
    $failed = $false
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try { $result = @(Run-Fixture) } catch { $failed = $true }
    Assert $failed "$mode was accepted"
    Assert ($watch.Elapsed.TotalSeconds -lt 23) "$mode exceeded bounded timeout"
}
$failed = $false
try { Invoke-StackStartup 'bad distro' https://fixture.ts.net 20 /fixture/helper.py } catch { $failed = $true }
Assert $failed 'argument validation bypassed'
Write-Output 'PASS: child timeout/exit; readiness; delayed/offline network; missing distro; helper failure; input validation (no live operations).'
