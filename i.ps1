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

$exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }

if ($exitCode -eq 3010) {
    Write-Warning "Setup completed and Windows reported that a reboot is required."
} elseif ($exitCode -ne 0) {
    try {
        $latestLog = Get-ChildItem -LiteralPath $env:TEMP -Filter "codex-windows-setup-*.log" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if ($null -ne $latestLog) {
            Write-Warning "Latest setup log: $($latestLog.FullName)"
            Write-Warning "Last setup log lines:"
            Get-Content -LiteralPath $latestLog.FullName -Tail 120 -ErrorAction SilentlyContinue
        }
    } catch {
    }

    throw "Setup failed with exit code $exitCode."
}
