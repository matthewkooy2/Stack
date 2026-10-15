# Task Scheduler lifetime action. An infinite keeper ending is always a failure
# so the task's existing RestartOnFailure policy can bring WSL back.
param(
    [Parameter(Mandatory=$true)]
    [ValidatePattern('^[A-Za-z0-9_.-]+$')]
    [string]$Distribution
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/startup/windows-keeper.ps1"
try {
    Invoke-StackWslKeeper -Distribution $Distribution
} catch {
    exit 1
}
exit 1
