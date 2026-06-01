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

$resolvedScript = Resolve-Path -LiteralPath $ScriptPath
$content = Get-Content -LiteralPath $resolvedScript -Raw
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($resolvedScript, [ref]$tokens, [ref]$errors)

Assert-True -Condition ($errors.Count -eq 0) -Message ("PowerShell parser errors: " + (($errors | ForEach-Object { $_.Message }) -join "; "))

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
    "Get-PwshCommand",
    "Install-VcRedist",
    "Get-CodexCommand",
    "Get-CodexCommandVersion",
    "Get-CodexDesktopPackageText",
    "Invoke-CodexDesktopWingetInstall",
    "Invoke-CodexDesktopStoreInstaller",
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
    "Get-WslDistroNames",
    "Test-WslDistroInitialized",
    "Import-UbuntuWslRootfs",
    "Initialize-ImportedWslDistro",
    "Get-UbuntuWslRootfsUrl",
    "Get-WslImportInstallDirectory",
    "Quote-BashString",
    "Add-DeferredAction"
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
Assert-Contains -Haystack $content -Needle 'cloud-images.ubuntu.com/wsl/releases/noble/current' -Message "WSL fallback must use official Ubuntu WSL rootfs images."
Assert-Contains -Haystack $content -Needle 'wsl --import' -Message "WSL fallback must import rootfs without Microsoft Store."
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
Assert-Contains -Haystack $content -Needle 'WSL distro install did not complete automatically' -Message "WSL distro install failures should become follow-up actions instead of failing the whole component."
Assert-Contains -Haystack $content -Needle 'Write-Ok $line' -Message "Final summary must avoid duplicated OK prefixes."
Assert-NotContains -Haystack $content -Needle '"OK: {0}"' -Message "Final summary must not build OK: OK lines."
Assert-NotContains -Haystack $content -Needle 'rerun with -InstallCodexInWsl' -Message "Deprecated WSL rerun hint must be removed."
Assert-NotContains -Haystack $content -Needle '-Type DWord' -Message "Set-ItemProperty must not use unsupported -Type DWord."
Assert-NotContains -Haystack $content -Needle 'Wangnov' -Message "Script must not use third-party Codex Desktop mirrors."

Write-Host "All static setup checks passed."
