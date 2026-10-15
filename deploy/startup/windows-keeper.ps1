Set-StrictMode -Version Latest

function Invoke-StackWslKeeper {
    param(
        [Parameter(Mandatory=$true)]
        [ValidatePattern('^[A-Za-z0-9_.-]+$')]
        [string]$Distribution
    )
    $wsl = "$env:SystemRoot/System32/wsl.exe"
    try {
        Start-Process -FilePath $wsl `
            -ArgumentList "--distribution $Distribution --exec /usr/bin/sleep infinity" `
            -WindowStyle Hidden -Wait -PassThru | Out-Null
    } catch {
        throw 'keeper-launch-failed'
    }
    throw 'keeper-ended'
}
