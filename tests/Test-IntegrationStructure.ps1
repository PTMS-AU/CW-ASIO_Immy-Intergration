<#
.SYNOPSIS
    Structural checks binding the integration script to the CWPlatformAPI module.

.DESCRIPTION
    Guards the failure that shipped in beta.1: helper functions were reachable at
    Init and HealthCheck but not inside later capability invocations, producing
    "The term 'Resolve-CwClientRef' is not recognized" on every sync.

    ImmyBot serialises each capability scriptblock independently, so a function
    defined at integration-script scope is not visible inside them. The shipped
    DattoRMM and NinjaRMM integrations solve this by calling Import-Module at the
    top of every block; so does this one. These checks enforce that contract.

    No Pester, no PSGallery — runs on Windows PowerShell 5.1 or pwsh 7.

.EXAMPLE
    pwsh -File tests/Test-IntegrationStructure.ps1
#>

[CmdletBinding()]
param(
    [string]$IntegrationScript = (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'integration') 'ConnectWiseRMM-Integration.ps1'),
    [string]$ModulePath        = (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'integration') 'CWPlatformAPI.psm1')
)

$ErrorActionPreference = 'Stop'

$script:Passed = 0
$script:Failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Because)
    if ($Condition) {
        $script:Passed++
        Write-Host "  PASS  $Because"
    } else {
        $script:Failed++
        Write-Host "  FAIL  $Because"
    }
}

$ModuleName = 'CWPlatformAPI'

foreach ($p in @($IntegrationScript, $ModulePath)) {
    $errs = $null
    [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$errs) | Out-Null
    if ($errs) { throw "$p does not parse: $($errs[0].Message) (line $($errs[0].Extent.StartLineNumber))" }
}

$ast       = [System.Management.Automation.Language.Parser]::ParseFile($IntegrationScript, [ref]$null, [ref]$null)
$moduleAst = [System.Management.Automation.Language.Parser]::ParseFile($ModulePath, [ref]$null, [ref]$null)
$rawScript = Get-Content -LiteralPath $IntegrationScript -Raw
$rawModule = Get-Content -LiteralPath $ModulePath -Raw

Write-Host "Integration: $IntegrationScript"
Write-Host "Module:      $ModulePath"

# --- module surface ---------------------------------------------------
$moduleFunctions = @($moduleAst.FindAll({
    param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true) | ForEach-Object { $_.Name })

$exported = @()
if ($rawModule -match '(?s)Export-ModuleMember\s+-Function\s+@\((.*?)\)') {
    $exported = @([regex]::Matches($Matches[1], "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
}

Write-Host "`nModule surface"
Write-Host "  defines $($moduleFunctions.Count), exports $($exported.Count)"

$exportedButMissing = @($exported | Where-Object { $moduleFunctions -notcontains $_ })
Assert-True -Condition ($exportedButMissing.Count -eq 0) `
    -Because "every exported name is actually defined$(if ($exportedButMissing.Count) { " — MISSING: $($exportedButMissing -join ', ')" })"

# --- every capability block imports the module ------------------------
$capabilityBlocks = $ast.FindAll({
    param($n) $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst]
}, $true) | Where-Object {
    $p = $_.Parent
    $p -is [System.Management.Automation.Language.CommandAst] -and "$($p.GetCommandName())" -match 'DynamicIntegration'
}

Write-Host "`nCapability blocks ($($capabilityBlocks.Count) found)"
Assert-True -Condition ($capabilityBlocks.Count -ge 6) -Because "at least 6 capability blocks are present"

$allCalled = @()

foreach ($block in $capabilityBlocks) {
    $line = $block.Extent.StartLineNumber

    $commands = @($block.FindAll({
        param($n) $n -is [System.Management.Automation.Language.CommandAst]
    }, $true))

    $called = @($commands | ForEach-Object { $_.GetCommandName() } |
        Where-Object { $_ -and $_ -match '-Cw' } | Sort-Object -Unique)

    if ($called.Count -eq 0) { continue }
    $allCalled += $called

    $imports = @($commands | Where-Object {
        "$($_.GetCommandName())" -eq 'Import-Module' -and "$($_.Extent.Text)" -match [regex]::Escape($ModuleName)
    })

    Assert-True -Condition ($imports.Count -ge 1) `
        -Because "block at line $line calls $($called.Count) module function(s) and imports $ModuleName"
}

# --- the script only calls what the module exports --------------------
Write-Host "`nScript/module contract"
$allCalled = @($allCalled | Sort-Object -Unique)
$notExported = @($allCalled | Where-Object { $exported -notcontains $_ })

Assert-True -Condition ($notExported.Count -eq 0) `
    -Because "all $($allCalled.Count) module function(s) the script calls are exported$(if ($notExported.Count) { " — NOT EXPORTED: $($notExported -join ', ')" })"

# --- no capability defines its own helpers ----------------------------
$localCwDefs = @($ast.FindAll({
    param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true) | Where-Object { $_.Name -match '-Cw' } | ForEach-Object { $_.Name })

Assert-True -Condition ($localCwDefs.Count -eq 0) `
    -Because "the integration script defines no helpers of its own — they belong in the module$(if ($localCwDefs.Count) { " — FOUND: $($localCwDefs -join ', ')" })"

# --- regression guards ------------------------------------------------
Write-Host "`nRegression guards"

Assert-True -Condition ($rawScript -notmatch 'scriptblock\]::Create') `
    -Because "no [scriptblock]::Create — ImmyBot's runspace does not permit it (this is what broke beta.1)"

Assert-True -Condition ($rawScript -match 'HandleHttpRequest') `
    -Because "webhook uses -HandleHttpRequest, the real ImmyBot parameter name"

Assert-True -Condition ($rawScript -notmatch 'HttpRequestHandler') `
    -Because "the guessed -HttpRequestHandler name is gone"

Assert-True -Condition ($rawModule -match "HeartbeatResourceType\s*=\s*'companies'") `
    -Because "heartbeat resourceType is 'companies' (endpoints=403, clients=400)"

Assert-True -Condition (($rawScript + $rawModule) -notmatch 'resourceType=endpoints') `
    -Because "nothing requests resourceType=endpoints, which is forbidden on this key"

Assert-True -Condition ($rawScript -match 'Import-Module CWPlatformAPI') `
    -Because "the module name is spelled consistently"

Write-Host ""
Write-Host "$($script:Passed) passed, $($script:Failed) failed."
if ($script:Failed -gt 0) { exit 1 }
exit 0
