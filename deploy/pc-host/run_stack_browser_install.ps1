$ErrorActionPreference = 'Stop'
$taskDir = 'C:\Users\Ryan\Documents\Codex\2026-09-30\task'
$prefixes = @(Get-NetRoute -AddressFamily IPv4 | Select-Object -ExpandProperty DestinationPrefix -Unique)
$portBusy = @(Get-NetTCPConnection -State Listen -LocalPort 8011 -ErrorAction SilentlyContinue).Count -gt 0
$metadata = @{ capturedEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); ipv4Prefixes = $prefixes; port8011Free = -not $portBusy }
$metadata | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $taskDir 'browser-current-windows-network.json') -Encoding UTF8
if ($portBusy) { throw 'Windows port 8011 is in use; inspect before installation.' }
& wsl.exe -d Ubuntu-24.04 -u mkooy -- /bin/bash /mnt/c/Users/Ryan/Documents/Codex/2026-09-30/task/run_stack_browser_install.sh
exit $LASTEXITCODE
