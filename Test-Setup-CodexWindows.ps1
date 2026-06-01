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
    "SkipCodexCliInWsl"
)) {
    Assert-True -Condition ($paramNames -contains $requiredParam) -Message "Missing parameter: $requiredParam"
}

foreach ($requiredFunction in @(
    "Get-WindowsSupportInfo",
    "Assert-WindowsSupport",
    "Install-VcRedist",
    "Get-CodexCommand",
    "Get-CodexCommandVersion",
    "Repair-WingetSources",
    "Get-WslDistroNames",
    "Test-WslDistroInitialized",
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
Assert-NotContains -Haystack $content -Needle 'rerun with -InstallCodexInWsl' -Message "Deprecated WSL rerun hint must be removed."
Assert-NotContains -Haystack $content -Needle '-Type DWord' -Message "Set-ItemProperty must not use unsupported -Type DWord."

Write-Host "All static setup checks passed."
