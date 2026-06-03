$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$bootstrapUrl = "https://raw.githubusercontent.com/OlegGorsky/ng/main/d.ps1"
$tempRoot = if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) { $env:TEMP } else { [IO.Path]::GetTempPath() }
$bootstrap = Join-Path $tempRoot ("neurogate-codex-desktop-bootstrap-" + [Guid]::NewGuid().ToString("N") + ".ps1")

function Enable-Tls12 {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {
    }
}

function Get-BootstrapBytes([string]$Uri) {
    Enable-Tls12
    $webClient = New-Object Net.WebClient
    $webClient.Headers.Set("User-Agent", "neurogate-codex-desktop-short-bootstrap")
    if ($webClient.Proxy) {
        $webClient.Proxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials
    }

    try {
        return $webClient.DownloadData($Uri)
    } finally {
        $webClient.Dispose()
    }
}

function ConvertFrom-BootstrapBytes([byte[]]$Bytes) {
    if (-not $Bytes -or $Bytes.Length -eq 0) {
        throw "Downloaded NeuroGate bootstrap is empty."
    }

    $strictUtf8 = New-Object Text.UTF8Encoding -ArgumentList $false, $true
    $text = $strictUtf8.GetString($Bytes)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
        $text = $text.Substring(1)
    }
    if ($text.TrimStart() -match '^(?i)<(!doctype|html)') {
        throw "Downloaded NeuroGate bootstrap looks like HTML, not a PowerShell script."
    }

    return $text
}

function Test-BootstrapSyntax([string]$Path) {
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $parseErrors = $null
    [Management.Automation.PSParser]::Tokenize($text, [ref]$parseErrors) | Out-Null
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        $summary = ($parseErrors | Select-Object -First 5 | ForEach-Object { $_.Message }) -join " | "
        throw ("Downloaded NeuroGate bootstrap failed PowerShell parse preflight: " + $summary)
    }
}

try {
    $cacheBust = [Guid]::NewGuid().ToString("N")
    $requestUrl = "{0}?cb={1}" -f $bootstrapUrl, $cacheBust
    $bytes = Get-BootstrapBytes $requestUrl
    $text = ConvertFrom-BootstrapBytes $bytes
    $utf8Bom = New-Object Text.UTF8Encoding -ArgumentList $true
    [IO.File]::WriteAllText($bootstrap, $text, $utf8Bom)
    Test-BootstrapSyntax $bootstrap

    try {
        Unblock-File -Path $bootstrap -ErrorAction SilentlyContinue
    } catch {
    }

    $powershell = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
    & $powershell -NoProfile -ExecutionPolicy Bypass -File $bootstrap @args

    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    if ($exitCode -ne 0) {
        throw "Setup failed with exit code $exitCode."
    }
} finally {
    Remove-Item -Force $bootstrap -ErrorAction SilentlyContinue
}
