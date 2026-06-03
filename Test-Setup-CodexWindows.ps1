[CmdletBinding()]
param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot "Setup-CodexWindows.ps1")
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)][string]$Haystack,
        [Parameter(Mandatory = $true)][string]$Needle,
        [Parameter(Mandatory = $true)][string]$Message
    )

    Assert-True -Condition ($Haystack.Contains($Needle)) -Message $Message
}

function Assert-NotContains {
    param(
        [Parameter(Mandatory = $true)][string]$Haystack,
        [Parameter(Mandatory = $true)][string]$Needle,
        [Parameter(Mandatory = $true)][string]$Message
    )

    Assert-True -Condition (-not $Haystack.Contains($Needle)) -Message $Message
}

function Assert-NoQuestionMarkVariableInterpolation {
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.Language.Ast]$Ast,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $badVariables = @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $node.VariablePath.UserPath -match '^[A-Za-z_][A-Za-z0-9_]*\?$'
    }, $true))

    if ($badVariables.Count -gt 0) {
        $details = ($badVariables | ForEach-Object {
            "{0}:{1}: {2}" -f $Path, $_.Extent.StartLineNumber, $_.Extent.Text
        }) -join "; "
        throw "Suspicious PowerShell interpolation before '?'. Use `${name}` or -f formatting. $details"
    }
}

$resolvedScript = Resolve-Path -LiteralPath $ScriptPath
$content = Get-Content -LiteralPath $resolvedScript -Raw
$bootstrapScript = Join-Path (Split-Path -Parent $resolvedScript) "i.ps1"
$bootstrapContent = Get-Content -LiteralPath $bootstrapScript -Raw
$desktopBootstrapScript = Join-Path (Split-Path -Parent $resolvedScript) "d.ps1"
$desktopBootstrapContent = Get-Content -LiteralPath $desktopBootstrapScript -Raw
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($resolvedScript, [ref]$tokens, [ref]$errors)
$bootstrapTokens = $null
$bootstrapErrors = $null
$bootstrapAst = [System.Management.Automation.Language.Parser]::ParseFile($bootstrapScript, [ref]$bootstrapTokens, [ref]$bootstrapErrors)
$desktopBootstrapTokens = $null
$desktopBootstrapErrors = $null
$desktopBootstrapAst = [System.Management.Automation.Language.Parser]::ParseFile($desktopBootstrapScript, [ref]$desktopBootstrapTokens, [ref]$desktopBootstrapErrors)

Assert-True -Condition ($errors.Count -eq 0) -Message ("PowerShell parser errors: " + (($errors | ForEach-Object { $_.Message }) -join "; "))
Assert-True -Condition ($bootstrapErrors.Count -eq 0) -Message ("Bootstrap parser errors: " + (($bootstrapErrors | ForEach-Object { $_.Message }) -join "; "))
Assert-True -Condition ($desktopBootstrapErrors.Count -eq 0) -Message ("Desktop bootstrap parser errors: " + (($desktopBootstrapErrors | ForEach-Object { $_.Message }) -join "; "))
Assert-NoQuestionMarkVariableInterpolation -Ast $ast -Path $resolvedScript
Assert-NoQuestionMarkVariableInterpolation -Ast $bootstrapAst -Path $bootstrapScript
Assert-NoQuestionMarkVariableInterpolation -Ast $desktopBootstrapAst -Path $desktopBootstrapScript

$paramBlock = $ast.ParamBlock
Assert-True -Condition ($null -ne $paramBlock) -Message "Script must define a parameter block."
$paramNames = @($paramBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
$functionNames = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })

foreach ($requiredParam in @(
    "RepairStorePolicies",
    "SkipVcRedist",
    "SkipWindowsSupportCheck",
    "UpdateAllWingetPackages",
    "RunWindowsUpdate",
    "SkipCodexCliInWsl",
    "WslUser"
)) {
    Assert-True -Condition ($paramNames -contains $requiredParam) -Message "Missing parameter: $requiredParam"
}

foreach ($requiredFunction in @(
    "Get-WindowsSupportInfo",
    "Assert-WindowsSupport",
    "Get-SafeTempPath",
    "Get-PwshCommand",
    "Install-VcRedist",
    "Get-CodexCommand",
    "Get-CodexCommandVersion",
    "Get-CodexDesktopPackageText",
    "Invoke-CodexDesktopWingetInstall",
    "Invoke-CodexDesktopStoreInstaller",
    "Invoke-WithRetry",
    "Get-WingetReleaseAsset",
    "Get-AppInstallerDependencyArchitecture",
    "Assert-AppInstallerDependencyPackage",
    "Get-AppInstallerDependencyPathsFromRelease",
    "Install-CodexDesktopDirectMsix",
    "Resolve-CodexDesktopMicrosoftStoreMsix",
    "Enable-AppxTrustedPackageInstall",
    "Invoke-MicrosoftStoreSoap",
    "Get-CodexDesktopStoreUpdateManifest",
    "Wait-CodexDesktopPackage",
    "Assert-AuthenticodeSignature",
    "Assert-CodexDesktopMsixPackage",
    "Get-MsixManifestInfo",
    "Get-ArchiveEntryText",
    "Join-CommandArguments",
    "Write-CodexDesktopOfficialPathDiagnostics",
    "Get-RegistryDwordValue",
    "Set-RegistryDwordValue",
    "Repair-WingetSources",
    "Get-WindowsOptionalFeatureState",
    "Test-WindowsOptionalFeatureEnabled",
    "Test-WindowsRebootPending",
    "Get-SetupAutoResumeScriptPath",
    "Clear-SetupAutoResume",
    "Enable-SetupAutoResume",
    "Get-WslDistroNames",
    "Test-WslEngineAvailable",
    "Test-WslDistroInitialized",
    "Import-UbuntuWslRootfs",
    "Initialize-ImportedWslDistro",
    "Expand-GZipFile",
    "Reset-WslImportInstallDirectory",
    "Invoke-WslDiagnosticCommand",
    "Write-WslDiagnostics",
    "Invoke-WslImportAttempt",
    "Get-UbuntuWslRootfsUrl",
    "Get-WslImportInstallDirectory",
    "Get-WslKernelUpdateMsiUrl",
    "Install-WslKernelUpdatePackage",
    "Test-Wsl2VirtualizationAvailable",
    "Quote-BashString",
    "Set-ComponentWarning",
    "Add-DeferredAction",
    "Remove-DeferredAction"
)) {
    Assert-True -Condition ($functionNames -contains $requiredFunction) -Message "Missing function: $requiredFunction"
}

Assert-Contains -Haystack $content -Needle '$env:APPDATA "npm"' -Message "npm fallback must add APPDATA npm path."
Assert-Contains -Haystack $content -Needle 'VCRUNTIME140_1.dll' -Message "VC++ redistributable context must mention VCRUNTIME140_1.dll."
Assert-Contains -Haystack $content -Needle '$script:WslDistroInstalledThisRun' -Message "WSL flow must track distro installation in the current run."
Assert-Contains -Haystack $content -Needle 'winget source reset --force' -Message "winget source repair must reset sources."
Assert-Contains -Haystack $content -Needle 'Windows 10 2004' -Message "WSL support check must explain Windows 10 2004/build 19041 requirement."
Assert-Contains -Haystack $content -Needle '$RepairStorePolicies' -Message "Store policy writes must be gated by RepairStorePolicies."
Assert-Contains -Haystack $content -Needle 'Reboot Windows, then rerun this script to finish WSL distro setup and Codex CLI inside WSL.' -Message "WSL feature enable must add a clear reboot follow-up."
Assert-Contains -Haystack $content -Needle 'Join-CommandArguments @("-d", $DistroName, "-u", "root", "--", "sh", "-lc", "exit 0")' -Message "WSL initialization probe must quote arguments reliably on Windows PowerShell 5.1."
Assert-Contains -Haystack $content -Needle '$script:BootstrapOriginalBoundParameters = @{}' -Message "Bootstrap relaunch must capture script-level bound parameters."
Assert-Contains -Haystack $content -Needle '$script:BootstrapOriginalBoundParameters.GetEnumerator()' -Message "Bootstrap relaunch must not use the helper function's own parameters as script arguments."
Assert-NotContains -Haystack $content -Needle 'foreach ($entry in $PSBoundParameters.GetEnumerator()) {
        $parameters[$entry.Key] = $entry.Value
    }' -Message "Bootstrap relaunch must not pass internal helper parameters such as ScriptPath or ForceSwitches to the setup script."
Assert-Contains -Haystack $content -Needle '$script:SetupTempPath = Get-SafeTempPath' -Message "Setup must tolerate missing TEMP by using a safe temp path helper."
Assert-Contains -Haystack $content -Needle 'if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA))' -Message "LOCALAPPDATA-dependent paths must be guarded for service/minimal environments."
Assert-Contains -Haystack $content -Needle 'Invoke-WithRetry -Description "Download $Uri"' -Message "Downloads must retry transient network/CDN failures."
Assert-Contains -Haystack $content -Needle 'Invoke-WithRetry -Description "$Method $Uri"' -Message "HTTP text requests must retry transient network/CDN failures."
Assert-Contains -Haystack $content -Needle 'Invoke-WithRetry -Description "GET $Uri"' -Message "REST JSON requests must retry transient network/CDN failures."
Assert-Contains -Haystack $content -Needle 'https://github.com/openai/codex/releases/latest/download/install.ps1' -Message "Windows Codex CLI install must use the official GitHub release installer directly."
Assert-Contains -Haystack $content -Needle 'https://github.com/openai/codex/releases/latest/download/install.sh' -Message "WSL Codex CLI install must use the official GitHub release installer directly."
Assert-NotContains -Haystack $content -Needle 'https://chatgpt.com/codex/install.ps1' -Message "Windows Codex CLI install must not depend on chatgpt.com redirects that can return 403."
Assert-NotContains -Haystack $content -Needle 'https://chatgpt.com/codex/install.sh' -Message "WSL Codex CLI install must not depend on chatgpt.com redirects that can return 403."
Assert-Contains -Haystack $content -Needle 'DesktopAppInstaller_Dependencies.zip' -Message "winget repair must download official Desktop App Installer dependency packages."
Assert-Contains -Haystack $content -Needle 'DesktopAppInstaller_Dependencies.txt' -Message "winget repair must verify the dependency zip hash from the official release asset."
Assert-Contains -Haystack $content -Needle 'Microsoft.VCLibs.140.00_*.appx' -Message "winget repair must provide Microsoft.VCLibs.140.00 to Add-AppxPackage."
Assert-Contains -Haystack $content -Needle 'Microsoft.VCLibs.140.00.UWPDesktop_*.appx' -Message "winget repair must provide Microsoft.VCLibs UWPDesktop to Add-AppxPackage."
Assert-Contains -Haystack $content -Needle 'Microsoft.WindowsAppRuntime.*.appx' -Message "winget repair must provide Windows App Runtime to Add-AppxPackage."
Assert-Contains -Haystack $content -Needle 'Add-AppxPackage -Path $(Quote-PSString $bundlePath) -DependencyPath `$dependencyPaths' -Message "App Installer repair must pass dependency packages to Add-AppxPackage."
Assert-Contains -Haystack $content -Needle 'Assert-AuthenticodeSignature -Path $bundlePath -ExpectedSubjectPattern "Microsoft Corporation"' -Message "App Installer msixbundle must be Authenticode verified before install."
Assert-Contains -Haystack $content -Needle 'Store/App Installer repair left packages missing' -Message "Store repair must warn when register-by-family did not actually restore packages."
Assert-Contains -Haystack $content -Needle 'cloud-images.ubuntu.com/wsl/releases/noble/current' -Message "WSL fallback must use official Ubuntu WSL rootfs images."
Assert-Contains -Haystack $content -Needle 'wsl --import' -Message "WSL fallback must import rootfs without Microsoft Store."
Assert-Contains -Haystack $content -Needle 'wslstorestorage.blob.core.windows.net/wslblob/wsl_update_x64.msi' -Message "WSL setup must fall back to the official WSL2 kernel update MSI."
Assert-Contains -Haystack $content -Needle 'WSL kernel update MSI signature is not valid or not signed by Microsoft' -Message "WSL kernel update MSI must be Authenticode-verified."
Assert-Contains -Haystack $content -Needle 'Install-WslKernelUpdatePackage' -Message "WSL setup must install the kernel package when wsl --update fails."
Assert-Contains -Haystack $content -Needle 'SecondLevelAddressTranslationExtensions' -Message "WSL setup must inspect SLAT availability before forcing WSL2."
Assert-Contains -Haystack $content -Needle 'VirtualizationFirmwareEnabled' -Message "WSL setup must inspect firmware/nested virtualization before forcing WSL2."
Assert-Contains -Haystack $content -Needle 'WSL2 virtualization prerequisites are unavailable; using WSL1.' -Message "WSL setup must gracefully fall back to WSL1 on VPS hosts without nested virtualization."
Assert-Contains -Haystack $content -Needle '-SkipWsl2:(-not $wsl2VirtualizationAvailable)' -Message "WSL rootfs import must skip WSL2 attempts when virtualization is unavailable."
Assert-Contains -Haystack $content -Needle '"compressed rootfs and WSL 1"' -Message "WSL rootfs import must include an explicit WSL1 fallback."
Assert-Contains -Haystack $content -Needle '"decompressed tar rootfs and WSL 1"' -Message "Legacy WSL rootfs import must include an explicit WSL1 fallback."
Assert-Contains -Haystack $content -Needle '$arguments += @("--version", [string]$WslVersion)' -Message "WSL rootfs import must pass explicit WSL versions when requested."
Assert-Contains -Haystack $content -Needle 'Decompressing Ubuntu rootfs for legacy WSL import.' -Message "WSL fallback must decompress gzip rootfs for legacy import support."
Assert-Contains -Haystack $content -Needle 'ubuntu-wsl.rootfs.tar' -Message "WSL fallback must retry import with a plain tar rootfs."
Assert-Contains -Haystack $content -Needle 'This is a large download and may take several minutes on slow connections.' -Message "WSL rootfs download must explain long silent waits."
Assert-Contains -Haystack $content -Needle 'Downloaded Ubuntu WSL rootfs is unexpectedly small' -Message "WSL rootfs download must reject proxy/firewall error pages."
Assert-Contains -Haystack $content -Needle 'Windows has a pending reboot; WSL setup will continue after reboot.' -Message "WSL flow must detect pending reboots before import attempts."
Assert-Contains -Haystack $content -Needle 'Test-WslEngineAvailable' -Message "Pending reboot handling must not block WSL if the engine is already responding."
Assert-Contains -Haystack $content -Needle '$script:AutoResumeTaskName = "Codex Windows Setup Resume"' -Message "Setup must define a stable auto-resume task name."
Assert-Contains -Haystack $content -Needle 'Register-ScheduledTask' -Message "Setup must register an elevated logon task for automatic post-reboot continuation."
Assert-Contains -Haystack $content -Needle 'New-ScheduledTaskPrincipal' -Message "Auto-resume task must be registered with an explicit principal."
Assert-Contains -Haystack $content -Needle 'RunLevel Highest' -Message "Auto-resume task must run elevated."
Assert-Contains -Haystack $content -Needle 'Setup auto-resume' -Message "Final flow must include setup auto-resume as a component."
Assert-Contains -Haystack $content -Needle '$SkipAutoResume' -Message "Auto-resume must be disableable."
Assert-Contains -Haystack $content -Needle 'Remove-DeferredAction "Reboot Windows, then rerun this script to finish WSL distro setup and Codex CLI inside WSL."' -Message "Successful auto-resume must suppress the manual rerun follow-up."
Assert-Contains -Haystack $content -Needle 'WSL diagnostics:' -Message "WSL failures must log diagnostic context."
Assert-Contains -Haystack $content -Needle '$script:WslDistroImportedThisRun' -Message "WSL flow must track imported distro setup."
Assert-Contains -Haystack $content -Needle 'default=%s' -Message "Imported WSL distro must set a default Linux user."
Assert-Contains -Haystack $content -Needle 'Windows Server detected. Using Store-free Ubuntu rootfs import' -Message "Windows Server must avoid interactive Store-backed WSL distro install."
Assert-Contains -Haystack $content -Needle 'ProgramFiles "PowerShell"' -Message "pwsh detection must search Program Files, not only PATH."
Assert-Contains -Haystack $content -Needle 'https://get.microsoft.com/installer/download' -Message "Codex Desktop fallback must use the official Microsoft Store web installer."
Assert-Contains -Haystack $content -Needle '--silent' -Message "Official Store installer fallback must run in silent mode."
Assert-Contains -Haystack $content -Needle '--allusers' -Message "Official Store installer fallback must try all-users silent mode where Store UI is missing."
Assert-Contains -Haystack $content -Needle 'Microsoft Corporation' -Message "Official Store installer fallback must verify Microsoft Authenticode signer."
Assert-Contains -Haystack $content -Needle 'CanTryStoreInstaller' -Message "Windows support info must model the official Store web installer path."
Assert-Contains -Haystack $content -Needle 'DoNotConnectToWindowsUpdateInternetLocations' -Message "Desktop install diagnostics must report Windows Update policy blockers."
Assert-Contains -Haystack $content -Needle 'installer returned but OpenAI.Codex AppX package was not registered' -Message "Desktop install must fail clearly when Store installer redirects instead of installing."
Assert-Contains -Haystack $content -Needle 'windows-store-update.json' -Message "Direct MSIX fallback must read the OpenAI Windows Store update manifest."
Assert-Contains -Haystack $content -Needle 'displaycatalog.mp.microsoft.com' -Message "Direct MSIX fallback must resolve the package through Microsoft Store metadata."
Assert-Contains -Haystack $content -Needle 'fe3.delivery.mp.microsoft.com' -Message "Direct MSIX fallback must resolve a Microsoft CDN URL through FE3."
Assert-Contains -Haystack $content -Needle 'Add-AppxPackage -Path' -Message "Direct MSIX fallback must install with Add-AppxPackage."
Assert-Contains -Haystack $content -Needle 'AllowAllTrustedApps' -Message "Direct MSIX fallback must enable trusted MSIX sideloading when needed."
Assert-Contains -Haystack $content -Needle 'MSIX publisher does not match signer' -Message "Direct MSIX fallback must validate manifest publisher against the signer certificate."
Assert-Contains -Haystack $content -Needle 'Unexpected MSIX package identity' -Message "Direct MSIX fallback must validate OpenAI.Codex package identity."
Assert-Contains -Haystack $content -Needle 'Skipping Microsoft Store web installer on this Server build' -Message "Server builds without winget must not open the Store web installer loop."
Assert-Contains -Haystack $content -Needle 'Codex Desktop is installed; winget Store upgrade was not applied:' -Message "Installed Codex Desktop should treat winget Store upgrade misses as non-blocking diagnostics."
Assert-Contains -Haystack $content -Needle 'WSL distro install did not complete automatically' -Message "WSL distro install failures should become follow-up actions instead of failing the whole component."
Assert-Contains -Haystack $content -Needle 'Status "WARN"' -Message "Final summary must support warning component results."
Assert-Contains -Haystack $content -Needle 'Write-WarnLine $line' -Message "Final summary must render warning component results as warnings."
Assert-Contains -Haystack $content -Needle 'Write-Ok $line' -Message "Final summary must avoid duplicated OK prefixes."
Assert-Contains -Haystack $bootstrapContent -Needle 'Latest setup log:' -Message "Bootstrap launcher must show the latest setup log path on failure."
Assert-Contains -Haystack $bootstrapContent -Needle 'Get-Content -LiteralPath $latestLog.FullName -Tail 120' -Message "Bootstrap launcher must show useful log tail on failure."
Assert-Contains -Haystack $bootstrapContent -Needle '$cacheBust = [Guid]::NewGuid().ToString("N")' -Message "Bootstrap cache-busting must work on old Windows PowerShell/.NET builds."
Assert-Contains -Haystack $bootstrapContent -Needle '$setupVersion = "' -Message "Bootstrap must pin the setup download to a tested immutable commit."
Assert-Contains -Haystack $bootstrapContent -Needle 'raw.githubusercontent.com/OlegGorsky/w/$setupVersion/Setup-CodexWindows.ps1' -Message "Bootstrap must download setup from an immutable raw commit URL."
Assert-Contains -Haystack $bootstrapContent -Needle '-RepairStorePolicies' -Message "Short web bootstrap must repair Store policies by default for stripped Windows images."
Assert-Contains -Haystack $bootstrapContent -Needle '$setupRequestUrl = "{0}?cb={1}" -f $setupUrl, $cacheBust' -Message "Bootstrap cache-bust URL must avoid PowerShell variable-name ambiguity before ?."
Assert-Contains -Haystack $bootstrapContent -Needle 'Invoke-WebRequest -Uri $setupRequestUrl' -Message "Bootstrap must download using the safely formatted cache-bust URL."
Assert-Contains -Haystack $desktopBootstrapContent -Needle 'raw.githubusercontent.com/OlegGorsky/ng/main/d.ps1' -Message "Desktop short bootstrap must delegate to the NeuroGate bootstrap source."
Assert-Contains -Haystack $desktopBootstrapContent -Needle '$requestUrl = "{0}?cb={1}" -f $bootstrapUrl, $cacheBust' -Message "Desktop bootstrap cache-bust URL must avoid PowerShell variable-name ambiguity before ?."
Assert-Contains -Haystack $desktopBootstrapContent -Needle 'Downloaded NeuroGate bootstrap looks like HTML' -Message "Desktop bootstrap must reject HTML error pages before execution."
Assert-Contains -Haystack $desktopBootstrapContent -Needle 'Test-BootstrapSyntax $bootstrap' -Message "Desktop bootstrap must parse-check the downloaded script before execution."
Assert-NotContains -Haystack $bootstrapContent -Needle '"$setupUrl?cb=$cacheBust"' -Message "Bootstrap must not interpolate a variable directly before ? in an expandable string."
Assert-NotContains -Haystack $bootstrapContent -Needle 'ToUnixTimeSeconds' -Message "Bootstrap must avoid newer DateTimeOffset APIs for old Windows PowerShell/.NET builds."
Assert-NotContains -Haystack $bootstrapContent -Needle 'raw/main' -Message "Bootstrap must avoid stale raw.githubusercontent.com main cache for setup download."
Assert-NotContains -Haystack $content -Needle '"OK: {0}"' -Message "Final summary must not build OK: OK lines."
Assert-NotContains -Haystack $content -Needle 'rerun with -InstallCodexInWsl' -Message "Deprecated WSL rerun hint must be removed."
Assert-NotContains -Haystack $content -Needle '-Type DWord' -Message "Set-ItemProperty must not use unsupported -Type DWord."
Assert-NotContains -Haystack $content -Needle 'Wangnov' -Message "Script must not use third-party Codex Desktop mirrors."
Assert-NotContains -Haystack $content -Needle 'winget upgrade did not complete cleanly' -Message "Installed Codex Desktop should not show scary winget upgrade warnings when the package is already present."

$bootstrapFunctionAsts = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        @("ConvertTo-BootstrapArgument", "New-BootstrapArgumentList") -contains $node.Name
}, $true)

foreach ($functionAst in $bootstrapFunctionAsts) {
    Invoke-Expression $functionAst.Extent.Text
}

$script:BootstrapOriginalBoundParameters = @{
    CheckOnly = [System.Management.Automation.SwitchParameter]::Present
    WslDistro = "Ubuntu Preview"
    WslUser = "codex"
}
$bootstrapArgumentList = New-BootstrapArgumentList -ScriptPath "C:\Temp\Setup-CodexWindows.ps1" -ForceSwitches @("NoAdminRelaunch", "NoHostRelaunch")
Assert-Contains -Haystack $bootstrapArgumentList -Needle '-CheckOnly' -Message "Bootstrap relaunch must preserve user script switches."
Assert-Contains -Haystack $bootstrapArgumentList -Needle '-WslDistro "Ubuntu Preview"' -Message "Bootstrap relaunch must preserve user string parameters."
Assert-Contains -Haystack $bootstrapArgumentList -Needle '-NoAdminRelaunch' -Message "Bootstrap relaunch must add forced switches."
Assert-Contains -Haystack $bootstrapArgumentList -Needle '-NoHostRelaunch' -Message "Bootstrap relaunch must add forced host switches."
Assert-NotContains -Haystack $bootstrapArgumentList -Needle '-ScriptPath' -Message "Bootstrap relaunch must not leak helper-only ScriptPath."
Assert-NotContains -Haystack $bootstrapArgumentList -Needle '-ForceSwitches' -Message "Bootstrap relaunch must not leak helper-only ForceSwitches."

$setupUrl = "https://example.invalid/Setup-CodexWindows.ps1"
$cacheBust = "abc123"
$setupRequestUrl = "{0}?cb={1}" -f $setupUrl, $cacheBust
Assert-True -Condition ($setupRequestUrl -eq "https://example.invalid/Setup-CodexWindows.ps1?cb=abc123") -Message "PowerShell cache-bust URL formatting must preserve the hostname."

Write-Host "All static setup checks passed."
