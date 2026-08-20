<#
.SYNOPSIS
    Dependency-free tests for the ConnectWise Platform integration helpers.

.DESCRIPTION
    Tests integration/CWPlatformAPI.psm1 — the module every capability block
    imports.

    Structural checks on the integration script (that each block imports the
    module, and that the module exports what the script calls) live in
    Test-IntegrationStructure.ps1.

    No Pester, no PSGallery — runs on Windows PowerShell 5.1 or pwsh 7.

.EXAMPLE
    pwsh -File tests/Test-CwHelpers.ps1

.EXAMPLE
    powershell -File tests\Test-CwHelpers.ps1   # Windows PowerShell 5.1
#>

[CmdletBinding()]
param(
    # Built with two-argument Join-Path calls so this runs on Windows
    # PowerShell 5.1 as well as pwsh 7 — the three-argument form is 7-only.
    [string]$ModulePath = (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'integration') 'CWPlatformAPI.psm1')
)

$ErrorActionPreference = 'Stop'

$script:Passed = 0
$script:Failed = 0

function Assert-Equal {
    param($Expected, $Actual, [string]$Because)

    $e = if ($null -eq $Expected) { '<null>' } else { "$Expected" }
    $a = if ($null -eq $Actual)   { '<null>' } else { "$Actual" }

    if ($e -ceq $a) {
        $script:Passed++
        Write-Host "  PASS  $Because"
    } else {
        $script:Failed++
        Write-Host "  FAIL  $Because"
        Write-Host "          expected: $e"
        Write-Host "          actual:   $a"
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Because)
    Assert-Equal -Expected 'True' -Actual "$Condition" -Because $Because
}

# ---------------------------------------------------------------------
# Load
# ---------------------------------------------------------------------
Write-Host "Loading $ModulePath"

$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($ModulePath, [ref]$null, [ref]$parseErrors) | Out-Null
if ($parseErrors) {
    throw "Module does not parse: $($parseErrors[0].Message) (line $($parseErrors[0].Extent.StartLineNumber))"
}

# Must be global: a module has its own scope and resolves $IntegrationContext
# from global, exactly as it does inside ImmyBot.
$global:IntegrationContext = [pscustomobject]@{
    ApiEndpoint  = 'https://openapi.service.auplatform.connectwise.com'
    ClientId     = 'test-client'
    ClientSecret = 'test-secret'
    TokenCache   = @{}
}

Import-Module $ModulePath -Force

Write-Host "`nGet-CwConfig"
Assert-Equal -Expected 'companies' -Actual (Get-CwConfig -Name 'HeartbeatResourceType') -Because 'reads the heartbeat resource type'
Assert-Equal -Expected '4'         -Actual (Get-CwConfig -Name 'ClientBatchSize')       -Because 'reads a numeric value'
Assert-Equal -Expected 'fallback'  -Actual (Get-CwConfig -Name 'NoSuchKey' -Default 'fallback') -Because 'returns the default for a missing key'
Assert-Equal -Expected ''          -Actual (Get-CwConfig -Name 'PreferredSiteName' -Default 'x') -Because 'an empty string is a real value, not a miss'
Assert-Equal -Expected 'True'      -Actual "$(Get-CwConfig -Name 'FailSyncOnPartialResults')" -Because 'partial syncs fail loudly by default'
Assert-Equal -Expected 'False'     -Actual "$(Get-CwConfig -Name 'SiteLevelClients')"    -Because 'site-level mapping is off by default'

# Config must not depend on $IntegrationContext at all — that dependency is
# exactly what broke the first beta in situ.
$savedContext = $global:IntegrationContext
$global:IntegrationContext = $null
Assert-Equal -Expected 'companies' -Actual (Get-CwConfig -Name 'HeartbeatResourceType') -Because 'config still resolves with no IntegrationContext present'
$global:IntegrationContext = $savedContext

Write-Host "`nGet-CwScope"
Assert-Equal -Expected 'False' -Actual "$((Get-CwScope) -match 'automation')" -Because 'the read scope carries no automation scopes'
Assert-Equal -Expected 'True'  -Actual "$((Get-CwScope -IncludeWrite) -match 'platform\.automation\.create')" -Because 'the write scope adds automation.create for RunScript'
Assert-Equal -Expected 'True'  -Actual "$((Get-CwScope -IncludeWrite).StartsWith((Get-CwScope)))" -Because 'the write scope is the read scope plus additions, not a separate list'

Write-Host "`nResolve-CwClientRef"
$company = Resolve-CwClientRef -ClientRef 'aaaaaaaa-1111-2222-3333-444444444444'
Assert-Equal -Expected 'aaaaaaaa-1111-2222-3333-444444444444' -Actual $company.CompanyId -Because 'bare GUID parses as a company id'
Assert-Equal -Expected $null -Actual $company.SiteId -Because 'bare GUID has no site id'

$site = Resolve-CwClientRef -ClientRef 'aaaaaaaa-1111-2222-3333-444444444444|bbbbbbbb-5555-6666-7777-888888888888'
Assert-Equal -Expected 'aaaaaaaa-1111-2222-3333-444444444444' -Actual $site.CompanyId -Because 'composite ref yields the company id'
Assert-Equal -Expected 'bbbbbbbb-5555-6666-7777-888888888888' -Actual $site.SiteId -Because 'composite ref yields the site id'
Assert-Equal -Expected 'aaaaaaaa-1111-2222-3333-444444444444|bbbbbbbb-5555-6666-7777-888888888888' -Actual $site.Raw -Because 'Raw round-trips for emit'
Assert-Equal -Expected $null -Actual (Resolve-CwClientRef -ClientRef '') -Because 'empty ref is null, not a crash'
Assert-Equal -Expected $null -Actual (Resolve-CwClientRef -ClientRef 'company|').SiteId -Because 'trailing separator does not fabricate an empty site id'
Assert-Equal -Expected 'company' -Actual (Resolve-CwClientRef -ClientRef 'company|').CompanyId -Because 'trailing separator still yields the company id'

Write-Host "`nGet-CwNextLink"
Assert-Equal -Expected 'https://api/next?page=2' `
    -Actual (Get-CwNextLink -Headers @{ Link = '<https://api/next?page=2>; rel="next"' }) `
    -Because 'parses a quoted rel=next'
Assert-Equal -Expected 'https://api/next' `
    -Actual (Get-CwNextLink -Headers @{ Link = '<https://api/next>; rel=next' }) `
    -Because 'parses an unquoted rel=next'
Assert-Equal -Expected 'https://api/p2' `
    -Actual (Get-CwNextLink -Headers @{ Link = @('<https://api/p0>; rel="prev"', '<https://api/p2>; rel="next"') }) `
    -Because 'handles a multi-value Link header array'
Assert-Equal -Expected $null `
    -Actual (Get-CwNextLink -Headers @{ Link = '<https://api/last>; rel="prev"' }) `
    -Because 'no rel=next means no next page'
Assert-Equal -Expected $null -Actual (Get-CwNextLink -Headers @{}) -Because 'missing Link header is null'
Assert-Equal -Expected $null -Actual (Get-CwNextLink -Headers $null) -Because 'null headers is null, not a crash'

Write-Host "`nGet-CwBatch"
$b = Get-CwBatch -Items @('1','2','3','4','5','6','7','8','9') -Size 4
Assert-Equal -Expected 3 -Actual $b.Count -Because '9 items at size 4 makes 3 batches'
Assert-Equal -Expected 4 -Actual $b[0].Count -Because 'first batch is full'
Assert-Equal -Expected 1 -Actual $b[2].Count -Because 'last batch holds the remainder'

$exact = Get-CwBatch -Items @('1','2','3','4') -Size 4
Assert-Equal -Expected 1 -Actual $exact.Count -Because 'an exact multiple does not emit a trailing empty batch'

$single = Get-CwBatch -Items @('only') -Size 4
Assert-Equal -Expected 1 -Actual $single.Count -Because 'a single item still yields one batch'
Assert-Equal -Expected 1 -Actual $single[0].Count -Because 'and that batch is not unrolled to a bare string'

Assert-Equal -Expected 0 -Actual (Get-CwBatch -Items @() -Size 4).Count -Because 'no items means no batches'
Assert-Equal -Expected 1 -Actual (Get-CwBatch -Items @($null,'a',$null) -Size 4).Count -Because 'null entries are skipped'

Write-Host "`nGet-CwEndpointSiteId"
Assert-Equal -Expected 'site-1' -Actual (Get-CwEndpointSiteId -Endpoint ([pscustomobject]@{ siteID = 'site-1' }) -Group $null) -Because 'reads siteID'
Assert-Equal -Expected 'site-2' -Actual (Get-CwEndpointSiteId -Endpoint ([pscustomobject]@{ siteId = 'site-2' }) -Group $null) -Because 'reads siteId'
Assert-Equal -Expected 'site-3' -Actual (Get-CwEndpointSiteId -Endpoint ([pscustomobject]@{ site = [pscustomobject]@{ id = 'site-3' } }) -Group $null) -Because 'reads nested site.id'
Assert-Equal -Expected 'site-4' -Actual (Get-CwEndpointSiteId -Endpoint ([pscustomobject]@{}) -Group ([pscustomobject]@{ siteID = 'site-4' })) -Because 'falls back to the group wrapper'
Assert-Equal -Expected $null -Actual (Get-CwEndpointSiteId -Endpoint ([pscustomobject]@{}) -Group ([pscustomobject]@{})) -Because 'unresolvable site returns null so the caller can refuse to guess'

Write-Host "`nConnect-CwPlatformApi (cache behaviour, no network)"
# The token cache lives on $IntegrationContext, which is what makes it survive
# ACROSS capability invocations rather than only within one. Seed it directly:
# a cache miss here would try to reach the token endpoint and fail the run.
$readScope = Get-CwScope
$global:IntegrationContext.TokenCache = @{
    $readScope = @{ Token = 'cached-token'; Expires = (Get-Date).AddMinutes(30) }
}
Assert-Equal -Expected 'cached-token' -Actual (Connect-CwPlatformApi) -Because 'an unexpired cached token is reused'

$global:IntegrationContext.TokenCache[$readScope].Expires = (Get-Date).AddSeconds(-1)
$expired = $false
try { Connect-CwPlatformApi | Out-Null } catch { $expired = $true }
Assert-True -Condition $expired -Because 'an expired token is not served from cache (falls through to the network)'

# Read and write tokens are cached separately — a read token must never be
# handed to RunScript, which needs automation.create.
$global:IntegrationContext.TokenCache = @{
    (Get-CwScope)               = @{ Token = 'read-token';  Expires = (Get-Date).AddMinutes(30) }
    (Get-CwScope -IncludeWrite) = @{ Token = 'write-token'; Expires = (Get-Date).AddMinutes(30) }
}
Assert-Equal -Expected 'read-token'  -Actual (Connect-CwPlatformApi) -Because 'the read scope gets the read token'
Assert-Equal -Expected 'write-token' -Actual (Connect-CwPlatformApi -IncludeWrite) -Because 'the write scope gets its own token, not the read one'

$forced = $false
try { Connect-CwPlatformApi -Force | Out-Null } catch { $forced = $true }
Assert-True -Condition $forced -Because '-Force bypasses the cache even when a valid token is present'

$global:IntegrationContext = [pscustomobject]@{ ApiEndpoint = ''; ClientId = 'x'; ClientSecret = 'y'; TokenCache = @{} }
$noEndpoint = $false
try { Connect-CwPlatformApi | Out-Null } catch { $noEndpoint = $true }
Assert-True -Condition $noEndpoint -Because 'an empty ApiEndpoint throws a clear error instead of building a bogus URL'

Write-Host "`nGet-CwSiteCompanyId"
Assert-Equal -Expected 'c1' -Actual (Get-CwSiteCompanyId -Site ([pscustomobject]@{ company = [pscustomobject]@{ id = 'c1' } })) -Because 'reads nested company.id'
Assert-Equal -Expected 'c2' -Actual (Get-CwSiteCompanyId -Site ([pscustomobject]@{ companyID = 'c2' })) -Because 'reads companyID'
Assert-Equal -Expected 'c3' -Actual (Get-CwSiteCompanyId -Site ([pscustomobject]@{ clientID = 'c3' })) -Because 'reads clientID'
Assert-Equal -Expected $null -Actual (Get-CwSiteCompanyId -Site ([pscustomobject]@{})) -Because 'an unattributable site returns null rather than guessing'

# ---------------------------------------------------------------------
Write-Host ""
Write-Host "$($script:Passed) passed, $($script:Failed) failed."
if ($script:Failed -gt 0) { exit 1 }
exit 0
