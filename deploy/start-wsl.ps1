# Example Task Scheduler action at Windows startup, running as the distro owner.
# Registration and host settings are separate, explicitly approved operator steps.
param([string]$Distribution = "Ubuntu")
$ErrorActionPreference = "Stop"
wsl.exe --distribution $Distribution --user root --exec /usr/bin/systemctl start postgresql.service stack-api.service stack-gateway.service stack-discovery.service stack-worker.service
if ($LASTEXITCODE -ne 0) { throw "Stack WSL services failed to start. Inspect journalctl in the selected distribution." }
