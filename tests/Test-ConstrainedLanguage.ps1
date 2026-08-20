<#
.SYNOPSIS
    Fails the build on constructs ImmyBot's ConstrainedLanguage mode rejects.

.DESCRIPTION
    ImmyBot runs integration and capability script blocks in ConstrainedLanguage
    mode. Anything outside a small set of core types raises:

        Cannot invoke method. Method invocation is supported only on core types
        in this language mode.

    This has bitten twice:
      - beta.1 built a scriptblock at runtime to share helpers. Every sync failed
        with "The term 'Resolve-CwClientRef' is not recognized".
      - beta.2 used [Math]::Max / [Math]::Pow. Init failed outright.
      - beta.2 returned [pscustomobject]@{...} from Invoke-CwApi. Every API call
        failed with "Cannot convert value to type ...InternalPSCustomObject",
        and because the cast threw inside a try block it surfaced as a bogus
        "HTTP 0" and was retried four times.

    Both were invisible locally, because a normal pwsh runs in FullLanguage and
    happily executes them. Static analysis is the only way to catch this without
    a live ImmyBot, so it runs in CI.

    Uses the AST, so mentions inside comments and strings are correctly ignored.

    Scope: integration/ only. Files under software/ run in MetaScript and
    endpoint contexts, which are FullLanguage — alpha has shipped
    [IO.Path]::GetTempFileName there for as long as it has existed.

.EXAMPLE
    pwsh -File tests/Test-ConstrainedLanguage.ps1
#>

[CmdletBinding()]
param(
    [string]$Path = (Join-Path (Split-Path -Parent $PSScriptRoot) 'integration')
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

# Types whose static members are reachable in ConstrainedLanguage, plus the
# ImmyBot types the shipped integrations demonstrably use.
$AllowedStaticTypes = @(
    # alpha-proven in production
    'string', 'OpResult',
    # from ImmyBot's own Example - Inbound Webhook
    'ObjectResult',
    # documented ConstrainedLanguage core types
    'bool', 'byte', 'char', 'datetime', 'decimal', 'double', 'float', 'single',
    'guid', 'hashtable', 'int', 'int32', 'int64', 'long', 'regex', 'sbyte',
    'short', 'int16', 'timespan', 'uint16', 'uint32', 'uint64', 'version',
    'pscustomobject', 'psobject', 'array', 'xml'
)

# Instance methods we have been burned by or that sit on non-core types.
# Operators and cmdlets do the same jobs without the language-mode risk.
$BannedInstanceCalls = @{
    'AddSeconds'      = 'use (Get-Date) + (New-TimeSpan -Seconds n)'
    'AddMinutes'      = 'use (Get-Date) + (New-TimeSpan -Minutes n)'
    'ContainsKey'     = 'use $hash.Keys -contains $name'
    'ToUpperInvariant'= '-contains and -eq are already case-insensitive'
    'ToLowerInvariant'= '-contains and -eq are already case-insensitive'
}

$files = @(Get-ChildItem -Path $Path -Include '*.ps1','*.psm1' -Recurse)
Write-Host "Checking $($files.Count) file(s) under $Path"

Write-Host "`nStatic member access"
foreach ($file in $files) {
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errs)
    if ($errs) { throw "$($file.Name) does not parse: $($errs[0].Message)" }

    $static = @($ast.FindAll({
        param($n)
        ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -or
         $n -is [System.Management.Automation.Language.MemberExpressionAst]) -and $n.Static
    }, $true))

    $bad = @()
    foreach ($node in $static) {
        $typeName = "$($node.Expression)" -replace '^\[|\]$', ''
        $typeName = ($typeName -split '\.')[-1]
        if ($AllowedStaticTypes -notcontains $typeName) {
            $bad += "[$typeName]::$($node.Member) (line $($node.Extent.StartLineNumber))"
        }
    }

    Assert-True -Condition ($bad.Count -eq 0) `
        -Because "$($file.Name): $($static.Count) static reference(s), all on core types$(if ($bad.Count) { " — DISALLOWED: $($bad -join '; ')" })"
}

Write-Host "`nInstance methods on non-core types"
foreach ($file in $files) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)

    $calls = @($ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and -not $n.Static
    }, $true))

    $bad = @()
    foreach ($node in $calls) {
        $name = "$($node.Member)"
        if ($BannedInstanceCalls.Keys -contains $name) {
            $bad += "$name (line $($node.Extent.StartLineNumber)) — $($BannedInstanceCalls[$name])"
        }
    }

    Assert-True -Condition ($bad.Count -eq 0) `
        -Because "$($file.Name): no banned instance calls$(if ($bad.Count) { " — FOUND: $($bad -join '; ')" })"
}

Write-Host "`nType conversions"
# [pscustomobject]@{...} is rejected outright. Return a plain hashtable; member
# access reads identically at the call site.
$BannedCastTypes = @{
    'pscustomobject' = 'return a plain hashtable — $x.Prop reads the same'
    'psobject'       = 'return a plain hashtable — $x.Prop reads the same'
}

foreach ($file in $files) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)

    $casts = @($ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.ConvertExpressionAst]
    }, $true))

    $bad = @()
    foreach ($node in $casts) {
        $typeName = "$($node.Type.TypeName)"
        if ($BannedCastTypes.Keys -contains $typeName.ToLower()) {
            $bad += "[$typeName] (line $($node.Extent.StartLineNumber)) — $($BannedCastTypes[$typeName.ToLower()])"
        }
    }

    Assert-True -Condition ($bad.Count -eq 0) `
        -Because "$($file.Name): $($casts.Count) cast(s), none to a banned type$(if ($bad.Count) { " — FOUND: $($bad -join '; ')" })"
}

Write-Host "`nRuntime scriptblock construction"
foreach ($file in $files) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)

    $created = @($ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        "$($n.Expression)" -match 'scriptblock' -and "$($n.Member)" -eq 'Create'
    }, $true))

    Assert-True -Condition ($created.Count -eq 0) `
        -Because "$($file.Name): builds no scriptblock at runtime (this is what broke beta.1)"
}

Write-Host ""
Write-Host "$($script:Passed) passed, $($script:Failed) failed."
if ($script:Failed -gt 0) { exit 1 }
exit 0
