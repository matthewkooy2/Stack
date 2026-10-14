Set-StrictMode -Version Latest

function Invoke-StartupProcess {
    param([string]$File, [string]$Arguments, [int]$Seconds)
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $File
    $info.Arguments = $Arguments
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($Seconds * 1000)) {
            $process.Kill() # Only this client; never terminate the distribution.
            throw 'command-timeout'
        }
        if ($process.ExitCode -ne 0) { throw 'command-failed' }
        # A descendant can keep redirected pipes open after the client exits.
        $remaining = [int][Math]::Max(0,($Seconds - $clock.Elapsed.TotalSeconds) * 1000)
        if (-not $stdout.Wait($remaining)) { throw 'output-timeout' }
        return $stdout.GetAwaiter().GetResult()
    } finally { $process.Dispose() }
}

function Invoke-StartupHttp {
    param([string]$Url, [int]$Seconds)
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Proxy = $null
    $request.AllowAutoRedirect = $false
    $request.Timeout = $Seconds * 1000
    $request.ReadWriteTimeout = $Seconds * 1000
    # GetResponse's timeout can be exceeded by DNS resolution. Bound the whole
    # async operation and abort on timeout, without waiting for resolver cleanup.
    $pending = $request.BeginGetResponse($null, $null)
    try {
        if (-not $pending.AsyncWaitHandle.WaitOne($Seconds * 1000)) {
            $request.Abort()
            throw 'http-timeout'
        }
        $response = $request.EndGetResponse($pending)
    } finally { $pending.AsyncWaitHandle.Close() }
    try {
        if ([int]$response.StatusCode -ne 200 -or $response.ContentType -notmatch '^text/html') { throw 'gateway-not-ready' }
    } finally { $response.Close() }
}

function Invoke-StackStartup {
    param([string]$Distribution, [string]$PhoneOrigin, [int]$TimeoutSeconds, [string]$HelperPath)
    if ($Distribution -notmatch '^[A-Za-z0-9_.-]+$' -or $HelperPath -notmatch '^/[A-Za-z0-9_./-]+$' -or
        $PhoneOrigin -notmatch '^https://[a-zA-Z0-9.-]+\.ts\.net(:[0-9]+)?/?$' -or $TimeoutSeconds -lt 20 -or $TimeoutSeconds -gt 900) { throw 'invalid-config' }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $stage = 'distribution'
    while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $remaining = [int][Math]::Floor($TimeoutSeconds - $clock.Elapsed.TotalSeconds)
        if ($remaining -lt 1) { break }
        try {
            if ($stage -eq 'distribution') {
                $distros = Invoke-StartupProcess "$env:SystemRoot/System32/wsl.exe" '--list --quiet' ([Math]::Min(10,$remaining))
                $names = @($distros.Replace([string][char]0,'') -split '\r?\n' | ForEach-Object { $_.Trim() })
                if ($names -notcontains $Distribution) { throw 'distribution-unavailable' }
                $stage = 'services'
            } elseif ($stage -eq 'services') {
                $report = Invoke-StartupProcess "$env:SystemRoot/System32/wsl.exe" "--distribution $Distribution --user root --exec /usr/bin/python3 $HelperPath --timeout $remaining" $remaining
                $result = $report | ConvertFrom-Json
                if ($result.status -ne 'ready' -or $result.scope -ne 'wsl-local') { throw 'services-not-ready' }
                $stage = 'windows-gateway'
            } elseif ($stage -eq 'windows-gateway') {
                Invoke-StartupHttp 'http://127.0.0.1:8080/' ([Math]::Min(5,$remaining))
                $stage = 'tailscale'
            } elseif ($stage -eq 'tailscale') {
                $raw = Invoke-StartupProcess "$env:ProgramFiles/Tailscale/tailscale.exe" 'status --json' ([Math]::Min(5,$remaining))
                if (($raw | ConvertFrom-Json).BackendState -ne 'Running') { throw 'network-not-ready' }
                $stage = 'private-route'
            } else {
                Invoke-StartupHttp ($PhoneOrigin.TrimEnd('/') + '/') ([Math]::Min(5,$remaining))
                Write-Output '{"stage":"windows-route","status":"ready","phone_acceptance":"not_run"}'
                return
            }
            Write-Output ('{"stage":"' + $stage + '","status":"waiting"}')
        } catch {
            Write-Output ('{"stage":"' + $stage + '","status":"retry"}')
            $delay = [Math]::Min(2000,[Math]::Max(0,($TimeoutSeconds - $clock.Elapsed.TotalSeconds) * 1000))
            if ($delay -gt 0) { Start-Sleep -Milliseconds ([int]$delay) }
        }
    }
    throw 'startup-deadline-exceeded'
}
