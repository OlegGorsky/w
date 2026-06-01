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
    [string]$WslDistro = "Ubuntu"
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
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
    foreach ($entry in $PSBoundParameters.GetEnumerator()) {
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

$script:StartedAt = Get-Date
$script:NeedsReboot = $false
$script:HadFailures = $false
$script:WslDistroInstalledThisRun = $false
$script:Results = New-Object System.Collections.Generic.List[object]
$script:DeferredActions = New-Object System.Collections.Generic.List[string]
$script:TempRoot = Join-Path $env:TEMP ("codex-windows-setup-" + [Guid]::NewGuid().ToString("N"))
$script:LogPath = Join-Path $env:TEMP ("codex-windows-setup-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

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
    $isWindows11 = $build -ge 22000

    return [PSCustomObject]@{
        Caption                = [string]$os.Caption
        Version                = [string]$os.Version
        Build                  = $build
        ProductType            = [int]$os.ProductType
        IsServer               = $isServer
        IsWindows11            = $isWindows11
        SupportsWinget         = (-not $isServer) -and $build -ge 17763
        SupportsStoreApps      = (-not $isServer) -and $build -ge 17763
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
        Write-WarnLine "Windows Server detected. Microsoft Store/Codex Desktop and winget msstore flows may be unavailable; CLI and WSL steps will still be attempted where supported."
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
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -Headers @{ "User-Agent" = "CodexWindowsSetup/1.0" }
    try { Unblock-File -Path $OutFile -ErrorAction SilentlyContinue } catch {}
}

function Invoke-RestJson {
    param([Parameter(Mandatory = $true)][string]$Uri)

    return Invoke-RestMethod -Uri $Uri -UseBasicParsing -Headers @{ "User-Agent" = "CodexWindowsSetup/1.0" }
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

function Get-WingetPath {
    $candidates = @()

    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($null -ne $cmd -and (Test-Path -LiteralPath $cmd.Source)) {
        $candidates += $cmd.Source
    }

    $candidates += Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\winget.exe"

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
    try {
        & $Body
        Add-Result -Name $Name -Status "OK" -Detail ""
    } catch {
        $script:HadFailures = $true
        Write-FailLine $_.Exception.Message
        Add-Result -Name $Name -Status "FAILED" -Detail $_.Exception.Message
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
        Add-CurrentProcessPath -Entry (Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps")
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
    $psRoot = Join-Path $env:ProgramFiles "PowerShell"
    if (Test-Path -LiteralPath $psRoot) {
        $programFilesPwsh = @(Get-ChildItem -Path $psRoot -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName "pwsh.exe" } |
            Where-Object { Test-Path -LiteralPath $_ })
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
        $nodeDir = Join-Path $env:ProgramFiles "nodejs"
        Add-CurrentProcessPath -Entry $nodeDir
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

    $nodeDir = Join-Path $env:ProgramFiles "nodejs"
    Add-CurrentProcessPath -Entry $nodeDir
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

    $codexBin = Join-Path $env:LOCALAPPDATA "Programs\OpenAI\Codex\bin"
    $npmBin = Join-Path $env:APPDATA "npm"
    Add-UserPath -Entry $codexBin -Prepend
    Add-UserPath -Entry $npmBin

    $version = Get-CodexCommandVersion
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "Codex CLI was installed, but codex is not available on PATH. Checked standalone path and npm global shim path."
    }

    Write-Ok "Codex CLI available: $version"
}

function Install-CodexDesktop {
    $support = Get-WindowsSupportInfo
    if (-not $support.SupportsStoreApps) {
        Write-WarnLine "Codex Desktop install skipped: Microsoft Store apps are not supported for this OS/edition by this script."
        Add-DeferredAction "Install Codex Desktop manually on a supported Windows client build if this machine needs the desktop app."
        return
    }

    $winget = Ensure-Winget

    try {
        Invoke-NativeCommand -FilePath $winget -Arguments @("source", "update") -AllowedExitCodes @(0) | Out-Null
    } catch {
        Write-WarnLine "winget source update failed: $($_.Exception.Message)"
        Repair-WingetSources -WingetPath $winget
    }

    $desktopPackage = Get-AppxPackageText -PackageName "OpenAI.Codex"
    if ([string]::IsNullOrWhiteSpace($desktopPackage)) {
        $desktopPackage = Get-AppxPackageText -PackageName "*Codex*"
    }

    $storePackageIds = @("9PLM9XGG6VKS", "Codex")
    $lastWingetError = $null

    if ([string]::IsNullOrWhiteSpace($desktopPackage)) {
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
    $arguments = "-d `"$DistroName`" -u root -- sh -lc `"exit 0`""

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

function Ensure-Wsl {
    if (-not (Test-IsAdmin)) {
        throw "WSL feature installation needs an elevated prompt."
    }

    $support = Get-WindowsSupportInfo
    if (-not $support.SupportsWslOneCommand) {
        Write-WarnLine "WSL install skipped: Windows 10 2004/build 19041 or newer is required for this scripted WSL setup."
        Add-DeferredAction "Upgrade Windows to build 19041+ before installing WSL/Ubuntu and Codex CLI inside WSL."
        return
    }

    $wslExe = Join-Path $env:WINDIR "System32\wsl.exe"
    if (-not (Test-Path -LiteralPath $wslExe)) {
        $wslExe = "wsl.exe"
    }

    $exitCode = Invoke-External -FilePath "dism.exe" -Arguments "/online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart" -AllowedExitCodes @(0, 3010)
    if ($exitCode -eq 3010) {
        $script:NeedsReboot = $true
    }

    $exitCode = Invoke-External -FilePath "dism.exe" -Arguments "/online /enable-feature /featurename:VirtualMachinePlatform /all /norestart" -AllowedExitCodes @(0, 3010)
    if ($exitCode -eq 3010) {
        $script:NeedsReboot = $true
    }

    try {
        Invoke-NativeCommand -FilePath $wslExe -Arguments @("--update", "--web-download") -AllowedExitCodes @(0) | Out-Null
    } catch {
        Write-WarnLine "wsl --update --web-download failed, retrying without --web-download."
        try {
            Invoke-NativeCommand -FilePath $wslExe -Arguments @("--update") -AllowedExitCodes @(0) | Out-Null
        } catch {
            Write-WarnLine "wsl --update failed: $($_.Exception.Message)"
        }
    }

    try {
        Invoke-NativeCommand -FilePath $wslExe -Arguments @("--set-default-version", "2") -AllowedExitCodes @(0) | Out-Null
    } catch {
        Write-WarnLine "Could not set WSL default version to 2 yet: $($_.Exception.Message)"
    }

    if ($script:NeedsReboot) {
        Write-WarnLine "WSL features were enabled and a reboot may be required before distro installation."
        return
    }

    $distros = Get-WslDistroNames -WslPath $wslExe

    if ($distros -contains $WslDistro) {
        Write-Ok "WSL distro is installed: $WslDistro"
    } else {
        Write-Info "Installing WSL distro: $WslDistro"
        try {
            Invoke-NativeCommand -FilePath $wslExe -Arguments @("--install", "--web-download", "-d", $WslDistro, "--no-launch") -AllowedExitCodes @(0) | Out-Null
        } catch {
            Write-WarnLine "wsl --install --web-download failed, retrying normal WSL install."
            Invoke-NativeCommand -FilePath $wslExe -Arguments @("--install", "-d", $WslDistro, "--no-launch") -AllowedExitCodes @(0) | Out-Null
        }
        $script:WslDistroInstalledThisRun = $true
        Add-DeferredAction "Launch $WslDistro once, create the Linux user, then rerun this script to install Codex CLI inside WSL."
        Write-Ok "WSL distro install command completed. First launch may still ask for a Linux username."
    }
}

function Install-CodexCliInWsl {
    $support = Get-WindowsSupportInfo
    if (-not $support.SupportsWslOneCommand) {
        Write-WarnLine "Codex-in-WSL install skipped: Windows 10 2004/build 19041 or newer is required for this scripted WSL setup."
        return
    }

    $wslExe = Join-Path $env:WINDIR "System32\wsl.exe"
    if (-not (Test-Path -LiteralPath $wslExe)) {
        $wslExe = "wsl.exe"
    }

    if ($script:NeedsReboot) {
        Write-WarnLine "Skipping Codex-in-WSL install until after reboot."
        return
    }

    if ($script:WslDistroInstalledThisRun) {
        Write-WarnLine "Skipping Codex-in-WSL because $WslDistro was installed in this run and still needs first-launch user creation."
        return
    }

    $distros = Get-WslDistroNames -WslPath $wslExe
    if ($distros -notcontains $WslDistro) {
        Write-WarnLine "WSL distro '$WslDistro' is not installed yet. Install/initialize it, then rerun this script."
        Add-DeferredAction "Install and launch $WslDistro once, then rerun this script to install Codex CLI inside WSL."
        return
    }

    if (-not (Test-WslDistroInitialized -WslPath $wslExe -DistroName $WslDistro)) {
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

    $pwshCmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($null -ne $pwshCmd) {
        $pwshVersion = Get-CommandVersion -CommandName "pwsh.exe" -Arguments @("-NoLogo", "-NoProfile", "-Command", '$PSVersionTable.PSVersion.ToString()')
        Write-Info "pwsh on PATH: $($pwshCmd.Source) $pwshVersion"
    } else {
        Write-Info "pwsh on PATH: not found"
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
        $line = "{0}: {1}" -f $result.Status, $result.Name
        if (-not [string]::IsNullOrWhiteSpace($result.Detail)) {
            $line = "$line - $($result.Detail)"
        }

        if ($result.Status -eq "FAILED") {
            Write-FailLine $line
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
