$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
}

$base = "https://github.com/OlegGorsky/w/raw/main"
$setup = Join-Path $env:TEMP "Setup-CodexWindows.ps1"

Invoke-WebRequest -Uri "$base/Setup-CodexWindows.ps1" -UseBasicParsing -OutFile $setup
try {
    Unblock-File -Path $setup -ErrorAction SilentlyContinue
} catch {
}

$powershell = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
& $powershell -NoProfile -ExecutionPolicy Bypass -File $setup

if ($LASTEXITCODE -eq 3010) {
    Write-Warning "Setup completed and Windows reported that a reboot is required."
} elseif ($LASTEXITCODE -ne 0) {
    throw "Setup failed with exit code $LASTEXITCODE."
}
