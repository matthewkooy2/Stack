# Run after approved setup, as the Windows distro owner. Retain the WSL keeper.
param(
    [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9_.-]+$')][string]$Distribution,
    [Parameter(Mandatory=$true)][ValidatePattern('^https://[a-zA-Z0-9.-]+\.ts\.net(:[0-9]+)?/?$')][string]$PhoneOrigin,
    [ValidateRange(20,900)][int]$TimeoutSeconds = 240,
    [ValidatePattern('^/[A-Za-z0-9_./-]+$')][string]$HelperPath = '/usr/local/libexec/stack-startup.py'
)
$ErrorActionPreference = "Stop"
. "$PSScriptRoot/startup/windows-startup.ps1"
try {
    Invoke-StackStartup -Distribution $Distribution -PhoneOrigin $PhoneOrigin -TimeoutSeconds $TimeoutSeconds -HelperPath $HelperPath
} catch {
    # Never print URLs, private names, command output or exception text.
    Write-Output '{"stage":"windows-startup","status":"failed","phone_acceptance":"not_run"}'
    exit 1
}
