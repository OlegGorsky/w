$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
}

$base = "https://oleggorsky.github.io/w"
$tempRoot = if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) { $env:TEMP } else { [IO.Path]::GetTempPath() }
$setup = Join-Path $tempRoot "Setup-CodexWindows.ps1"

$cacheBust = [Guid]::NewGuid().ToString("N")
Invoke-WebRequest -Uri "$base/Setup-CodexWindows.ps1?cb=$cacheBust" -UseBasicParsing -OutFile $setup
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
        $latestLog = Get-ChildItem -LiteralPath $tempRoot -Filter "codex-windows-setup-*.log" -ErrorAction SilentlyContinue |
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
