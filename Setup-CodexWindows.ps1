<# 
.SYNOPSIS
Installs and repairs a Windows development setup for OpenAI Codex.

.DESCRIPTION
This script is intentionally idempotent. It checks the current machine, installs
or updates PowerShell 7, Node.js LTS, OpenAI Codex CLI for Windows, OpenAI
Codex CLI inside WSL, OpenAI Codex Desktop, and WSL/Ubuntu where possible.

Recommended launch from any Windows terminal. The script will relaunch itself
through a stable elevated Windows PowerShell host when needed:
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup-CodexWindows.ps1

Dry run:
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup-CodexWindows.ps1 -CheckOnly
#>

[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [switch]$SkipPowerShell,
    [switch]$SkipNode,
    [switch]$SkipCodexCli,
    [switch]$SkipCodexDesktop,
    [switch]$SkipWsl,
    [switch]$SkipCodexCliInWsl,
    [switch]$SkipVcRedist,
    [switch]$SkipWindowsSupportCheck,
    [switch]$SkipWingetRepair,
    [switch]$SkipStoreRepair,
    [switch]$RepairStorePolicies,
    [switch]$InstallCodexInWsl,
    [switch]$InstallRecommendedDevTools,
    [switch]$UpdateAllWingetPackages,
    [switch]$RunWindowsUpdate,
    [switch]$NoBootstrap,
    [switch]$NoAdminRelaunch,
    [switch]$NoHostRelaunch,
    [switch]$SkipAutoResume,
    [string]$WslDistro = "Ubuntu",
    [string]$WslUser = "codex"
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
}

$script:BootstrapOriginalBoundParameters = @{}
foreach ($entry in $PSBoundParameters.GetEnumerator()) {
    $script:BootstrapOriginalBoundParameters[$entry.Key] = $entry.Value
}

function Test-BootstrapIsWindows {
    return $env:OS -eq "Windows_NT"
}

function Get-BootstrapScriptPath {
    if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
        return $PSCommandPath
    }

    if ($null -ne $MyInvocation.MyCommand -and -not [string]::IsNullOrWhiteSpace($MyInvocation.MyCommand.Path)) {
        return $MyInvocation.MyCommand.Path
    }

    return $null
}

function ConvertTo-BootstrapArgument {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return '""'
    }

    $text = [string]$Value
    return '"' + ($text -replace '"', '\"') + '"'
}

function New-BootstrapArgumentList {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$ForceSwitches = @()
    )

    $parameters = @{}
    foreach ($entry in $script:BootstrapOriginalBoundParameters.GetEnumerator()) {
        $parameters[$entry.Key] = $entry.Value
    }

    foreach ($switchName in $ForceSwitches) {
        $parameters[$switchName] = [switch]::Present
    }

    $parts = @(
        "-NoLogo",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        (ConvertTo-BootstrapArgument $ScriptPath)
    )

    foreach ($key in ($parameters.Keys | Sort-Object)) {
        $value = $parameters[$key]
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) {
                $parts += "-$key"
            }
            continue
        }

        if ($value -is [bool]) {
            if ($value) {
                $parts += "-$key"
            }
            continue
        }

        $parts += "-$key"
        $parts += (ConvertTo-BootstrapArgument $value)
    }

    return ($parts -join " ")
}

function Get-BootstrapWindowsPowerShellPath {
    $system32 = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
    $sysnative = Join-Path $env:WINDIR "Sysnative\WindowsPowerShell\v1.0\powershell.exe"

    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess -and (Test-Path -LiteralPath $sysnative)) {
        return $sysnative
    }

    return $system32
}

function Get-BootstrapCurrentProcessPath {
    try {
        $process = Get-Process -Id $PID -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace($process.Path)) {
            return $process.Path
        }
    } catch {
    }

    return $null
}

function Test-BootstrapPortablePowerShell {
    $currentPath = Get-BootstrapCurrentProcessPath
    if ([string]::IsNullOrWhiteSpace($currentPath)) {
        return $false
    }

    $fileName = [IO.Path]::GetFileName($currentPath)
    if ($fileName -ine "pwsh.exe") {
        return $false
    }

    $safeRoots = @(
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:WINDIR
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($root in $safeRoots) {
        if ($currentPath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }

    return $true
}

function Test-BootstrapIsAdmin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Invoke-BootstrapRelaunch {
    param(
        [Parameter(Mandatory = $true)][string]$Reason,
        [Parameter(Mandatory = $true)][string]$PowerShellPath,
        [Parameter(Mandatory = $true)][string]$ArgumentList,
        [switch]$Elevated
    )

    Write-Host "Codex setup bootstrap: $Reason"
    Write-Host "Host: $PowerShellPath"

    if ($CheckOnly) {
        Write-Host "[check] Would relaunch with: $PowerShellPath $ArgumentList"
        return
    }

    try {
        if ($Elevated) {
            $process = Start-Process -FilePath $PowerShellPath -ArgumentList $ArgumentList -Verb RunAs -Wait -PassThru
        } else {
            $process = Start-Process -FilePath $PowerShellPath -ArgumentList $ArgumentList -Wait -PassThru
        }

        if ($null -ne $process) {
            exit $process.ExitCode
        }
    } catch {
        throw "Could not relaunch setup script. $($_.Exception.Message)"
    }

    exit 0
}

function Initialize-BootstrapHost {
    if ($NoBootstrap) {
        return
    }

    if (-not (Test-BootstrapIsWindows)) {
        throw "This script configures Windows only. Run it on the target Windows machine."
    }

    $scriptPath = Get-BootstrapScriptPath
    if ([string]::IsNullOrWhiteSpace($scriptPath) -or -not (Test-Path -LiteralPath $scriptPath)) {
        Write-Host "Codex setup bootstrap: script path is unavailable, continuing in the current host."
        return
    }

    $stablePowerShell = Get-BootstrapWindowsPowerShellPath

    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $args = New-BootstrapArgumentList -ScriptPath $scriptPath -ForceSwitches @("NoHostRelaunch")
        Invoke-BootstrapRelaunch -Reason "switching from 32-bit PowerShell to 64-bit Windows PowerShell" -PowerShellPath $stablePowerShell -ArgumentList $args
        exit 0
    }

    if ((Test-BootstrapPortablePowerShell) -and -not $NoHostRelaunch) {
        $args = New-BootstrapArgumentList -ScriptPath $scriptPath -ForceSwitches @("NoHostRelaunch")
        Invoke-BootstrapRelaunch -Reason "switching from portable PowerShell to built-in Windows PowerShell to avoid publisher trust prompts" -PowerShellPath $stablePowerShell -ArgumentList $args
        exit 0
    }

    if ((-not $CheckOnly) -and (-not $NoAdminRelaunch) -and (-not (Test-BootstrapIsAdmin))) {
        $args = New-BootstrapArgumentList -ScriptPath $scriptPath -ForceSwitches @("NoAdminRelaunch", "NoHostRelaunch")
        Invoke-BootstrapRelaunch -Reason "requesting administrator rights for WSL, App Installer, MSI, and Store repair" -PowerShellPath $stablePowerShell -ArgumentList $args -Elevated
        exit 0
    }
}

Initialize-BootstrapHost

function Get-SafeTempPath {
    if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) {
        return $env:TEMP
    }

    return [IO.Path]::GetTempPath()
}

$script:StartedAt = Get-Date
$script:NeedsReboot = $false
$script:HadFailures = $false
$script:WslDistroInstalledThisRun = $false
$script:WslDistroImportedThisRun = $false
$script:Results = New-Object System.Collections.Generic.List[object]
$script:DeferredActions = New-Object System.Collections.Generic.List[string]
$script:CurrentComponentWarning = ""
$script:SetupTempPath = Get-SafeTempPath
$script:TempRoot = Join-Path $script:SetupTempPath ("codex-windows-setup-" + [Guid]::NewGuid().ToString("N"))
$script:LogPath = Join-Path $script:SetupTempPath ("codex-windows-setup-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
$script:CodexDesktopStoreProductId = "9PLM9XGG6VKS"
$script:CodexDesktopStoreInstallerUrl = "https://get.microsoft.com/installer/download/$($script:CodexDesktopStoreProductId)?cid=website_cta_psi"
$script:CodexDesktopStoreUpdateManifestUrl = "https://persistent.oaistatic.com/codex-app-prod/windows-store-update.json"
$script:SetupLauncherUrl = "https://oleggorsky.github.io/w/i.ps1"
$script:AutoResumeTaskName = "Codex Windows Setup Resume"

New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
try {
    Start-Transcript -Path $script:LogPath -Force | Out-Null
} catch {
}

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Info {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "    $Message"
}

function Write-Ok {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "    OK: $Message" -ForegroundColor Green
}

function Write-WarnLine {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "    WARN: $Message" -ForegroundColor Yellow
}

function Write-FailLine {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "    FAIL: $Message" -ForegroundColor Red
}

function Add-Result {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Status,
        [string]$Detail = ""
    )

    $script:Results.Add([PSCustomObject]@{
        Name   = $Name
        Status = $Status
        Detail = $Detail
    }) | Out-Null
}

function Add-DeferredAction {
    param([Parameter(Mandatory = $true)][string]$Message)

    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        $script:DeferredActions.Add($Message) | Out-Null
    }
}

function Remove-DeferredAction {
    param([Parameter(Mandatory = $true)][string]$Message)

    for ($index = $script:DeferredActions.Count - 1; $index -ge 0; $index--) {
        if ([string]$script:DeferredActions[$index] -eq $Message) {
            $script:DeferredActions.RemoveAt($index)
        }
    }
}

function Set-ComponentWarning {
    param([Parameter(Mandatory = $true)][string]$Message)

    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        $script:CurrentComponentWarning = $Message
    }
}

function Test-IsAdmin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Get-ParentProcessName {
    try {
        $process = Get-CimInstance Win32_Process -Filter "ProcessId = $PID"
        if ($null -eq $process -or $null -eq $process.ParentProcessId) {
            return $null
        }

        $parent = Get-Process -Id $process.ParentProcessId -ErrorAction SilentlyContinue
        if ($null -ne $parent) {
            return $parent.ProcessName
        }
    } catch {
    }

    return $null
}

function Get-LaunchEnvironment {
    $currentPath = Get-BootstrapCurrentProcessPath
    $parent = Get-ParentProcessName
    $terminal = "classic console"

    if (-not [string]::IsNullOrWhiteSpace($env:WT_SESSION)) {
        $terminal = "Windows Terminal"
    } elseif ($env:TERM_PROGRAM -eq "vscode" -or $env:VSCODE_INJECTION -eq "1" -or $parent -match "Code") {
        $terminal = "VS Code terminal"
    } elseif ($parent -match "WindowsTerminal|wt") {
        $terminal = "Windows Terminal"
    }

    $portable = if (Test-BootstrapPortablePowerShell) { "yes" } else { "no" }

    return [PSCustomObject]@{
        HostName        = $Host.Name
        Terminal        = $terminal
        ParentProcess   = if ($parent) { $parent } else { "unknown" }
        ProcessPath     = if ($currentPath) { $currentPath } else { "unknown" }
        PSHome          = $PSHOME
        PortablePwsh    = $portable
        Elevated        = if (Test-IsAdmin) { "yes" } else { "no" }
        ExecutionPolicy = try { [string](Get-ExecutionPolicy) } catch { "unknown" }
    }
}

function Get-WindowsSupportInfo {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $build = [int]$os.BuildNumber
    $version = ConvertTo-VersionSafe $os.Version
    $isServer = [int]$os.ProductType -ne 1
    $isServer2025OrNewer = $isServer -and $build -ge 26100
    $isWindows11 = $build -ge 22000

    return [PSCustomObject]@{
        Caption                = [string]$os.Caption
        Version                = [string]$os.Version
        Build                  = $build
        ProductType            = [int]$os.ProductType
        IsServer               = $isServer
        IsWindows11            = $isWindows11
        SupportsWinget         = (((-not $isServer) -and $build -ge 17763) -or $isServer2025OrNewer)
        SupportsStoreApps      = (-not $isServer) -and $build -ge 17763
        CanTryStoreInstaller   = $build -ge 17763
        SupportsWslOneCommand  = $build -ge 19041
        SupportsPowerShell7Msi = $build -ge 17763
        SupportsNodeLtsMsi     = $build -ge 17763
    }
}

function Assert-WindowsSupport {
    if ($SkipWindowsSupportCheck) {
        Write-WarnLine "Windows support preflight was skipped by parameter."
        return
    }

    $support = Get-WindowsSupportInfo
    Write-Info "Detected Windows: $($support.Caption) $($support.Version), build $($support.Build)"

    if ($support.Build -lt 17763) {
        throw "This script expects Windows 10 1809/build 17763 or newer. Older Windows builds cannot reliably install current PowerShell, Node.js LTS, App Installer/winget, Store apps, or Codex tooling."
    }

    if ($support.IsServer) {
        if ($support.SupportsWinget) {
            Write-WarnLine "Windows Server detected. Codex Desktop still depends on Microsoft Store/App Installer infrastructure; the script will use only official Microsoft Store paths."
        } else {
            Write-WarnLine "Windows Server detected. Windows Server 2022 and older do not have the normal Microsoft Store/App Installer path for Codex Desktop; the script will try the official Microsoft Store web installer and fail clearly if Microsoft blocks the install."
        }
    }

    if (-not $support.SupportsWslOneCommand) {
        Write-WarnLine "WSL one-command install needs Windows 10 2004/build 19041 or newer. WSL distro install and Codex-in-WSL may be skipped."
    }
}

function Get-ArchitectureInfo {
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw "Codex, WSL 2, PowerShell 7, and current Node.js builds require 64-bit Windows."
    }

    $processor = [string]$env:PROCESSOR_ARCHITECTURE
    $wow = [string]$env:PROCESSOR_ARCHITEW6432
    $combined = "$processor $wow $env:PROCESSOR_IDENTIFIER"

    if ($combined -match "ARM64|AArch64") {
        return [PSCustomObject]@{
            Label             = "Windows ARM64"
            PowerShellAsset   = "win-arm64.msi"
            NodeAsset         = "arm64"
            CodexArchitecture = "Arm64"
        }
    }

    return [PSCustomObject]@{
        Label             = "Windows x64"
        PowerShellAsset   = "win-x64.msi"
        NodeAsset         = "x64"
        CodexArchitecture = "X64"
    }
}

function Quote-PSString {
    param([AllowNull()][string]$Value)
    return "'" + (($Value -replace "'", "''")) + "'"
}

function Split-PathList {
    param([AllowNull()][string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return @()
    }

    return @($PathValue -split ";" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Test-PathListContains {
    param(
        [AllowNull()][string]$PathValue,
        [Parameter(Mandatory = $true)][string]$Entry
    )

    $needle = $Entry.TrimEnd("\")
    foreach ($segment in Split-PathList $PathValue) {
        if ($segment.TrimEnd("\") -ieq $needle) {
            return $true
        }
    }

    return $false
}

function Add-CurrentProcessPath {
    param(
        [Parameter(Mandatory = $true)][string]$Entry,
        [switch]$Prepend
    )

    if ([string]::IsNullOrWhiteSpace($Entry) -or -not (Test-Path -LiteralPath $Entry)) {
        return
    }

    if (Test-PathListContains -PathValue $env:Path -Entry $Entry) {
        return
    }

    if ($Prepend) {
        $env:Path = "$Entry;$env:Path"
    } else {
        $env:Path = "$env:Path;$Entry"
    }
}

function Add-UserPath {
    param(
        [Parameter(Mandatory = $true)][string]$Entry,
        [switch]$Prepend
    )

    if ([string]::IsNullOrWhiteSpace($Entry) -or -not (Test-Path -LiteralPath $Entry)) {
        return
    }

    Add-CurrentProcessPath -Entry $Entry -Prepend:$Prepend

    if ($CheckOnly) {
        Write-Info "[check] Would add to user PATH: $Entry"
        return
    }

    $current = [Environment]::GetEnvironmentVariable("Path", "User")
    if (Test-PathListContains -PathValue $current -Entry $Entry) {
        return
    }

    $newValue = if ($Prepend) {
        if ([string]::IsNullOrWhiteSpace($current)) { $Entry } else { "$Entry;$current" }
    } else {
        if ([string]::IsNullOrWhiteSpace($current)) { $Entry } else { "$current;$Entry" }
    }

    [Environment]::SetEnvironmentVariable("Path", $newValue, "User")
}

function Invoke-External {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string]$Arguments = "",
        [int[]]$AllowedExitCodes = @(0),
        [switch]$NoWindow
    )

    $display = if ([string]::IsNullOrWhiteSpace($Arguments)) { $FilePath } else { "$FilePath $Arguments" }
    if ($CheckOnly) {
        Write-Info "[check] Would run: $display"
        return 0
    }

    if ($NoWindow) {
        $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden
    } else {
        $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
    }

    if ($AllowedExitCodes -notcontains $process.ExitCode) {
        throw "Command failed with exit code $($process.ExitCode): $display"
    }

    return $process.ExitCode
}

function Join-CommandArguments {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    return ($Arguments | ForEach-Object {
        if ($_ -match '\s|"' ) {
            '"' + ($_ -replace '"', '\"') + '"'
        } else {
            $_
        }
    }) -join " "
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int[]]$AllowedExitCodes = @(0)
    )

    $display = "$FilePath " + ($Arguments -join " ")
    if ($CheckOnly) {
        Write-Info "[check] Would run: $display"
        return 0
    }

    & $FilePath @Arguments
    $code = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    if ($AllowedExitCodes -notcontains $code) {
        throw "Command failed with exit code ${code}: $display"
    }

    return $code
}

function Invoke-WindowsPowerShell {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptText,
        [int[]]$AllowedExitCodes = @(0)
    )

    $powershellExe = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path -LiteralPath $powershellExe)) {
        throw "Windows PowerShell was not found at $powershellExe"
    }

    $tempScript = Join-Path $script:TempRoot ("winps-" + [Guid]::NewGuid().ToString("N") + ".ps1")
    if (-not $CheckOnly) {
        Set-Content -Path $tempScript -Value $ScriptText -Encoding UTF8
        try { Unblock-File -Path $tempScript -ErrorAction SilentlyContinue } catch {}
    }

    try {
        return Invoke-External -FilePath $powershellExe -Arguments "-NoProfile -ExecutionPolicy Bypass -File `"$tempScript`"" -AllowedExitCodes $AllowedExitCodes
    } finally {
        if (-not $CheckOnly -and (Test-Path -LiteralPath $tempScript)) {
            Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Operation,
        [Parameter(Mandatory = $true)][string]$Description,
        [int]$Attempts = 3
    )

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            return & $Operation
        } catch {
            if ($attempt -ge $Attempts) {
                throw
            }

            Write-WarnLine "$Description failed on attempt $attempt/${Attempts}: $($_.Exception.Message)"
            Start-Sleep -Seconds ([Math]::Min(10, 2 * $attempt))
        }
    }
}

function Invoke-WebDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$OutFile
    )

    if ($CheckOnly) {
        Write-Info "[check] Would download: $Uri"
        return
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $OutFile) -Force | Out-Null
    Invoke-WithRetry -Description "Download $Uri" -Operation {
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -Headers @{ "User-Agent" = "CodexWindowsSetup/1.0" }
    } | Out-Null
    try { Unblock-File -Path $OutFile -ErrorAction SilentlyContinue } catch {}
}

function Invoke-HttpText {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$Method = "GET",
        [string]$Body = "",
        [string]$ContentType = "",
        [hashtable]$Headers = @{}
    )

    if ($CheckOnly) {
        Write-Info "[check] Would request: $Method $Uri"
        return ""
    }

    $requestHeaders = @{ "User-Agent" = "CodexWindowsSetup/1.0" }
    foreach ($key in $Headers.Keys) {
        $requestHeaders[$key] = $Headers[$key]
    }

    $parameters = @{
        Uri             = $Uri
        Method          = $Method
        Headers         = $requestHeaders
        UseBasicParsing = $true
    }

    if (-not [string]::IsNullOrWhiteSpace($Body)) {
        $parameters["Body"] = $Body
    }

    if (-not [string]::IsNullOrWhiteSpace($ContentType)) {
        $parameters["ContentType"] = $ContentType
    }

    $response = Invoke-WithRetry -Description "$Method $Uri" -Operation {
        Invoke-WebRequest @parameters
    }
    return [string]$response.Content
}

function Assert-AuthenticodeSignature {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$ExpectedSubjectPattern = ""
    )

    if ($CheckOnly) {
        Write-Info "[check] Would verify Authenticode signature: $Path"
        return
    }

    $signature = Get-AuthenticodeSignature -FilePath $Path
    if ($null -eq $signature -or [string]$signature.Status -ne "Valid") {
        $status = if ($null -ne $signature) { [string]$signature.Status } else { "missing" }
        throw "Invalid Authenticode signature for $Path. Status: $status"
    }

    $subject = ""
    if ($null -ne $signature.SignerCertificate) {
        $subject = [string]$signature.SignerCertificate.Subject
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedSubjectPattern) -and $subject -notmatch $ExpectedSubjectPattern) {
        throw "Unexpected signer for $Path. Signer: $subject"
    }

    Write-Ok "Verified Authenticode signature: $subject"
}

function Get-ArchiveEntryText {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$EntryName
    )

    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    $archive = $null
    $reader = $null
    $stream = $null
    try {
        $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
        $entry = $archive.Entries | Where-Object { $_.FullName -ieq $EntryName } | Select-Object -First 1
        if ($null -eq $entry) {
            throw "Archive entry not found: $EntryName"
        }

        $stream = $entry.Open()
        $reader = New-Object IO.StreamReader($stream)
        return $reader.ReadToEnd()
    } finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        } elseif ($null -ne $stream) {
            $stream.Dispose()
        }

        if ($null -ne $archive) {
            $archive.Dispose()
        }
    }
}

function Get-MsixManifestInfo {
    param([Parameter(Mandatory = $true)][string]$Path)

    $manifestText = Get-ArchiveEntryText -ArchivePath $Path -EntryName "AppxManifest.xml"
    $document = New-Object Xml.XmlDocument
    $document.PreserveWhitespace = $false
    $document.LoadXml($manifestText)

    $identity = $document.SelectSingleNode("/*[local-name()='Package']/*[local-name()='Identity']")
    if ($null -eq $identity) {
        throw "MSIX manifest is missing Package/Identity."
    }

    $publisherDisplayNameNode = $document.SelectSingleNode("/*[local-name()='Package']/*[local-name()='Properties']/*[local-name()='PublisherDisplayName']")
    $displayNameNode = $document.SelectSingleNode("/*[local-name()='Package']/*[local-name()='Properties']/*[local-name()='DisplayName']")

    return [PSCustomObject]@{
        Name                 = [string]$identity.GetAttribute("Name")
        Publisher            = [string]$identity.GetAttribute("Publisher")
        Version              = [string]$identity.GetAttribute("Version")
        ProcessorArchitecture = [string]$identity.GetAttribute("ProcessorArchitecture")
        PublisherDisplayName = if ($null -ne $publisherDisplayNameNode) { [string]$publisherDisplayNameNode.InnerText } else { "" }
        DisplayName          = if ($null -ne $displayNameNode) { [string]$displayNameNode.InnerText } else { "" }
    }
}

function Assert-CodexDesktopMsixPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedPackageMoniker
    )

    if ($CheckOnly) {
        Write-Info "[check] Would verify Codex Desktop MSIX package identity and signature: $Path"
        return
    }

    $signature = Get-AuthenticodeSignature -FilePath $Path
    if ($null -eq $signature -or [string]$signature.Status -ne "Valid" -or $null -eq $signature.SignerCertificate) {
        $status = if ($null -ne $signature) { [string]$signature.Status } else { "missing" }
        throw "Invalid Authenticode signature for Codex Desktop MSIX. Status: $status"
    }

    $subject = [string]$signature.SignerCertificate.Subject
    $manifest = Get-MsixManifestInfo -Path $Path

    if ($manifest.Name -ne "OpenAI.Codex") {
        throw "Unexpected MSIX package identity. Expected OpenAI.Codex, got $($manifest.Name)."
    }

    if ($manifest.Publisher -ne $subject) {
        throw "MSIX publisher does not match signer. Manifest publisher: $($manifest.Publisher). Signer: $subject."
    }

    if ($ExpectedPackageMoniker -notlike "OpenAI.Codex_*" -or $ExpectedPackageMoniker -notmatch "_$($manifest.ProcessorArchitecture)`__") {
        throw "Resolved package moniker does not match MSIX manifest architecture. Moniker: $ExpectedPackageMoniker. Manifest architecture: $($manifest.ProcessorArchitecture)."
    }

    Write-Ok "Verified Codex Desktop MSIX: $($manifest.Name) $($manifest.Version), signer $subject"
}

function Invoke-RestJson {
    param([Parameter(Mandatory = $true)][string]$Uri)

    return Invoke-WithRetry -Description "GET $Uri" -Operation {
        Invoke-RestMethod -Uri $Uri -UseBasicParsing -Headers @{ "User-Agent" = "CodexWindowsSetup/1.0" }
    }
}

function ConvertTo-VersionSafe {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $match = [regex]::Match($Text, "\d+(?:\.\d+){1,3}")
    if (-not $match.Success) {
        return $null
    }

    try {
        return [Version]$match.Value
    } catch {
        return $null
    }
}

function Get-CommandVersion {
    param(
        [Parameter(Mandatory = $true)][string]$CommandName,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
        return $null
    }

    try {
        $output = & $cmd.Source @Arguments 2>$null
        return (($output | Select-Object -First 1) -as [string]).Trim()
    } catch {
        return $null
    }
}

function Get-PwshCommand {
    $candidates = @()

    $cmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($null -ne $cmd -and (Test-Path -LiteralPath $cmd.Source)) {
        $candidates += $cmd.Source
    }

    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $psRoot = Join-Path $env:ProgramFiles "PowerShell"
        if (Test-Path -LiteralPath $psRoot) {
            $candidates += @(Get-ChildItem -Path $psRoot -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending |
                ForEach-Object { Join-Path $_.FullName "pwsh.exe" } |
                Where-Object { Test-Path -LiteralPath $_ })
        }
    }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

function Get-WindowsOptionalFeatureState {
    param([Parameter(Mandatory = $true)][string]$FeatureName)

    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction Stop
        return [string]$feature.State
    } catch {
        return "Unknown"
    }
}

function Test-WindowsOptionalFeatureEnabled {
    param([Parameter(Mandatory = $true)][string]$FeatureName)

    return (Get-WindowsOptionalFeatureState -FeatureName $FeatureName) -eq "Enabled"
}

function Test-WindowsRebootPending {
    if ($CheckOnly) {
        return $false
    }

    $rebootKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
    )

    foreach ($key in $rebootKeys) {
        try {
            if (Test-Path -LiteralPath $key) {
                return $true
            }
        } catch {
        }
    }

    try {
        $sessionManager = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name "PendingFileRenameOperations" -ErrorAction SilentlyContinue
        if ($null -ne $sessionManager -and $null -ne $sessionManager.PendingFileRenameOperations) {
            return $true
        }
    } catch {
    }

    return $false
}

function Get-SetupAutoResumeScriptPath {
    $base = if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
        Join-Path $env:ProgramData "CodexSetup"
    } elseif (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Join-Path $env:LOCALAPPDATA "CodexSetup"
    } else {
        Join-Path (Get-SafeTempPath) "CodexSetup"
    }

    return Join-Path $base "Resume-CodexWindowsSetup.ps1"
}

function Clear-SetupAutoResume {
    if ($CheckOnly) {
        Write-Info "[check] Would remove setup auto-resume task."
        return
    }

    try {
        $existingTask = Get-ScheduledTask -TaskName $script:AutoResumeTaskName -ErrorAction SilentlyContinue
        if ($null -ne $existingTask) {
            Unregister-ScheduledTask -TaskName $script:AutoResumeTaskName -Confirm:$false -ErrorAction SilentlyContinue
        }
    } catch {
        try {
            Invoke-External -FilePath "schtasks.exe" -Arguments "/Delete /TN `"$($script:AutoResumeTaskName)`" /F" -AllowedExitCodes @(0, 1) -NoWindow | Out-Null
        } catch {
        }
    }
}

function Enable-SetupAutoResume {
    if ($SkipAutoResume) {
        Set-ComponentWarning "Setup auto-resume after reboot is disabled by parameter."
        Write-WarnLine "Setup auto-resume after reboot is disabled by parameter."
        return
    }

    if ($CheckOnly) {
        Write-Info "[check] Would register setup auto-resume after reboot."
        return
    }

    try {
        $resumeScriptPath = Get-SetupAutoResumeScriptPath
        New-Item -ItemType Directory -Path (Split-Path -Parent $resumeScriptPath) -Force | Out-Null

        $resumeScript = @"
`$ErrorActionPreference = "Continue"
try {
    schtasks.exe /Delete /TN "$($script:AutoResumeTaskName)" /F | Out-Null
} catch {
}
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
}
irm $($script:SetupLauncherUrl) | iex
"@

        Set-Content -Path $resumeScriptPath -Value $resumeScript -Encoding UTF8
        try { Unblock-File -Path $resumeScriptPath -ErrorAction SilentlyContinue } catch {}

        $powershellExe = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
        $taskAction = New-ScheduledTaskAction -Execute $powershellExe -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$resumeScriptPath`""
        $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $taskTrigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
        $taskPrincipal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Highest
        $taskSettings = New-ScheduledTaskSettingsSet -Compatibility Win8 -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

        Register-ScheduledTask -TaskName $script:AutoResumeTaskName -Action $taskAction -Trigger $taskTrigger -Principal $taskPrincipal -Settings $taskSettings -Force | Out-Null
        Write-Ok "Setup will continue automatically after the next administrator logon."
        Remove-DeferredAction "Reboot Windows, then rerun this script to finish WSL distro setup and Codex CLI inside WSL."
        Add-DeferredAction "Reboot Windows; setup is scheduled to continue automatically after the next administrator logon."
    } catch {
        Set-ComponentWarning "Setup auto-resume task could not be registered."
        Write-WarnLine "Could not register setup auto-resume task: $($_.Exception.Message)"
        Add-DeferredAction "Reboot Windows, then rerun this script to finish setup."
    }
}

function Get-WingetPath {
    $candidates = @()

    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($null -ne $cmd -and (Test-Path -LiteralPath $cmd.Source)) {
        $candidates += $cmd.Source
    }

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $candidates += Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\winget.exe"
    }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate)) {
            continue
        }

        try {
            $null = & $candidate --version 2>$null
            if ($LASTEXITCODE -eq 0) {
                return $candidate
            }
        } catch {
        }
    }

    return $null
}

function Repair-WingetSources {
    param([Parameter(Mandatory = $true)][string]$WingetPath)

    Write-Info "Resetting winget sources after source/update failure."
    Invoke-NativeCommand -FilePath $WingetPath -Arguments @("source", "reset", "--force") -AllowedExitCodes @(0) | Out-Null
    Invoke-NativeCommand -FilePath $WingetPath -Arguments @("source", "update") -AllowedExitCodes @(0) | Out-Null
    Write-Ok "winget source reset --force completed."
}

function Invoke-Component {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )

    Write-Step $Name
    $script:CurrentComponentWarning = ""
    try {
        & $Body
        if ([string]::IsNullOrWhiteSpace($script:CurrentComponentWarning)) {
            Add-Result -Name $Name -Status "OK" -Detail ""
        } else {
            Add-Result -Name $Name -Status "WARN" -Detail $script:CurrentComponentWarning
        }
    } catch {
        $script:HadFailures = $true
        Write-FailLine $_.Exception.Message
        Add-Result -Name $Name -Status "FAILED" -Detail $_.Exception.Message
    } finally {
        $script:CurrentComponentWarning = ""
    }
}

function Get-AppxPackageText {
    param([Parameter(Mandatory = $true)][string]$PackageName)

    $scriptText = @"
`$ErrorActionPreference = 'Stop'
`$pkg = Get-AppxPackage -AllUsers -Name $(Quote-PSString $PackageName) | Select-Object -First 1
if (`$null -ne `$pkg) {
    [PSCustomObject]@{
        Name = `$pkg.Name
        PackageFullName = `$pkg.PackageFullName
        Version = `$pkg.Version.ToString()
        InstallLocation = `$pkg.InstallLocation
    } | ConvertTo-Json -Compress
}
"@

    $powershellExe = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path -LiteralPath $powershellExe)) {
        return $null
    }

    try {
        $output = & $powershellExe -NoProfile -ExecutionPolicy Bypass -Command $scriptText 2>$null
        if ([string]::IsNullOrWhiteSpace([string]$output)) {
            return $null
        }
        return ($output | Out-String).Trim()
    } catch {
        return $null
    }
}

function Get-CodexDesktopPackageText {
    $desktopPackage = Get-AppxPackageText -PackageName "OpenAI.Codex"
    if ([string]::IsNullOrWhiteSpace($desktopPackage)) {
        $desktopPackage = Get-AppxPackageText -PackageName "*Codex*"
    }

    return $desktopPackage
}

function Find-ObjectPropertyString {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string]) {
        return $null
    }

    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            if ([string]$key -ieq $Name -and $Value[$key] -is [string]) {
                return [string]$Value[$key]
            }

            $nested = Find-ObjectPropertyString -Value $Value[$key] -Name $Name
            if (-not [string]::IsNullOrWhiteSpace($nested)) {
                return $nested
            }
        }

        return $null
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($item in $Value) {
            $nested = Find-ObjectPropertyString -Value $item -Name $Name
            if (-not [string]::IsNullOrWhiteSpace($nested)) {
                return $nested
            }
        }

        return $null
    }

    foreach ($property in $Value.PSObject.Properties) {
        if ($property.Name -ieq $Name -and $property.Value -is [string]) {
            return [string]$property.Value
        }

        $nested = Find-ObjectPropertyString -Value $property.Value -Name $Name
        if (-not [string]::IsNullOrWhiteSpace($nested)) {
            return $nested
        }
    }

    return $null
}

function ConvertTo-XmlEscapedString {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return ""
    }

    return [Security.SecurityElement]::Escape($Value)
}

function Format-SoapDate {
    param([Parameter(Mandatory = $true)][DateTime]$Value)

    return $Value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture)
}

function New-StoreSoapEnvelope {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$To,
        [Parameter(Mandatory = $true)][string]$Body
    )

    $created = Format-SoapDate -Value (Get-Date).ToUniversalTime()
    $expires = Format-SoapDate -Value (Get-Date).ToUniversalTime().AddMinutes(5)
    $messageId = [Guid]::NewGuid().ToString()
    $actionEscaped = ConvertTo-XmlEscapedString $Action
    $toEscaped = ConvertTo-XmlEscapedString $To

    return @"
<s:Envelope xmlns:a="http://www.w3.org/2005/08/addressing" xmlns:s="http://www.w3.org/2003/05/soap-envelope">
  <s:Header>
    <a:Action s:mustUnderstand="1">$actionEscaped</a:Action>
    <a:MessageID>urn:uuid:$messageId</a:MessageID>
    <a:To s:mustUnderstand="1">$toEscaped</a:To>
    <o:Security s:mustUnderstand="1" xmlns:o="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">
      <Timestamp xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">
        <Created>$created</Created>
        <Expires>$expires</Expires>
      </Timestamp>
      <wuws:WindowsUpdateTicketsToken wsu:id="ClientMSA" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" xmlns:wuws="http://schemas.microsoft.com/msus/2014/10/WindowsUpdateAuthorization">
        <TicketType Name="MSA" Version="1.0" Policy="MBI_SSL">
          <User />
        </TicketType>
      </wuws:WindowsUpdateTicketsToken>
    </o:Security>
  </s:Header>
  <s:Body>
$Body
  </s:Body>
</s:Envelope>
"@
}

function Invoke-MicrosoftStoreSoap {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Soap
    )

    $oldCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
    [Net.ServicePointManager]::ServerCertificateValidationCallback = {
        param($Sender, $Certificate, $Chain, $SslPolicyErrors)

        if ($SslPolicyErrors -eq [Net.Security.SslPolicyErrors]::None) {
            return $true
        }

        try {
            $request = $Sender -as [Net.HttpWebRequest]
            $hostName = if ($null -ne $request -and $null -ne $request.RequestUri) { $request.RequestUri.Host } else { "" }
            $subject = if ($null -ne $Certificate) { [string]$Certificate.Subject } else { "" }
            $issuer = if ($null -ne $Certificate) { [string]$Certificate.Issuer } else { "" }

            return $hostName -ieq "fe3.delivery.mp.microsoft.com" -and
                ($subject -match "delivery\.mp\.microsoft\.com" -or $subject -match "Microsoft") -and
                ($issuer -match "Microsoft" -or $issuer -match "Microsoft Update")
        } catch {
            return $false
        }
    }

    try {
        return Invoke-HttpText -Uri $Uri -Method "POST" -Body $Soap -ContentType "application/soap+xml; charset=utf-8" -Headers @{
            "MS-CV" = ([Guid]::NewGuid().ToString("N").Substring(0, 16) + ".0")
        }
    } finally {
        [Net.ServicePointManager]::ServerCertificateValidationCallback = $oldCallback
    }
}

function Get-XmlLocalNameValues {
    param(
        [Parameter(Mandatory = $true)][string]$XmlText,
        [Parameter(Mandatory = $true)][string]$LocalName
    )

    $document = New-Object Xml.XmlDocument
    $document.PreserveWhitespace = $false
    $document.LoadXml($XmlText)
    $nodes = $document.SelectNodes(("//*[local-name()='{0}']" -f $LocalName))

    $values = @()
    foreach ($node in $nodes) {
        $values += [string]$node.InnerText
    }

    return $values
}

function Get-CodexDesktopStoreUpdateManifest {
    try {
        $manifestText = Invoke-HttpText -Uri $script:CodexDesktopStoreUpdateManifestUrl
        if ([string]::IsNullOrWhiteSpace($manifestText)) {
            return $null
        }

        return $manifestText | ConvertFrom-Json
    } catch {
        Write-WarnLine "Could not read OpenAI Codex Windows Store update manifest: $($_.Exception.Message)"
        return $null
    }
}

function Resolve-CodexDesktopMicrosoftStoreMsix {
    $arch = Get-ArchitectureInfo
    $storeArchitecture = if ($arch.CodexArchitecture -ieq "Arm64") { "arm64" } else { "x64" }

    Write-Info "Resolving Codex Desktop MSIX from Microsoft Store metadata for $storeArchitecture."

    if ($CheckOnly) {
        return [PSCustomObject]@{
            PackageMoniker = "OpenAI.Codex_check_$($storeArchitecture)__2p2nqsd0c76g0"
            DownloadUrl    = "https://tlu.dl.delivery.mp.microsoft.com/check/OpenAI.Codex.Msix"
            ContentLength  = 0
        }
    }

    $manifest = Get-CodexDesktopStoreUpdateManifest
    if ($null -ne $manifest -and -not [string]::IsNullOrWhiteSpace([string]$manifest.buildVersion)) {
        Write-Info "OpenAI Windows Store manifest version: $($manifest.buildVersion)"
    }

    $catalogUrl = "https://displaycatalog.mp.microsoft.com/v7.0/products/$($script:CodexDesktopStoreProductId)?market=US&languages=en-US,en,neutral"
    $catalog = (Invoke-HttpText -Uri $catalogUrl) | ConvertFrom-Json
    $wuCategoryId = Find-ObjectPropertyString -Value $catalog -Name "WuCategoryId"
    if ([string]::IsNullOrWhiteSpace($wuCategoryId)) {
        throw "Microsoft Store DisplayCatalog did not return WuCategoryId for $($script:CodexDesktopStoreProductId)."
    }

    $fe3Endpoint = "https://fe3.delivery.mp.microsoft.com/ClientWebService/client.asmx"
    $fe3SecuredEndpoint = "https://fe3.delivery.mp.microsoft.com/ClientWebService/client.asmx/secured"
    $now = (Get-Date).ToUniversalTime()

    $getCookieBody = @"
<GetCookie xmlns="http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService">
  <oldCookie></oldCookie>
  <lastChange>2015-10-21T17:01:07.1472913Z</lastChange>
  <currentTime>$(Format-SoapDate -Value $now)</currentTime>
  <protocolVersion>1.40</protocolVersion>
</GetCookie>
"@
    $getCookieSoap = New-StoreSoapEnvelope -Action "http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/GetCookie" -To $fe3Endpoint -Body $getCookieBody
    $cookieXml = Invoke-MicrosoftStoreSoap -Uri $fe3Endpoint -Soap $getCookieSoap
    $cookie = @(Get-XmlLocalNameValues -XmlText $cookieXml -LocalName "EncryptedData" | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace([string]$cookie)) {
        throw "Microsoft Store FE3 GetCookie did not return EncryptedData."
    }

    $baselineUpdateIds = @(
        1, 2, 3, 11, 19, 544, 549, 2359974, 5169044, 8788830, 23110993, 23110994,
        54341900, 54343656, 59830006, 59830007, 59830008, 60484010, 62450018,
        62450019, 62450020, 66027979, 66053150, 97657898, 98822896, 98959022,
        98959023, 98959024, 98959025, 98959026, 104433538, 104900364, 105489019,
        117765322, 129905029, 130040031, 132387090, 132393049, 138537048,
        140377312, 143747671, 158941041, 158941042, 158941043, 158941044,
        159123858, 159130928, 164836897, 164847386, 164848327, 164852241,
        164852246, 164852252, 164852253
    )
    $installedIds = ($baselineUpdateIds | ForEach-Object { "<int>$_</int>" }) -join ""
    $deviceAttributes = "OSArchitecture=AMD64;DeviceFamily=Windows.Desktop;App=WU;AppVer=10.0.22621.1;OSVersion=10.0.22621.1;InstallationType=Client;IsDeviceRetailDemo=0;"
    if ($storeArchitecture -eq "arm64") {
        $deviceAttributes = "OSArchitecture=ARM64;DeviceFamily=Windows.Desktop;App=WU;AppVer=10.0.22621.1;OSVersion=10.0.22621.1;InstallationType=Client;IsDeviceRetailDemo=0;"
    }

    $syncBody = @"
<SyncUpdates xmlns="http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService">
  <cookie>
    <Expiration>$(Format-SoapDate -Value $now.AddDays(1))</Expiration>
    <EncryptedData>$(ConvertTo-XmlEscapedString ([string]$cookie))</EncryptedData>
  </cookie>
  <parameters>
    <ExpressQuery>false</ExpressQuery>
    <InstalledNonLeafUpdateIDs>$installedIds</InstalledNonLeafUpdateIDs>
    <OtherCachedUpdateIDs></OtherCachedUpdateIDs>
    <SkipSoftwareSync>false</SkipSoftwareSync>
    <NeedTwoGroupOutOfScopeUpdates>true</NeedTwoGroupOutOfScopeUpdates>
    <FilterAppCategoryIds>
      <CategoryIdentifier>
        <Id>$(ConvertTo-XmlEscapedString $wuCategoryId)</Id>
      </CategoryIdentifier>
    </FilterAppCategoryIds>
    <TreatAppCategoryIdsAsInstalled>true</TreatAppCategoryIdsAsInstalled>
    <AlsoPerformRegularSync>false</AlsoPerformRegularSync>
    <ComputerSpec />
    <ExtendedUpdateInfoParameters>
      <XmlUpdateFragmentTypes>
        <XmlUpdateFragmentType>Extended</XmlUpdateFragmentType>
      </XmlUpdateFragmentTypes>
      <Locales>
        <string>en-US</string>
        <string>en</string>
      </Locales>
    </ExtendedUpdateInfoParameters>
    <ClientPreferredLanguages>
      <string>en-US</string>
    </ClientPreferredLanguages>
    <ProductsParameters>
      <SyncCurrentVersionOnly>false</SyncCurrentVersionOnly>
      <DeviceAttributes>$deviceAttributes</DeviceAttributes>
      <CallerAttributes>Interactive=1;IsSeeker=0;</CallerAttributes>
      <Products />
    </ProductsParameters>
  </parameters>
</SyncUpdates>
"@

    $syncSoap = New-StoreSoapEnvelope -Action "http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/SyncUpdates" -To $fe3Endpoint -Body $syncBody
    $syncXml = Invoke-MicrosoftStoreSoap -Uri $fe3Endpoint -Soap $syncSoap

    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($fragmentText in (Get-XmlLocalNameValues -XmlText $syncXml -LocalName "Xml")) {
        $fragment = [Net.WebUtility]::HtmlDecode($fragmentText)
        if ($fragment -notmatch "AppxMetadata" -or $fragment -notmatch "SecuredFragment") {
            continue
        }

        $identityMatch = [regex]::Match($fragment, '<UpdateIdentity\s+UpdateID="(?<id>[^"]+)"\s+RevisionNumber="(?<revision>[^"]+)"', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $packageMatch = [regex]::Match($fragment, '<AppxMetadata\b(?=[^>]*\bPackageType="(?<type>[^"]+)")(?=[^>]*\bPackageMoniker="(?<moniker>[^"]+)")[^>]*>', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $identityMatch.Success -or -not $packageMatch.Success) {
            continue
        }

        $moniker = $packageMatch.Groups["moniker"].Value
        if ($moniker -notlike "OpenAI.Codex_*" -or $moniker -notmatch "_$storeArchitecture`__") {
            continue
        }

        $version = ConvertTo-VersionSafe $moniker
        $candidates.Add([PSCustomObject]@{
            PackageMoniker = $moniker
            PackageType    = $packageMatch.Groups["type"].Value
            UpdateId       = $identityMatch.Groups["id"].Value
            RevisionNumber = $identityMatch.Groups["revision"].Value
            Version        = $version
        }) | Out-Null
    }

    $package = $candidates | Sort-Object -Property Version -Descending | Select-Object -First 1
    if ($null -eq $package) {
        throw "Microsoft Store FE3 did not return an OpenAI.Codex $storeArchitecture MSIX package."
    }

    $extendedBody = @"
<GetExtendedUpdateInfo2 xmlns="http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService">
  <updateIDs>
    <UpdateIdentity>
      <UpdateID>$(ConvertTo-XmlEscapedString $package.UpdateId)</UpdateID>
      <RevisionNumber>$(ConvertTo-XmlEscapedString $package.RevisionNumber)</RevisionNumber>
    </UpdateIdentity>
  </updateIDs>
  <infoTypes>
    <XmlUpdateFragmentType>FileUrl</XmlUpdateFragmentType>
    <XmlUpdateFragmentType>FileDecryption</XmlUpdateFragmentType>
  </infoTypes>
  <deviceAttributes>$deviceAttributes</deviceAttributes>
</GetExtendedUpdateInfo2>
"@
    $extendedSoap = New-StoreSoapEnvelope -Action "http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/GetExtendedUpdateInfo2" -To $fe3SecuredEndpoint -Body $extendedBody
    $extendedXml = Invoke-MicrosoftStoreSoap -Uri $fe3SecuredEndpoint -Soap $extendedSoap
    $downloadUrl = @(Get-XmlLocalNameValues -XmlText $extendedXml -LocalName "Url" |
        Where-Object { $_ -match "^https?://" } |
        Sort-Object Length -Descending |
        Select-Object -First 1)

    if ([string]::IsNullOrWhiteSpace([string]$downloadUrl)) {
        throw "Microsoft Store FE3 did not return a package URL for $($package.PackageMoniker)."
    }

    return [PSCustomObject]@{
        PackageMoniker = [string]$package.PackageMoniker
        DownloadUrl    = [string]$downloadUrl
        ContentLength  = 0
    }
}

function Enable-AppxTrustedPackageInstall {
    if (-not (Test-IsAdmin)) {
        throw "Direct MSIX install needs an elevated prompt."
    }

    if ($CheckOnly) {
        Write-Info "[check] Would enable AllowAllTrustedApps policy for trusted MSIX sideloading."
        return
    }

    foreach ($path in @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock",
        "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Appx"
    )) {
        Set-RegistryDwordValue -Path $path -Name "AllowAllTrustedApps" -Value 1
    }
}

function Get-RegistryDwordValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    try {
        $value = Get-ItemPropertyValue -LiteralPath $Path -Name $Name -ErrorAction Stop
        if ($null -ne $value) {
            return [int]$value
        }
    } catch {
    }

    return $null
}

function Set-RegistryDwordValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$Value
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    $existing = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        Set-ItemProperty -LiteralPath $Path -Name $Name -Value $Value
    } else {
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
    }
}

function Write-CodexDesktopOfficialPathDiagnostics {
    $support = Get-WindowsSupportInfo
    $storePackage = Get-AppxPackageText -PackageName "Microsoft.WindowsStore"
    $appInstallerPackage = Get-AppxPackageText -PackageName "Microsoft.DesktopAppInstaller"

    Write-Info "Official Desktop install diagnostics:"
    Write-Info "  OS edition: $(if ($support.IsServer) { 'Windows Server' } else { 'Windows client' }), build $($support.Build)"
    Write-Info "  Microsoft Store package: $(if ($storePackage) { 'present' } else { 'not found' })"
    Write-Info "  Desktop App Installer package: $(if ($appInstallerPackage) { 'present' } else { 'not found' })"
    Write-Info "  winget supported by script: $(if ($support.SupportsWinget) { 'yes' } else { 'no' })"

    foreach ($serviceName in @("AppXSvc", "ClipSVC", "InstallService", "wuauserv", "BITS")) {
        try {
            $service = Get-Service -Name $serviceName -ErrorAction Stop
            Write-Info "  service ${serviceName}: $($service.Status), start type: $($service.StartType)"
        } catch {
            Write-Info "  service ${serviceName}: not found"
        }
    }

    $wuPolicy = Get-RegistryDwordValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "DoNotConnectToWindowsUpdateInternetLocations"
    if ($null -ne $wuPolicy) {
        Write-Info "  Windows Update policy DoNotConnectToWindowsUpdateInternetLocations: $wuPolicy"
        if ($wuPolicy -ne 0) {
            Write-WarnLine "Windows Update internet locations are blocked by policy; Microsoft Store all-users install can redirect or fail."
        }
    }
}

function Repair-ExecutionPolicy {
    Write-Info "Checking PowerShell execution policy."

    if ($CheckOnly) {
        Write-Info "[check] Would set CurrentUser execution policy to RemoteSigned when it is Restricted or AllSigned."
        return
    }

    try {
        $effective = Get-ExecutionPolicy
        Write-Info "Effective execution policy: $effective"
        if ($effective -in @("Restricted", "AllSigned")) {
            Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
            Write-Ok "CurrentUser execution policy set to RemoteSigned."
        } else {
            Write-Ok "Execution policy does not need a permanent change."
        }
    } catch {
        Write-WarnLine "Could not change execution policy: $($_.Exception.Message)"
    }
}

function Repair-StorePackages {
    if (-not (Test-IsAdmin)) {
        Write-WarnLine "Store/App Installer repair needs an elevated prompt. Skipping repair."
        return
    }

    $support = Get-WindowsSupportInfo
    if (-not $support.SupportsStoreApps) {
        Write-WarnLine "Store/App Installer repair skipped: Microsoft Store apps are not supported for this OS/edition by this script."
        return
    }

    $repairPoliciesLiteral = if ($RepairStorePolicies) { '$true' } else { '$false' }
    $scriptText = @"
`$ErrorActionPreference = 'Stop'

if ($repairPoliciesLiteral) {
    foreach (`$path in @('HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore', 'HKCU:\SOFTWARE\Policies\Microsoft\WindowsStore')) {
        if (Test-Path -LiteralPath `$path) {
            foreach (`$name in @('RemoveWindowsStore', 'DisableStoreApps', 'RequirePrivateStoreOnly')) {
                try {
                    `$value = Get-ItemPropertyValue -LiteralPath `$path -Name `$name -ErrorAction SilentlyContinue
                    if (`$null -ne `$value -and [int]`$value -ne 0) {
                        Set-ItemProperty -LiteralPath `$path -Name `$name -Value 0
                        Write-Host "Set `$path\`$name to 0."
                    }
                } catch {
                }
            }
        }
    }
} else {
    foreach (`$path in @('HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore', 'HKCU:\SOFTWARE\Policies\Microsoft\WindowsStore')) {
        if (Test-Path -LiteralPath `$path) {
            foreach (`$name in @('RemoveWindowsStore', 'DisableStoreApps', 'RequirePrivateStoreOnly')) {
                try {
                    `$value = Get-ItemPropertyValue -LiteralPath `$path -Name `$name -ErrorAction SilentlyContinue
                    if (`$null -ne `$value -and [int]`$value -ne 0) {
                        Write-Host "Store policy is set: `$path\`$name=`$value. Use -RepairStorePolicies to change it."
                    }
                } catch {
                }
            }
        }
    }
}

try {
    `$store = Get-AppxPackage -AllUsers -Name Microsoft.WindowsStore | Select-Object -First 1
    if (`$null -ne `$store) {
        `$manifest = Join-Path `$store.InstallLocation 'AppXManifest.xml'
        if (Test-Path -LiteralPath `$manifest) {
            Add-AppxPackage -DisableDevelopmentMode -Register `$manifest
            Write-Host "Registered Microsoft.WindowsStore."
        }
    } else {
        Write-Host "Microsoft.WindowsStore package was not found."
    }
} catch {
    Write-Host "Microsoft.WindowsStore repair failed: `$(`$_.Exception.Message)"
}

try {
    Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe
    Write-Host "Registered Microsoft.DesktopAppInstaller."
} catch {
    Write-Host "Microsoft.DesktopAppInstaller register-by-family failed: `$(`$_.Exception.Message)"
}
"@

    Invoke-WindowsPowerShell -ScriptText $scriptText -AllowedExitCodes @(0) | Out-Null
    Write-Ok "Store/App Installer repair commands completed."
}

function Repair-WingetWithMicrosoftModule {
    if (-not (Test-IsAdmin)) {
        throw "Microsoft.WinGet.Client repair needs an elevated prompt."
    }

    $scriptText = @"
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

`$oldPolicy = `$null
try {
    `$repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
    if (`$null -ne `$repo) {
        `$oldPolicy = `$repo.InstallationPolicy
    }

    if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
    }

    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    Install-Module -Name Microsoft.WinGet.Client -Force -AllowClobber -Repository PSGallery -Scope AllUsers | Out-Null
    Import-Module Microsoft.WinGet.Client -Force
    Repair-WinGetPackageManager -AllUsers -Force
} finally {
    if (-not [string]::IsNullOrWhiteSpace(`$oldPolicy)) {
        try {
            Set-PSRepository -Name PSGallery -InstallationPolicy `$oldPolicy
        } catch {
        }
    }
}
"@

    Invoke-WindowsPowerShell -ScriptText $scriptText -AllowedExitCodes @(0) | Out-Null
}

function Ensure-Winget {
    $winget = Get-WingetPath
    if ($null -ne $winget) {
        try {
            $version = & $winget --version 2>$null
            Write-Ok "winget found: $winget ($version)"
        } catch {
            Write-Ok "winget found: $winget"
        }
        return $winget
    }

    if ($SkipWingetRepair) {
        throw "winget is missing and -SkipWingetRepair was specified."
    }

    if (-not (Test-IsAdmin)) {
        throw "winget is missing. Re-run from an elevated prompt so the script can repair App Installer."
    }

    Write-Info "winget is missing. Trying to repair Microsoft App Installer."

    if (-not $SkipStoreRepair) {
        Repair-StorePackages
    }

    $winget = Get-WingetPath
    if ($null -ne $winget) {
        Write-Ok "winget became available after App Installer repair."
        return $winget
    }

    $release = Invoke-RestJson -Uri "https://api.github.com/repos/microsoft/winget-cli/releases/latest"
    $asset = $release.assets |
        Where-Object { $_.name -eq "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle" } |
        Select-Object -First 1

    if ($null -eq $asset) {
        throw "Could not find Desktop App Installer msixbundle in the latest winget release."
    }

    $bundlePath = Join-Path $script:TempRoot $asset.name
    Invoke-WebDownload -Uri $asset.browser_download_url -OutFile $bundlePath

    $scriptText = @"
`$ErrorActionPreference = 'Stop'
Add-AppxPackage -Path $(Quote-PSString $bundlePath)
"@

    try {
        Invoke-WindowsPowerShell -ScriptText $scriptText -AllowedExitCodes @(0) | Out-Null
    } catch {
        Write-WarnLine "Direct App Installer msixbundle install failed: $($_.Exception.Message)"
        Write-Info "Trying Microsoft.WinGet.Client Repair-WinGetPackageManager fallback."
        Repair-WingetWithMicrosoftModule
    }

    if ($CheckOnly) {
        Write-Info "[check] Would verify winget availability after App Installer repair."
        return "winget.exe"
    }

    $winget = Get-WingetPath
    if ($null -eq $winget) {
        Write-WarnLine "Desktop App Installer was installed, but winget is not visible in this session yet."
        if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            Add-CurrentProcessPath -Entry (Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps")
        }
        $winget = Get-WingetPath
    }

    if ($null -eq $winget) {
        throw "winget is still not available after App Installer repair."
    }

    Write-Ok "winget installed: $winget"
    return $winget
}

function Install-PowerShell7 {
    $arch = Get-ArchitectureInfo
    Write-Info "Architecture: $($arch.Label)"

    $release = Invoke-RestJson -Uri "https://api.github.com/repos/PowerShell/PowerShell/releases/latest"
    $latestVersion = ConvertTo-VersionSafe $release.tag_name
    if ($null -eq $latestVersion) {
        throw "Could not parse latest PowerShell release version from $($release.tag_name)."
    }

    $programFilesPwsh = @()
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $psRoot = Join-Path $env:ProgramFiles "PowerShell"
        if (Test-Path -LiteralPath $psRoot) {
            $programFilesPwsh = @(Get-ChildItem -Path $psRoot -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { Join-Path $_.FullName "pwsh.exe" } |
                Where-Object { Test-Path -LiteralPath $_ })
        }
    }

    $bestInstalledVersion = $null
    foreach ($path in $programFilesPwsh) {
        try {
            $versionText = & $path -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null
            $version = ConvertTo-VersionSafe $versionText
            if ($null -ne $version -and ($null -eq $bestInstalledVersion -or $version -gt $bestInstalledVersion)) {
                $bestInstalledVersion = $version
            }
        } catch {
        }
    }

    if ($null -ne $bestInstalledVersion) {
        Write-Info "Installed PowerShell under Program Files: $bestInstalledVersion"
    } else {
        Write-Info "No Program Files PowerShell installation was found."
    }

    if ($null -ne $bestInstalledVersion -and $bestInstalledVersion -ge $latestVersion) {
        Write-Ok "PowerShell 7 is current enough: $bestInstalledVersion"
        $pwshPath = Get-PwshCommand
        if (-not [string]::IsNullOrWhiteSpace($pwshPath)) {
            Add-CurrentProcessPath -Entry (Split-Path -Parent $pwshPath)
        }
        return
    }

    $assetSuffix = [regex]::Escape($arch.PowerShellAsset)
    $asset = $release.assets |
        Where-Object { $_.name -match "^PowerShell-\d+\.\d+\.\d+.*-$assetSuffix$" } |
        Select-Object -First 1

    if ($null -eq $asset) {
        throw "Could not find PowerShell installer asset ending with $($arch.PowerShellAsset)."
    }

    $msiPath = Join-Path $script:TempRoot $asset.name
    Invoke-WebDownload -Uri $asset.browser_download_url -OutFile $msiPath

    if (-not $CheckOnly) {
        $signature = Get-AuthenticodeSignature -FilePath $msiPath
        if ($signature.Status -ne "Valid" -or $null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch "Microsoft") {
            throw "PowerShell MSI signature is not valid or not signed by Microsoft. Status: $($signature.Status)"
        }
    }

    $exitCode = Invoke-External -FilePath "msiexec.exe" -Arguments "/i `"$msiPath`" /qn /norestart" -AllowedExitCodes @(0, 3010)
    if ($exitCode -eq 3010) {
        $script:NeedsReboot = $true
    }

    $pwshPath = Get-PwshCommand
    if (-not [string]::IsNullOrWhiteSpace($pwshPath)) {
        Add-CurrentProcessPath -Entry (Split-Path -Parent $pwshPath)
    }

    Write-Ok "PowerShell 7 installer completed."
}

function Install-NodeLts {
    $arch = Get-ArchitectureInfo

    $index = Invoke-RestJson -Uri "https://nodejs.org/dist/index.json"
    $latestLts = $index | Where-Object { $_.lts -ne $false } | Select-Object -First 1
    if ($null -eq $latestLts) {
        throw "Could not find a Node.js LTS release in nodejs.org index.json."
    }

    $latestVersionText = [string]$latestLts.version
    $latestVersion = ConvertTo-VersionSafe $latestVersionText
    $currentText = Get-CommandVersion -CommandName "node.exe" -Arguments @("-v")
    $currentVersion = ConvertTo-VersionSafe $currentText

    if ($null -ne $currentVersion) {
        Write-Info "Installed Node.js: $currentText"
    } else {
        Write-Info "Node.js is not installed or not on PATH."
    }

    if ($null -ne $currentVersion -and $currentVersion -ge $latestVersion) {
        Write-Ok "Node.js is current enough: $currentText"
        if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
            $nodeDir = Join-Path $env:ProgramFiles "nodejs"
            Add-CurrentProcessPath -Entry $nodeDir
        }
        return
    }

    $fileName = "node-$latestVersionText-$($arch.NodeAsset).msi"
    $baseUri = "https://nodejs.org/dist/$latestVersionText"
    $msiUri = "$baseUri/$fileName"
    $shasumsUri = "$baseUri/SHASUMS256.txt"
    $msiPath = Join-Path $script:TempRoot $fileName
    $shasumsPath = Join-Path $script:TempRoot "node-SHASUMS256.txt"

    Invoke-WebDownload -Uri $msiUri -OutFile $msiPath
    Invoke-WebDownload -Uri $shasumsUri -OutFile $shasumsPath

    if (-not $CheckOnly) {
        $hashLine = Get-Content -Path $shasumsPath | Where-Object { $_ -match "\s+$([regex]::Escape($fileName))$" } | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($hashLine)) {
            throw "Could not find $fileName in Node.js SHASUMS256.txt."
        }

        $expected = ($hashLine -split "\s+")[0].ToLowerInvariant()
        $actual = (Get-FileHash -Path $msiPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            throw "Node.js MSI checksum mismatch. Expected $expected but got $actual."
        }
    }

    $exitCode = Invoke-External -FilePath "msiexec.exe" -Arguments "/i `"$msiPath`" /qn /norestart" -AllowedExitCodes @(0, 3010)
    if ($exitCode -eq 3010) {
        $script:NeedsReboot = $true
    }

    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $nodeDir = Join-Path $env:ProgramFiles "nodejs"
        Add-CurrentProcessPath -Entry $nodeDir
    }
    Write-Ok "Node.js LTS installer completed."
}

function Get-VcRedistRegistryInfo {
    $arch = Get-ArchitectureInfo
    $runtimeArch = if ($arch.CodexArchitecture -eq "Arm64") { "ARM64" } else { "X64" }
    $path = "HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\$runtimeArch"

    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }

    try {
        $props = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
        return [PSCustomObject]@{
            Path      = $path
            Arch      = $runtimeArch
            Installed = [int]$props.Installed
            Version   = [string]$props.Version
            Major     = [int]$props.Major
            Minor     = [int]$props.Minor
            Bld       = [int]$props.Bld
            Rbld      = [int]$props.Rbld
        }
    } catch {
        return $null
    }
}

function Install-VcRedist {
    $arch = Get-ArchitectureInfo
    $redistArch = if ($arch.CodexArchitecture -eq "Arm64") { "arm64" } else { "x64" }
    $existing = Get-VcRedistRegistryInfo

    if ($null -ne $existing -and $existing.Installed -eq 1 -and $existing.Major -ge 14) {
        Write-Ok "Microsoft Visual C++ 2015-2022 Redistributable is present ($($existing.Arch), $($existing.Version))."
        return
    }

    Write-Info "Installing Microsoft Visual C++ 2015-2022 Redistributable to avoid VCRUNTIME140_1.dll and related launch errors."
    $uri = "https://aka.ms/vs/17/release/vc_redist.$redistArch.exe"
    $redistPath = Join-Path $script:TempRoot "vc_redist.$redistArch.exe"
    Invoke-WebDownload -Uri $uri -OutFile $redistPath

    if (-not $CheckOnly) {
        $signature = Get-AuthenticodeSignature -FilePath $redistPath
        if ($signature.Status -ne "Valid" -or $null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch "Microsoft") {
            throw "VC++ Redistributable signature is not valid or not signed by Microsoft. Status: $($signature.Status)"
        }
    }

    $exitCode = Invoke-External -FilePath $redistPath -Arguments "/install /quiet /norestart" -AllowedExitCodes @(0, 3010, 1638)
    if ($exitCode -eq 3010) {
        $script:NeedsReboot = $true
    }

    Write-Ok "Microsoft Visual C++ Redistributable install/update completed."
}

function Get-CodexCommand {
    foreach ($name in @("codex.exe", "codex.cmd", "codex")) {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue
        if ($null -ne $cmd -and (Test-Path -LiteralPath $cmd.Source)) {
            return $cmd.Source
        }
    }

    return $null
}

function Get-CodexCommandVersion {
    $codex = Get-CodexCommand
    if ([string]::IsNullOrWhiteSpace($codex)) {
        return $null
    }

    try {
        $output = & $codex --version 2>$null
        return (($output | Select-Object -First 1) -as [string]).Trim()
    } catch {
        return $null
    }
}

function Install-CodexCli {
    $arch = Get-ArchitectureInfo
    $existing = Get-CodexCommandVersion
    if (-not [string]::IsNullOrWhiteSpace($existing)) {
        Write-Info "Existing Codex CLI: $existing"
    } else {
        Write-Info "Codex CLI is not installed or not on PATH."
    }

    $installerPath = Join-Path $script:TempRoot "codex-install.ps1"
    Invoke-WebDownload -Uri "https://chatgpt.com/codex/install.ps1" -OutFile $installerPath

    if (-not $CheckOnly) {
        $content = Get-Content -Path $installerPath -Raw
        $pattern = '\$architecture = \[System\.Runtime\.InteropServices\.RuntimeInformation\]::OSArchitecture'
        if ($content -match $pattern) {
            $patched = $content -replace $pattern, ('$architecture = "' + $arch.CodexArchitecture + '"')
            Set-Content -Path $installerPath -Value $patched -Encoding UTF8
        } else {
            Write-WarnLine "Codex installer architecture probe pattern was not found. Running installer without patch."
        }
        try { Unblock-File -Path $installerPath -ErrorAction SilentlyContinue } catch {}
    }

    $oldNonInteractive = $env:CODEX_NON_INTERACTIVE
    $env:CODEX_NON_INTERACTIVE = "1"

    try {
        $powershellExe = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
        Invoke-External -FilePath $powershellExe -Arguments "-NoProfile -ExecutionPolicy Bypass -File `"$installerPath`"" -AllowedExitCodes @(0) | Out-Null
    } catch {
        Write-WarnLine "Official standalone installer failed: $($_.Exception.Message)"
        $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
        if ($null -eq $npm) {
            throw "Codex standalone installer failed, and npm.cmd is not available for npm fallback."
        }
        Invoke-NativeCommand -FilePath $npm.Source -Arguments @("install", "-g", "@openai/codex") -AllowedExitCodes @(0) | Out-Null
    } finally {
        if ($null -eq $oldNonInteractive) {
            Remove-Item Env:\CODEX_NON_INTERACTIVE -ErrorAction SilentlyContinue
        } else {
            $env:CODEX_NON_INTERACTIVE = $oldNonInteractive
        }
    }

    if ($CheckOnly) {
        Write-Info "[check] Would verify codex.exe after install/update."
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $codexBin = Join-Path $env:LOCALAPPDATA "Programs\OpenAI\Codex\bin"
        Add-UserPath -Entry $codexBin -Prepend
    }
    if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
        $npmBin = Join-Path $env:APPDATA "npm"
        Add-UserPath -Entry $npmBin
    }

    $version = Get-CodexCommandVersion
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "Codex CLI was installed, but codex is not available on PATH. Checked standalone path and npm global shim path."
    }

    Write-Ok "Codex CLI available: $version"
}

function Invoke-CodexDesktopWingetInstall {
    param([AllowNull()][string]$ExistingPackageText)

    $storePackageIds = @("9PLM9XGG6VKS", "Codex")
    $lastWingetError = $null
    $winget = Ensure-Winget

    try {
        Invoke-NativeCommand -FilePath $winget -Arguments @("source", "update") -AllowedExitCodes @(0) | Out-Null
    } catch {
        Write-WarnLine "winget source update failed: $($_.Exception.Message)"
        Repair-WingetSources -WingetPath $winget
    }

    if ([string]::IsNullOrWhiteSpace($ExistingPackageText)) {
        Write-Info "Codex Desktop AppX package was not found. Installing from Microsoft Store source."
        foreach ($packageId in $storePackageIds) {
            try {
                Invoke-NativeCommand -FilePath $winget -Arguments @(
                    "install",
                    "--id", $packageId,
                    "-e",
                    "--source", "msstore",
                    "--accept-package-agreements",
                    "--accept-source-agreements",
                    "--disable-interactivity"
                ) -AllowedExitCodes @(0) | Out-Null
                $lastWingetError = $null
                break
            } catch {
                $lastWingetError = $_.Exception.Message
                Write-WarnLine "Codex Desktop install candidate '$packageId' failed: $lastWingetError"
            }
        }

        if ($null -ne $lastWingetError) {
            try {
                Write-Info "Store search output for diagnostics:"
                Invoke-NativeCommand -FilePath $winget -Arguments @("search", "Codex", "--source", "msstore", "--disable-interactivity") -AllowedExitCodes @(0) | Out-Null
            } catch {
                Write-WarnLine "winget Store search also failed: $($_.Exception.Message)"
            }
            throw "Codex Desktop Store install failed. Last winget error: $lastWingetError"
        }
    } else {
        Write-Info "Codex Desktop appears to be installed. Asking winget to upgrade it if an update exists."
        foreach ($packageId in $storePackageIds) {
            try {
                Invoke-NativeCommand -FilePath $winget -Arguments @(
                    "upgrade",
                    "--id", $packageId,
                    "-e",
                    "--source", "msstore",
                    "--accept-package-agreements",
                    "--accept-source-agreements",
                    "--disable-interactivity"
                ) -AllowedExitCodes @(0) | Out-Null
                $lastWingetError = $null
                break
            } catch {
                $lastWingetError = $_.Exception.Message
            }
        }

        if ($null -ne $lastWingetError) {
            Write-WarnLine "winget upgrade did not complete cleanly. This often means no matching Store update was available: $lastWingetError"
        }
    }
}

function Wait-CodexDesktopPackage {
    param([int]$TimeoutSeconds = 120)

    if ($CheckOnly) {
        Write-Info "[check] Would wait for Codex Desktop AppX package registration."
        return "check"
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $desktopPackage = Get-CodexDesktopPackageText
        if (-not [string]::IsNullOrWhiteSpace($desktopPackage)) {
            return $desktopPackage
        }

        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)

    return $null
}

function Invoke-CodexDesktopStoreInstaller {
    $support = Get-WindowsSupportInfo
    if (-not $support.CanTryStoreInstaller) {
        throw "Official Microsoft Store web installer requires Windows 10 1809/build 17763 or newer."
    }

    $installerPath = Join-Path $script:TempRoot "Codex Installer.exe"
    Write-Info "Downloading official Microsoft Store web installer for Codex Desktop."
    Invoke-WebDownload -Uri $script:CodexDesktopStoreInstallerUrl -OutFile $installerPath
    Assert-AuthenticodeSignature -Path $installerPath -ExpectedSubjectPattern "Microsoft Corporation"

    Write-CodexDesktopOfficialPathDiagnostics

    $attempts = New-Object System.Collections.Generic.List[object]
    $storePackage = Get-AppxPackageText -PackageName "Microsoft.WindowsStore"
    $appInstallerPackage = Get-AppxPackageText -PackageName "Microsoft.DesktopAppInstaller"

    if ((Test-IsAdmin) -and ($support.IsServer -or [string]::IsNullOrWhiteSpace($storePackage) -or [string]::IsNullOrWhiteSpace($appInstallerPackage))) {
        $attempts.Add([PSCustomObject]@{
            Label          = "all-users silent mode"
            Arguments      = @("--silent", "--allusers")
            TimeoutSeconds = 90
        }) | Out-Null
    }

    if (-not $support.IsServer -or -not [string]::IsNullOrWhiteSpace($storePackage) -or -not [string]::IsNullOrWhiteSpace($appInstallerPackage)) {
        $attempts.Add([PSCustomObject]@{
            Label          = "per-user silent mode"
            Arguments      = @("--silent")
            TimeoutSeconds = 120
        }) | Out-Null
    }

    if ($attempts.Count -eq 0) {
        throw "Official Microsoft Store installer cannot run non-interactively here because this Server build has no Store/App Installer package and the script is not elevated for all-users install."
    }

    $attemptErrors = New-Object System.Collections.Generic.List[string]
    foreach ($attempt in $attempts) {
        $argumentText = Join-CommandArguments -Arguments ([string[]]$attempt.Arguments)
        Write-Info "Running official Microsoft Store installer in $($attempt.Label): $argumentText"

        try {
            $exitCode = Invoke-External -FilePath $installerPath -Arguments $argumentText -AllowedExitCodes @(0, 3010)
            if ($exitCode -eq 3010) {
                $script:NeedsReboot = $true
                Write-WarnLine "Codex Desktop installer reported that a reboot is required."
            }
        } catch {
            $attemptErrors.Add("$($attempt.Label): $($_.Exception.Message)") | Out-Null
            continue
        }

        $desktopPackage = Wait-CodexDesktopPackage -TimeoutSeconds ([int]$attempt.TimeoutSeconds)
        if (-not [string]::IsNullOrWhiteSpace($desktopPackage)) {
            return
        }

        $attemptErrors.Add("$($attempt.Label): installer returned but OpenAI.Codex AppX package was not registered") | Out-Null
    }

    if ($attemptErrors.Count -gt 0) {
        throw "Official Microsoft Store installer could not register Codex Desktop. " + ($attemptErrors -join " | ")
    }

    throw "Official Microsoft Store installer completed, but the OpenAI.Codex AppX package was not registered."
}

function Install-CodexDesktopDirectMsix {
    if (-not (Test-IsAdmin)) {
        throw "Direct Microsoft Store MSIX install needs an elevated prompt."
    }

    $resolved = Resolve-CodexDesktopMicrosoftStoreMsix
    $msixPath = Join-Path $script:TempRoot ($resolved.PackageMoniker + ".Msix")

    Write-Info "Downloading Codex Desktop MSIX from Microsoft Store CDN."
    Invoke-WebDownload -Uri $resolved.DownloadUrl -OutFile $msixPath

    if ($resolved.ContentLength -gt 0 -and -not $CheckOnly) {
        $actualLength = (Get-Item -LiteralPath $msixPath).Length
        if ($actualLength -ne [int64]$resolved.ContentLength) {
            throw "Downloaded MSIX size mismatch. Expected $($resolved.ContentLength) bytes, got $actualLength bytes."
        }
    }

    Assert-CodexDesktopMsixPackage -Path $msixPath -ExpectedPackageMoniker $resolved.PackageMoniker
    Enable-AppxTrustedPackageInstall

    $scriptText = @"
`$ErrorActionPreference = 'Stop'
Add-AppxPackage -Path $(Quote-PSString $msixPath) -ForceApplicationShutdown
"@

    Invoke-WindowsPowerShell -ScriptText $scriptText -AllowedExitCodes @(0) | Out-Null
    $desktopPackage = Wait-CodexDesktopPackage -TimeoutSeconds 90
    if ([string]::IsNullOrWhiteSpace($desktopPackage)) {
        throw "Direct Microsoft Store MSIX install completed, but the OpenAI.Codex AppX package was not registered."
    }

    Write-Ok "Codex Desktop MSIX installed from Microsoft Store CDN."
}

function Install-CodexDesktop {
    $support = Get-WindowsSupportInfo
    $desktopPackage = Get-CodexDesktopPackageText
    $wingetError = $null
    $storeInstallerError = $null
    $directMsixError = $null

    if ($support.SupportsWinget) {
        try {
            Invoke-CodexDesktopWingetInstall -ExistingPackageText $desktopPackage
        } catch {
            $wingetError = $_.Exception.Message
            Write-WarnLine "winget/msstore Codex Desktop install failed: $wingetError"
        }
    } else {
        Write-WarnLine "winget/msstore Codex Desktop install is not supported for this OS/edition by this script."
    }

    $desktopPackage = Get-CodexDesktopPackageText
    if ([string]::IsNullOrWhiteSpace($desktopPackage)) {
        if ($support.IsServer -and -not $support.SupportsWinget) {
            Write-WarnLine "Skipping Microsoft Store web installer on this Server build because it redirects to Store UI instead of installing."
        } else {
            if ($support.IsServer) {
                Write-WarnLine "Trying the official Microsoft Store web installer. On Windows Server this may still fail because the Microsoft Store install stack may not be present."
            } else {
                Write-Info "Trying the official Microsoft Store web installer fallback."
            }

            try {
                Invoke-CodexDesktopStoreInstaller
            } catch {
                $storeInstallerError = $_.Exception.Message
                Write-WarnLine "Official Microsoft Store web installer failed: $storeInstallerError"
            }
        }
    }

    $desktopPackage = Get-CodexDesktopPackageText
    if ([string]::IsNullOrWhiteSpace($desktopPackage)) {
        Write-WarnLine "Trying direct Microsoft Store CDN MSIX fallback. This is not a standalone EXE; it installs the signed Store package without Store UI."
        try {
            Install-CodexDesktopDirectMsix
        } catch {
            $directMsixError = $_.Exception.Message
            Write-WarnLine "Direct Microsoft Store CDN MSIX fallback failed: $directMsixError"
        }
    }

    $desktopPackage = Get-CodexDesktopPackageText
    if ([string]::IsNullOrWhiteSpace($desktopPackage)) {
        if ($support.IsServer) {
            Add-DeferredAction "Codex Desktop has no official standalone Windows EXE. If direct Microsoft Store CDN MSIX install is blocked by this Server build, use Windows 10/11 client or a Server build where Microsoft App Installer/winget msstore is available."
        } else {
            Add-DeferredAction "Open the official Codex Desktop Store page if silent install was blocked by policy: https://get.microsoft.com/installer/download/$($script:CodexDesktopStoreProductId)"
        }

        $details = @()
        if (-not [string]::IsNullOrWhiteSpace($wingetError)) {
            $details += "winget: $wingetError"
        }
        if (-not [string]::IsNullOrWhiteSpace($storeInstallerError)) {
            $details += "Store installer: $storeInstallerError"
        }
        if (-not [string]::IsNullOrWhiteSpace($directMsixError)) {
            $details += "direct MSIX: $directMsixError"
        }

        $detailText = if ($details.Count -gt 0) { " " + ($details -join " | ") } else { "" }
        throw "Codex Desktop could not be installed by official Microsoft Store paths.$detailText"
    }

    Write-Ok "Codex Desktop install/update step completed."
}

function Get-WslDistroNames {
    param([string]$WslPath = "wsl.exe")

    try {
        $rawDistros = & $WslPath -l -q 2>$null
        if ($LASTEXITCODE -ne 0 -or $null -eq $rawDistros) {
            return @()
        }

        return @($rawDistros | ForEach-Object { ([string]$_ -replace "`0", "").Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    } catch {
        return @()
    }
}

function Test-WslEngineAvailable {
    param([string]$WslPath = "wsl.exe")

    if ($CheckOnly) {
        return $true
    }

    try {
        $null = & $WslPath -l -q 2>$null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

function Test-WslDistroInitialized {
    param(
        [Parameter(Mandatory = $true)][string]$WslPath,
        [Parameter(Mandatory = $true)][string]$DistroName,
        [int]$TimeoutSeconds = 20
    )

    if ($CheckOnly) {
        Write-Info "[check] Would test whether WSL distro '$DistroName' is initialized."
        return $true
    }

    $stdoutPath = Join-Path $script:TempRoot ("wsl-init-check-" + [Guid]::NewGuid().ToString("N") + ".out")
    $stderrPath = Join-Path $script:TempRoot ("wsl-init-check-" + [Guid]::NewGuid().ToString("N") + ".err")
    $arguments = Join-CommandArguments @("-d", $DistroName, "-u", "root", "--", "sh", "-lc", "exit 0")

    try {
        $process = Start-Process -FilePath $WslPath -ArgumentList $arguments -PassThru -NoNewWindow -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch {}
            return $false
        }

        return $process.ExitCode -eq 0
    } catch {
        return $false
    }
}

function Quote-BashString {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return "''"
    }

    return "'" + ($Value -replace "'", "'\''") + "'"
}

function Get-UbuntuWslRootfsUrl {
    $arch = Get-ArchitectureInfo
    if ($arch.CodexArchitecture -ieq "Arm64") {
        return "https://cloud-images.ubuntu.com/wsl/releases/noble/current/ubuntu-noble-wsl-arm64-24.04lts.rootfs.tar.gz"
    }

    return "https://cloud-images.ubuntu.com/wsl/releases/noble/current/ubuntu-noble-wsl-amd64-24.04lts.rootfs.tar.gz"
}

function Get-WslKernelUpdateMsiUrl {
    $arch = Get-ArchitectureInfo
    if ($arch.CodexArchitecture -ieq "Arm64") {
        return "https://wslstorestorage.blob.core.windows.net/wslblob/wsl_update_arm64.msi"
    }

    return "https://wslstorestorage.blob.core.windows.net/wslblob/wsl_update_x64.msi"
}

function Install-WslKernelUpdatePackage {
    $arch = Get-ArchitectureInfo
    $kernelMsiUrl = Get-WslKernelUpdateMsiUrl
    $kernelMsiPath = Join-Path $script:TempRoot ("wsl-kernel-update-$($arch.CodexArchitecture).msi")

    Write-Info "Installing official WSL2 Linux kernel update package."
    Invoke-WebDownload -Uri $kernelMsiUrl -OutFile $kernelMsiPath

    if (-not $CheckOnly) {
        $signature = Get-AuthenticodeSignature -FilePath $kernelMsiPath
        if ($signature.Status -ne "Valid" -or $null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch "Microsoft") {
            throw "WSL kernel update MSI signature is not valid or not signed by Microsoft. Status: $($signature.Status)"
        }
    }

    $exitCode = Invoke-External -FilePath "msiexec.exe" -Arguments "/i `"$kernelMsiPath`" /qn /norestart" -AllowedExitCodes @(0, 3010)
    if ($exitCode -eq 3010) {
        $script:NeedsReboot = $true
    }

    Write-Ok "WSL2 Linux kernel update package installed."
}

function Test-Wsl2VirtualizationAvailable {
    if ($CheckOnly) {
        return $true
    }

    try {
        $processors = @(Get-CimInstance Win32_Processor -ErrorAction Stop)
        if ($processors.Count -eq 0) {
            return $true
        }

        $hasSlat = $false
        $hasFirmwareVirtualizationProperty = $false
        $hasFirmwareVirtualization = $false

        foreach ($processor in $processors) {
            if ($processor.SecondLevelAddressTranslationExtensions) {
                $hasSlat = $true
            }

            $firmwareVirtualizationProperty = $processor.PSObject.Properties["VirtualizationFirmwareEnabled"]
            if ($null -ne $firmwareVirtualizationProperty) {
                $hasFirmwareVirtualizationProperty = $true
                if ($firmwareVirtualizationProperty.Value) {
                    $hasFirmwareVirtualization = $true
                }
            }
        }

        if (-not $hasSlat) {
            return $false
        }

        if ($hasFirmwareVirtualizationProperty -and -not $hasFirmwareVirtualization) {
            return $false
        }

        return $true
    } catch {
        Write-WarnLine "Could not inspect CPU virtualization flags for WSL2: $($_.Exception.Message)"
        return $true
    }
}

function Get-WslImportInstallDirectory {
    param([Parameter(Mandatory = $true)][string]$DistroName)

    $base = if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Join-Path $env:LOCALAPPDATA "CodexSetup\WSL"
    } elseif (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
        Join-Path $env:ProgramData "CodexSetup\WSL"
    } else {
        Join-Path (Get-SafeTempPath) "CodexSetup\WSL"
    }

    $safeName = ($DistroName -replace '[^A-Za-z0-9_.-]', '-')
    return Join-Path $base $safeName
}

function Initialize-ImportedWslDistro {
    param(
        [Parameter(Mandatory = $true)][string]$WslPath,
        [Parameter(Mandatory = $true)][string]$DistroName,
        [Parameter(Mandatory = $true)][string]$UserName
    )

    $quotedUser = Quote-BashString $UserName
    $initScript = @"
set -e
export DEBIAN_FRONTEND=noninteractive
if command -v apt-get >/dev/null 2>&1; then
  apt-get update
  apt-get install -y sudo curl ca-certificates
fi
groupadd -f sudo || true
if ! id -u $quotedUser >/dev/null 2>&1; then
  useradd -m -s /bin/bash $quotedUser
fi
usermod -aG sudo $quotedUser || true
mkdir -p /etc/sudoers.d
printf '%s ALL=(ALL) NOPASSWD:ALL\n' $quotedUser > /etc/sudoers.d/99-codex
chmod 0440 /etc/sudoers.d/99-codex
printf '[user]\ndefault=%s\n' $quotedUser > /etc/wsl.conf
"@

    Invoke-NativeCommand -FilePath $WslPath -Arguments @("-d", $DistroName, "-u", "root", "--", "bash", "-lc", $initScript) -AllowedExitCodes @(0) | Out-Null

    try {
        Invoke-NativeCommand -FilePath $WslPath -Arguments @("--terminate", $DistroName) -AllowedExitCodes @(0) | Out-Null
    } catch {
        Write-WarnLine "Could not terminate $DistroName after non-interactive initialization: $($_.Exception.Message)"
    }
}

function Expand-GZipFile {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    if ($CheckOnly) {
        Write-Info "[check] Would decompress gzip file: $SourcePath"
        return
    }

    Add-Type -AssemblyName System.IO.Compression
    New-Item -ItemType Directory -Path (Split-Path -Parent $DestinationPath) -Force | Out-Null

    $sourceStream = [System.IO.File]::OpenRead($SourcePath)
    try {
        $destinationStream = [System.IO.File]::Create($DestinationPath)
        try {
            $gzipStream = New-Object System.IO.Compression.GZipStream($sourceStream, [System.IO.Compression.CompressionMode]::Decompress)
            try {
                $gzipStream.CopyTo($destinationStream)
            } finally {
                $gzipStream.Dispose()
            }
        } finally {
            $destinationStream.Dispose()
        }
    } finally {
        $sourceStream.Dispose()
    }
}

function Reset-WslImportInstallDirectory {
    param([Parameter(Mandatory = $true)][string]$InstallDirectory)

    if ($CheckOnly) {
        Write-Info "[check] Would prepare WSL import directory: $InstallDirectory"
        return $InstallDirectory
    }

    $base = if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Join-Path $env:LOCALAPPDATA "CodexSetup\WSL"
    } elseif (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
        Join-Path $env:ProgramData "CodexSetup\WSL"
    } else {
        Join-Path (Get-SafeTempPath) "CodexSetup\WSL"
    }

    $baseFullPath = [System.IO.Path]::GetFullPath($base).TrimEnd("\")
    $installFullPath = [System.IO.Path]::GetFullPath($InstallDirectory).TrimEnd("\")

    if ($installFullPath -ne $baseFullPath -and -not $installFullPath.StartsWith($baseFullPath + "\", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean unexpected WSL import directory outside ${baseFullPath}: $installFullPath"
    }

    $targetDirectory = $InstallDirectory
    if (Test-Path -LiteralPath $InstallDirectory) {
        $existingContent = @(Get-ChildItem -LiteralPath $InstallDirectory -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($existingContent.Count -gt 0) {
            $parent = Split-Path -Parent $InstallDirectory
            $leaf = Split-Path -Leaf $InstallDirectory
            $targetDirectory = Join-Path $parent ("$leaf-retry-" + [Guid]::NewGuid().ToString("N"))
            Write-WarnLine "WSL import directory is not empty; using a fresh retry directory: $targetDirectory"
        }
    }

    New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
    return $targetDirectory
}

function Invoke-WslDiagnosticCommand {
    param(
        [Parameter(Mandatory = $true)][string]$WslPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ($CheckOnly) {
        Write-Info "[check] Would run WSL diagnostic: $Label"
        return
    }

    try {
        $output = & $WslPath @Arguments 2>&1
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
        Write-Info "$Label exit code: $exitCode"

        foreach ($line in @($output)) {
            $text = ([string]$line -replace "`0", "").TrimEnd()
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                Write-Info "  $text"
            }
        }
    } catch {
        Write-Info "$Label failed: $($_.Exception.Message)"
    }
}

function Write-WslDiagnostics {
    param([Parameter(Mandatory = $true)][string]$WslPath)

    Write-Info "WSL diagnostics:"
    foreach ($featureName in @("Microsoft-Windows-Subsystem-Linux", "VirtualMachinePlatform")) {
        Write-Info "  Optional feature ${featureName}: $(Get-WindowsOptionalFeatureState -FeatureName $featureName)"
    }

    try {
        $service = Get-Service -Name "LxssManager" -ErrorAction Stop
        Write-Info "  LxssManager service: $($service.Status), start type: $($service.StartType)"
    } catch {
        Write-Info "  LxssManager service: unavailable ($($_.Exception.Message))"
    }

    Invoke-WslDiagnosticCommand -WslPath $WslPath -Arguments @("--version") -Label "wsl --version"
    Invoke-WslDiagnosticCommand -WslPath $WslPath -Arguments @("--status") -Label "wsl --status"
    Invoke-WslDiagnosticCommand -WslPath $WslPath -Arguments @("-l", "-v") -Label "wsl -l -v"
}

function Invoke-WslImportAttempt {
    param(
        [Parameter(Mandatory = $true)][string]$WslPath,
        [Parameter(Mandatory = $true)][string]$DistroName,
        [Parameter(Mandatory = $true)][string]$InstallDirectory,
        [Parameter(Mandatory = $true)][string]$RootfsPath,
        [Parameter(Mandatory = $true)][string]$Label,
        [ValidateSet(0, 1, 2)][int]$WslVersion = 0
    )

    if ((Get-WslDistroNames -WslPath $WslPath) -contains $DistroName) {
        Write-Ok "WSL distro was registered during a previous import attempt: $DistroName"
        return
    }

    $attemptInstallDirectory = Reset-WslImportInstallDirectory -InstallDirectory $InstallDirectory

    $arguments = @("--import", $DistroName, $attemptInstallDirectory, $RootfsPath)
    if ($WslVersion -ne 0) {
        $arguments += @("--version", [string]$WslVersion)
    }

    Write-Info "Trying wsl --import with $Label."
    try {
        Invoke-NativeCommand -FilePath $WslPath -Arguments $arguments -AllowedExitCodes @(0) | Out-Null
    } catch {
        if ((Get-WslDistroNames -WslPath $WslPath) -contains $DistroName) {
            Write-WarnLine "wsl --import returned an error, but $DistroName is registered. Continuing."
            return
        }

        throw
    }
}

function Import-UbuntuWslRootfs {
    param(
        [Parameter(Mandatory = $true)][string]$WslPath,
        [Parameter(Mandatory = $true)][string]$DistroName,
        [switch]$SkipWsl2
    )

    if ($DistroName -notmatch "^Ubuntu") {
        throw "Store-free WSL import fallback currently supports Ubuntu distro names only. Requested: $DistroName"
    }

    $rootfsUrl = Get-UbuntuWslRootfsUrl
    $rootfsGzipPath = Join-Path $script:TempRoot "ubuntu-wsl.rootfs.tar.gz"
    $rootfsTarPath = Join-Path $script:TempRoot "ubuntu-wsl.rootfs.tar"
    $installDirectory = Get-WslImportInstallDirectory -DistroName $DistroName
    $attemptErrors = New-Object System.Collections.Generic.List[string]

    Write-Info "Downloading official Ubuntu WSL rootfs without Microsoft Store."
    Write-Info "This is a large download and may take several minutes on slow connections."
    Invoke-WebDownload -Uri $rootfsUrl -OutFile $rootfsGzipPath

    if ($CheckOnly) {
        Write-Info "[check] Would import $DistroName into WSL from Ubuntu rootfs."
        return
    }

    $rootfsFile = Get-Item -LiteralPath $rootfsGzipPath -ErrorAction Stop
    if ($rootfsFile.Length -lt [int64](50MB)) {
        throw "Downloaded Ubuntu WSL rootfs is unexpectedly small ($($rootfsFile.Length) bytes). Check network, proxy, or firewall settings and rerun setup."
    }

    $imported = $false
    $compressedAttempts = @()
    if (-not $SkipWsl2) {
        $compressedAttempts += @{ Label = "compressed rootfs and WSL 2"; Path = $rootfsGzipPath; WslVersion = 2 }
        $compressedAttempts += @{ Label = "compressed rootfs and default WSL version"; Path = $rootfsGzipPath; WslVersion = 0 }
    }
    $compressedAttempts += @{ Label = "compressed rootfs and WSL 1"; Path = $rootfsGzipPath; WslVersion = 1 }

    foreach ($attempt in $compressedAttempts) {
        try {
            Invoke-WslImportAttempt -WslPath $WslPath -DistroName $DistroName -InstallDirectory $installDirectory -RootfsPath $attempt.Path -Label $attempt.Label -WslVersion ([int]$attempt.WslVersion)
            $imported = $true
            break
        } catch {
            $message = "$($attempt.Label): $($_.Exception.Message)"
            $attemptErrors.Add($message) | Out-Null
            Write-WarnLine "wsl --import failed with $($attempt.Label): $($_.Exception.Message)"
        }
    }

    if (-not $imported) {
        Write-Info "Decompressing Ubuntu rootfs for legacy WSL import."
        Expand-GZipFile -SourcePath $rootfsGzipPath -DestinationPath $rootfsTarPath

        $plainTarAttempts = @()
        if (-not $SkipWsl2) {
            $plainTarAttempts += @{ Label = "decompressed tar rootfs and WSL 2"; Path = $rootfsTarPath; WslVersion = 2 }
            $plainTarAttempts += @{ Label = "decompressed tar rootfs and default WSL version"; Path = $rootfsTarPath; WslVersion = 0 }
        }
        $plainTarAttempts += @{ Label = "decompressed tar rootfs and WSL 1"; Path = $rootfsTarPath; WslVersion = 1 }

        foreach ($attempt in $plainTarAttempts) {
            try {
                Invoke-WslImportAttempt -WslPath $WslPath -DistroName $DistroName -InstallDirectory $installDirectory -RootfsPath $attempt.Path -Label $attempt.Label -WslVersion ([int]$attempt.WslVersion)
                $imported = $true
                break
            } catch {
                $message = "$($attempt.Label): $($_.Exception.Message)"
                $attemptErrors.Add($message) | Out-Null
                Write-WarnLine "wsl --import failed with $($attempt.Label): $($_.Exception.Message)"
            }
        }
    }

    if (-not $imported) {
        Write-WslDiagnostics -WslPath $WslPath
        throw "Ubuntu rootfs import failed after compressed and decompressed tar attempts. $($attemptErrors -join ' | ')"
    }

    Initialize-ImportedWslDistro -WslPath $WslPath -DistroName $DistroName -UserName $WslUser
    $script:WslDistroImportedThisRun = $true
    Write-Ok "Imported and initialized $DistroName from official Ubuntu WSL rootfs."
}

function Ensure-Wsl {
    if (-not (Test-IsAdmin)) {
        throw "WSL feature installation needs an elevated prompt."
    }

    $support = Get-WindowsSupportInfo
    if (-not $support.SupportsWslOneCommand) {
        Set-ComponentWarning "Windows build is too old for scripted WSL setup."
        Write-WarnLine "WSL install skipped: Windows 10 2004/build 19041 or newer is required for this scripted WSL setup."
        Add-DeferredAction "Upgrade Windows to build 19041+ before installing WSL/Ubuntu and Codex CLI inside WSL."
        return
    }

    $wslExe = Join-Path $env:WINDIR "System32\wsl.exe"
    if (-not (Test-Path -LiteralPath $wslExe)) {
        $wslExe = "wsl.exe"
    }

    $wslFeatureEnabledBefore = Test-WindowsOptionalFeatureEnabled -FeatureName "Microsoft-Windows-Subsystem-Linux"
    $vmFeatureEnabledBefore = Test-WindowsOptionalFeatureEnabled -FeatureName "VirtualMachinePlatform"
    $wsl2VirtualizationAvailable = Test-Wsl2VirtualizationAvailable

    if (-not $wslFeatureEnabledBefore) {
        $exitCode = Invoke-External -FilePath "dism.exe" -Arguments "/online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart" -AllowedExitCodes @(0, 3010)
        if ($exitCode -eq 3010) {
            $script:NeedsReboot = $true
        }
    } else {
        Write-Ok "WSL optional feature is already enabled."
    }

    if (-not $wsl2VirtualizationAvailable) {
        Set-ComponentWarning "WSL2 virtualization prerequisites are unavailable; using WSL1."
        Write-WarnLine "WSL2 virtualization prerequisites are unavailable in this VM. Using WSL1 for Ubuntu/Codex instead."
        if ($vmFeatureEnabledBefore) {
            Write-Ok "Virtual Machine Platform optional feature is already enabled."
        } else {
            Write-WarnLine "Skipping Virtual Machine Platform enablement because WSL2 cannot run without SLAT/nested virtualization."
        }
    } elseif (-not $vmFeatureEnabledBefore) {
        $exitCode = Invoke-External -FilePath "dism.exe" -Arguments "/online /enable-feature /featurename:VirtualMachinePlatform /all /norestart" -AllowedExitCodes @(0, 3010)
        if ($exitCode -eq 3010) {
            $script:NeedsReboot = $true
        }
    } else {
        Write-Ok "Virtual Machine Platform optional feature is already enabled."
    }

    $wslFeatureEnabledAfter = Test-WindowsOptionalFeatureEnabled -FeatureName "Microsoft-Windows-Subsystem-Linux"
    $vmFeatureEnabledAfter = if ($wsl2VirtualizationAvailable) { Test-WindowsOptionalFeatureEnabled -FeatureName "VirtualMachinePlatform" } else { $vmFeatureEnabledBefore }
    if (((-not $wslFeatureEnabledBefore) -and $wslFeatureEnabledAfter) -or ($wsl2VirtualizationAvailable -and (-not $vmFeatureEnabledBefore) -and $vmFeatureEnabledAfter)) {
        $script:NeedsReboot = $true
        Add-DeferredAction "Reboot Windows, then rerun this script to finish WSL distro setup and Codex CLI inside WSL."
    }

    if ($script:NeedsReboot) {
        Set-ComponentWarning "Reboot required before WSL distro setup can continue."
        Write-WarnLine "WSL features were enabled and a reboot is required before WSL update/default-version/distro setup."
        return
    }

    $rebootPending = Test-WindowsRebootPending
    if ($rebootPending -and -not (Test-WslEngineAvailable -WslPath $wslExe)) {
        $script:NeedsReboot = $true
        Set-ComponentWarning "Windows has a pending reboot; WSL setup will continue after reboot."
        Add-DeferredAction "Reboot Windows, then rerun this script to finish WSL distro setup and Codex CLI inside WSL."
        Write-WarnLine "Windows reports a pending reboot. Skipping WSL update/default-version/distro setup until after reboot."
        return
    } elseif ($rebootPending) {
        Write-WarnLine "Windows reports a pending reboot, but WSL is responding; continuing WSL setup."
    }

    if ($wsl2VirtualizationAvailable) {
        try {
            Invoke-NativeCommand -FilePath $wslExe -Arguments @("--update", "--web-download") -AllowedExitCodes @(0) | Out-Null
        } catch {
            Write-WarnLine "wsl --update --web-download failed, retrying without --web-download."
            try {
                Invoke-NativeCommand -FilePath $wslExe -Arguments @("--update") -AllowedExitCodes @(0) | Out-Null
            } catch {
                Write-WarnLine "wsl --update failed: $($_.Exception.Message)"
                try {
                    Install-WslKernelUpdatePackage
                } catch {
                    Write-WarnLine "Official WSL2 kernel update package install failed: $($_.Exception.Message)"
                }
            }
        }

        if ($script:NeedsReboot) {
            Set-ComponentWarning "Reboot required after WSL kernel update package install."
            Add-DeferredAction "Reboot Windows, then rerun this script to finish WSL distro setup and Codex CLI inside WSL."
            Write-WarnLine "WSL kernel update package requested a reboot before distro setup can continue."
            return
        }

        try {
            Invoke-NativeCommand -FilePath $wslExe -Arguments @("--set-default-version", "2") -AllowedExitCodes @(0) | Out-Null
        } catch {
            Write-WarnLine "Could not set WSL default version to 2 yet: $($_.Exception.Message)"
        }
    } else {
        Write-WarnLine "Skipping WSL2 update/default-version steps because this VM does not expose SLAT/nested virtualization."
    }

    $distros = Get-WslDistroNames -WslPath $wslExe

    if ($distros -contains $WslDistro) {
        Write-Ok "WSL distro is installed: $WslDistro"
    } else {
        if ($support.IsServer) {
            Write-WarnLine "Windows Server detected. Using Store-free Ubuntu rootfs import instead of interactive wsl --install distro flow."
            try {
                Import-UbuntuWslRootfs -WslPath $wslExe -DistroName $WslDistro -SkipWsl2:(-not $wsl2VirtualizationAvailable)
                return
            } catch {
                Write-WarnLine "Store-free Ubuntu WSL import failed: $($_.Exception.Message)"
                Set-ComponentWarning "WSL distro import did not finish automatically."
                Add-DeferredAction "WSL distro import failed. Check the log, then rerun this script after reboot/network repair."
                return
            }
        }

        Write-Info "Installing WSL distro: $WslDistro"
        $distroInstallError = $null
        try {
            Invoke-NativeCommand -FilePath $wslExe -Arguments @("--install", "--web-download", "-d", $WslDistro, "--no-launch") -AllowedExitCodes @(0) | Out-Null
        } catch {
            $distroInstallError = $_.Exception.Message
            Write-WarnLine "wsl --install --web-download failed, retrying normal WSL install: $distroInstallError"
            try {
                Invoke-NativeCommand -FilePath $wslExe -Arguments @("--install", "-d", $WslDistro, "--no-launch") -AllowedExitCodes @(0) | Out-Null
                $distroInstallError = $null
            } catch {
                $distroInstallError = $_.Exception.Message
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($distroInstallError)) {
            Write-WarnLine "WSL distro install did not complete automatically: $distroInstallError"
            Write-WarnLine "Trying Store-free Ubuntu rootfs import fallback."
            try {
                Import-UbuntuWslRootfs -WslPath $wslExe -DistroName $WslDistro -SkipWsl2:(-not $wsl2VirtualizationAvailable)
                return
            } catch {
                Write-WarnLine "Store-free Ubuntu WSL import failed: $($_.Exception.Message)"
                Set-ComponentWarning "WSL distro install/import did not finish automatically."
                Add-DeferredAction "Install $WslDistro manually from an elevated PowerShell with: wsl --install -d $WslDistro"
                return
            }
        }

        $script:WslDistroInstalledThisRun = $true
        Set-ComponentWarning "WSL distro install command completed, but first launch may still need Linux user creation."
        Add-DeferredAction "Launch $WslDistro once, create the Linux user, then rerun this script to install Codex CLI inside WSL."
        Write-Ok "WSL distro install command completed. First launch may still ask for a Linux username."
    }
}

function Install-CodexCliInWsl {
    $support = Get-WindowsSupportInfo
    if (-not $support.SupportsWslOneCommand) {
        Set-ComponentWarning "Windows build is too old for scripted Codex-in-WSL setup."
        Write-WarnLine "Codex-in-WSL install skipped: Windows 10 2004/build 19041 or newer is required for this scripted WSL setup."
        return
    }

    $wslExe = Join-Path $env:WINDIR "System32\wsl.exe"
    if (-not (Test-Path -LiteralPath $wslExe)) {
        $wslExe = "wsl.exe"
    }

    if ($script:NeedsReboot) {
        Set-ComponentWarning "Reboot required before Codex CLI can be installed inside WSL."
        Write-WarnLine "Skipping Codex-in-WSL install until after reboot."
        return
    }

    if ($script:WslDistroInstalledThisRun) {
        Set-ComponentWarning "WSL distro was installed and still needs first-launch initialization."
        Write-WarnLine "Skipping Codex-in-WSL because $WslDistro was installed in this run and still needs first-launch user creation."
        return
    }

    $distros = Get-WslDistroNames -WslPath $wslExe
    if ($distros -notcontains $WslDistro) {
        Set-ComponentWarning "WSL distro '$WslDistro' is not installed yet."
        Write-WarnLine "WSL distro '$WslDistro' is not installed yet. Install/initialize it, then rerun this script."
        Add-DeferredAction "Install and launch $WslDistro once, then rerun this script to install Codex CLI inside WSL."
        return
    }

    if (-not (Test-WslDistroInitialized -WslPath $wslExe -DistroName $WslDistro)) {
        Set-ComponentWarning "WSL distro '$WslDistro' is not initialized yet."
        Write-WarnLine "WSL distro '$WslDistro' is not initialized yet. Open it once, create the Linux user, then rerun this script."
        Add-DeferredAction "Launch $WslDistro once, create the Linux user, then rerun this script to install Codex CLI inside WSL."
        return
    }

    try {
        Invoke-NativeCommand -FilePath $wslExe -Arguments @("-d", $WslDistro, "-u", "root", "--", "bash", "-lc", "if command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y curl ca-certificates; fi") -AllowedExitCodes @(0) | Out-Null
    } catch {
        Write-WarnLine "Could not install curl/ca-certificates in WSL as root: $($_.Exception.Message)"
    }

    Invoke-NativeCommand -FilePath $wslExe -Arguments @("-d", $WslDistro, "--", "bash", "-lc", "set -e; curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh; if command -v codex >/dev/null 2>&1; then codex --version; elif [ -x ~/.local/bin/codex ]; then ~/.local/bin/codex --version; else echo 'Codex installed, but it is not on PATH yet.'; fi") -AllowedExitCodes @(0) | Out-Null
    Write-Ok "Codex CLI install in WSL completed."
}

function Install-RecommendedDevTools {
    $support = Get-WindowsSupportInfo
    if (-not $support.SupportsWinget) {
        Write-WarnLine "Recommended developer tools skipped: winget is not supported for this OS/edition by this script."
        return
    }

    $winget = Ensure-Winget
    $packages = @(
        @{ Id = "Git.Git"; Name = "Git" },
        @{ Id = "Python.Python.3.12"; Name = "Python 3.12" },
        @{ Id = "GitHub.cli"; Name = "GitHub CLI" }
    )

    foreach ($package in $packages) {
        Write-Info "Installing/updating $($package.Name) with winget."
        try {
            Invoke-NativeCommand -FilePath $winget -Arguments @(
                "install",
                "--id", $package.Id,
                "-e",
                "--accept-package-agreements",
                "--accept-source-agreements",
                "--disable-interactivity"
            ) -AllowedExitCodes @(0) | Out-Null
        } catch {
            Write-WarnLine "winget install for $($package.Name) did not complete cleanly: $($_.Exception.Message)"
        }
    }
}

function Update-WingetState {
    $support = Get-WindowsSupportInfo
    if (-not $support.SupportsWinget) {
        Write-WarnLine "winget source/package update skipped: winget is not supported for this OS/edition by this script."
        return
    }

    $winget = Ensure-Winget

    try {
        Invoke-NativeCommand -FilePath $winget -Arguments @("source", "update") -AllowedExitCodes @(0) | Out-Null
    } catch {
        Write-WarnLine "winget source update failed: $($_.Exception.Message)"
        Repair-WingetSources -WingetPath $winget
    }
    Write-Ok "winget sources updated."

    if ($UpdateAllWingetPackages) {
        Write-Info "Updating all winget-managed packages because -UpdateAllWingetPackages was specified."
        Invoke-NativeCommand -FilePath $winget -Arguments @(
            "upgrade",
            "--all",
            "--accept-package-agreements",
            "--accept-source-agreements",
            "--disable-interactivity"
        ) -AllowedExitCodes @(0) | Out-Null
        Write-Ok "winget upgrade --all completed."
    } else {
        Write-Info "Full winget upgrade is disabled by default. Use -UpdateAllWingetPackages to update all winget-managed apps."
    }
}

function Invoke-WindowsUpdateMaintenance {
    if (-not $RunWindowsUpdate) {
        Write-Info "Windows Update install is disabled by default. Use -RunWindowsUpdate to trigger a Windows Update scan/download/install."
        return
    }

    $usoClient = Join-Path $env:WINDIR "System32\UsoClient.exe"
    if (-not (Test-Path -LiteralPath $usoClient)) {
        throw "UsoClient.exe was not found. Cannot trigger Windows Update from this script."
    }

    foreach ($serviceName in @("wuauserv", "bits")) {
        try {
            $service = Get-Service -Name $serviceName -ErrorAction Stop
            if ($service.StartType -eq "Disabled") {
                Write-WarnLine "Windows Update service '$serviceName' is disabled. Attempting to set it to Manual."
                if (-not $CheckOnly) {
                    Set-Service -Name $serviceName -StartupType Manual
                }
            }
        } catch {
            Write-WarnLine "Could not inspect or adjust service '$serviceName': $($_.Exception.Message)"
        }
    }

    Write-Info "Triggering Windows Update scan/download/install. Windows may continue this work after the script exits."
    Invoke-External -FilePath $usoClient -Arguments "StartScan" -AllowedExitCodes @(0) | Out-Null
    Start-Sleep -Seconds 3
    Invoke-External -FilePath $usoClient -Arguments "StartDownload" -AllowedExitCodes @(0) | Out-Null
    Start-Sleep -Seconds 3
    Invoke-External -FilePath $usoClient -Arguments "StartInstall" -AllowedExitCodes @(0) | Out-Null
    Write-Ok "Windows Update commands were submitted."
}

function Show-SystemReport {
    Write-Step "System report"

    try {
        $os = Get-CimInstance Win32_OperatingSystem
        Write-Info "OS: $($os.Caption) $($os.Version) build $($os.BuildNumber)"
    } catch {
        Write-Info "OS: unavailable"
    }

    try {
        $arch = Get-ArchitectureInfo
        Write-Info "Architecture: $($arch.Label)"
    } catch {
        Write-WarnLine $_.Exception.Message
    }

    Write-Info "Current PowerShell: $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    Write-Info "Administrator: $(if (Test-IsAdmin) { 'yes' } else { 'no' })"

    try {
        $launch = Get-LaunchEnvironment
        Write-Info "Launch host: $($launch.HostName)"
        Write-Info "Terminal: $($launch.Terminal), parent: $($launch.ParentProcess), portable pwsh: $($launch.PortablePwsh)"
        Write-Info "Process: $($launch.ProcessPath)"
        Write-Info "PSHOME: $($launch.PSHome)"
        Write-Info "Execution policy: $($launch.ExecutionPolicy)"
    } catch {
        Write-WarnLine "Launch environment report failed: $($_.Exception.Message)"
    }

    $pwshPath = Get-PwshCommand
    if (-not [string]::IsNullOrWhiteSpace($pwshPath)) {
        try {
            $pwshVersion = & $pwshPath -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null
            Write-Info "pwsh: $pwshPath $pwshVersion"
        } catch {
            Write-Info "pwsh: $pwshPath"
        }
    } else {
        Write-Info "pwsh: not found"
    }

    $winget = Get-WingetPath
    if ($null -ne $winget) {
        try {
            $wingetVersion = & $winget --version 2>$null
            Write-Info "winget: $winget $wingetVersion"
        } catch {
            Write-Info "winget: $winget"
        }
    } else {
        Write-Info "winget: not found"
    }

    $nodeVersion = Get-CommandVersion -CommandName "node.exe" -Arguments @("-v")
    $npmVersion = Get-CommandVersion -CommandName "npm.cmd" -Arguments @("-v")
    $codexVersion = Get-CodexCommandVersion
    $vcRedist = Get-VcRedistRegistryInfo
    Write-Info "node: $(if ($nodeVersion) { $nodeVersion } else { 'not found' })"
    Write-Info "npm: $(if ($npmVersion) { $npmVersion } else { 'not found' })"
    Write-Info "codex CLI: $(if ($codexVersion) { $codexVersion } else { 'not found' })"
    Write-Info "VC++ Redistributable: $(if ($vcRedist -and $vcRedist.Installed -eq 1) { "$($vcRedist.Arch) $($vcRedist.Version)" } else { 'not found' })"

    $storePackage = Get-AppxPackageText -PackageName "Microsoft.WindowsStore"
    $appInstallerPackage = Get-AppxPackageText -PackageName "Microsoft.DesktopAppInstaller"
    $codexDesktopPackage = Get-AppxPackageText -PackageName "OpenAI.Codex"
    Write-Info "Microsoft Store package: $(if ($storePackage) { 'present' } else { 'not found' })"
    Write-Info "App Installer package: $(if ($appInstallerPackage) { 'present' } else { 'not found' })"
    Write-Info "Codex Desktop package: $(if ($codexDesktopPackage) { 'present' } else { 'not found' })"

    try {
        $wslStatus = & wsl.exe --status 2>$null
        if ($LASTEXITCODE -eq 0 -and $null -ne $wslStatus) {
            Write-Info "WSL status:"
            $wslStatus | ForEach-Object { Write-Info "  $_" }
        } else {
            Write-Info "WSL status: unavailable"
        }
    } catch {
        Write-Info "WSL status: unavailable"
    }
}

function Show-FinalSummary {
    Write-Step "Final summary"
    foreach ($result in $script:Results) {
        $line = $result.Name
        if (-not [string]::IsNullOrWhiteSpace($result.Detail)) {
            $line = "$line - $($result.Detail)"
        }

        if ($result.Status -eq "FAILED") {
            Write-FailLine $line
        } elseif ($result.Status -eq "WARN") {
            Write-WarnLine $line
        } else {
            Write-Ok $line
        }
    }

    if ($script:NeedsReboot) {
        Write-WarnLine "A reboot is required or recommended before WSL/installed tools are fully available."
    }

    if ($script:DeferredActions.Count -gt 0) {
        Write-WarnLine "Follow-up actions:"
        foreach ($action in ($script:DeferredActions | Select-Object -Unique)) {
            Write-Info "- $action"
        }
    }

    Write-Info "Log: $script:LogPath"
    Write-Info "Elapsed: $([int]((Get-Date) - $script:StartedAt).TotalSeconds)s"
}

try {
    Show-SystemReport

    if ($InstallCodexInWsl) {
        Write-WarnLine "-InstallCodexInWsl is deprecated because Codex CLI inside WSL is installed by default. Use -SkipCodexCliInWsl to skip it."
    }

    Invoke-Component -Name "Windows support preflight" -Body {
        Assert-WindowsSupport
    }
    if ($script:HadFailures -and -not $SkipWindowsSupportCheck) {
        Show-FinalSummary
        exit 1
    }

    Invoke-Component -Name "PowerShell execution policy repair" -Body {
        Repair-ExecutionPolicy
    }

    if (-not $SkipStoreRepair) {
        Invoke-Component -Name "Microsoft Store and App Installer repair" -Body {
            Repair-StorePackages
        }
    } else {
        Add-Result -Name "Microsoft Store and App Installer repair" -Status "OK" -Detail "Skipped by parameter."
    }

    $supportForWinget = $null
    try {
        $supportForWinget = Get-WindowsSupportInfo
    } catch {
    }

    if (-not $SkipWingetRepair -and ($null -eq $supportForWinget -or $supportForWinget.SupportsWinget)) {
        Invoke-Component -Name "winget availability" -Body {
            $null = Ensure-Winget
        }
    } else {
        $wingetSkipReason = if ($SkipWingetRepair) { "Skipped by parameter." } else { "Skipped because winget is not supported for this OS/edition by this script." }
        Add-Result -Name "winget availability" -Status "OK" -Detail $wingetSkipReason
    }

    if (-not $SkipWingetRepair) {
        Invoke-Component -Name "winget source/package update" -Body {
            Update-WingetState
        }
    } else {
        Add-Result -Name "winget source/package update" -Status "OK" -Detail "Skipped because winget repair was skipped."
    }

    Invoke-Component -Name "Windows Update maintenance" -Body {
        Invoke-WindowsUpdateMaintenance
    }

    if (-not $SkipPowerShell) {
        Invoke-Component -Name "PowerShell 7 install/update" -Body {
            Install-PowerShell7
        }
    } else {
        Add-Result -Name "PowerShell 7 install/update" -Status "OK" -Detail "Skipped by parameter."
    }

    if (-not $SkipNode) {
        Invoke-Component -Name "Node.js LTS install/update" -Body {
            Install-NodeLts
        }
    } else {
        Add-Result -Name "Node.js LTS install/update" -Status "OK" -Detail "Skipped by parameter."
    }

    if (-not $SkipVcRedist) {
        Invoke-Component -Name "Microsoft Visual C++ Redistributable install/update" -Body {
            Install-VcRedist
        }
    } else {
        Add-Result -Name "Microsoft Visual C++ Redistributable install/update" -Status "OK" -Detail "Skipped by parameter."
    }

    if (-not $SkipCodexCli) {
        Invoke-Component -Name "Codex CLI install/update" -Body {
            Install-CodexCli
        }
    } else {
        Add-Result -Name "Codex CLI install/update" -Status "OK" -Detail "Skipped by parameter."
    }

    if (-not $SkipCodexDesktop) {
        Invoke-Component -Name "Codex Desktop install/update" -Body {
            Install-CodexDesktop
        }
    } else {
        Add-Result -Name "Codex Desktop install/update" -Status "OK" -Detail "Skipped by parameter."
    }

    if (-not $SkipWsl) {
        Invoke-Component -Name "WSL install/update" -Body {
            Ensure-Wsl
        }

        if (-not $SkipCodexCliInWsl) {
            Invoke-Component -Name "Codex CLI install/update in WSL" -Body {
                Install-CodexCliInWsl
            }
        } else {
            Add-Result -Name "Codex CLI install/update in WSL" -Status "OK" -Detail "Skipped by parameter."
        }
    } else {
        Add-Result -Name "WSL install/update" -Status "OK" -Detail "Skipped by parameter."
        Add-Result -Name "Codex CLI install/update in WSL" -Status "OK" -Detail "Skipped because WSL was skipped."
    }

    if ($InstallRecommendedDevTools) {
        Invoke-Component -Name "Recommended developer tools install/update" -Body {
            Install-RecommendedDevTools
        }
    }

    Show-SystemReport

    if ($script:NeedsReboot -and -not $script:HadFailures) {
        Invoke-Component -Name "Setup auto-resume" -Body {
            Enable-SetupAutoResume
        }
    } elseif (-not $script:NeedsReboot) {
        Clear-SetupAutoResume
    }

    Show-FinalSummary
} finally {
    try {
        Stop-Transcript | Out-Null
    } catch {
    }

    if (Test-Path -LiteralPath $script:TempRoot) {
        Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($script:HadFailures) {
    exit 1
}

if ($script:NeedsReboot) {
    exit 3010
}

exit 0
