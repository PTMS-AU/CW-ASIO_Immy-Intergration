<#
.SYNOPSIS
    ImmyBot Software Action: install the ConnectWise Platform (ITSPlatform) agent.
    [v2.0.0-beta]

.DESCRIPTION
    Installs the generic barebone MSI downloaded by ImmyBot.

    The MSI is downloaded from the generic non-tokenized URL returned by the
    Dynamic Versions script. The install token is retrieved at install time and
    passed to msiexec using the MSI property:

        TOKEN=<guid>

    Beta changes:
      - The install token is validated as a GUID before it reaches msiexec.
        A malformed token installs an agent that never registers, which surfaces
        days later as a detection bug rather than an install failure.
      - Optional server support behind $AllowServerInstall (see below).
#>

[CmdletBinding()]
param()

# =====================================================================
# SERVER INSTALL — OPT-IN, UNVALIDATED
# ---------------------------------------------------------------------
# Workstations install with SYSTEM=desktop, which is confirmed working. The
# server value is NOT confirmed against ConnectWise Platform. Alpha refused to
# guess and simply blocked servers; beta keeps that default and makes the guess
# an explicit, deliberate choice rather than a silent one.
#
# Before setting this to $true: confirm the correct SYSTEM= value with
# ConnectWise, set $ServerSystemType to match, and test on ONE non-production
# server. An agent installed in the wrong mode registers but is licensed and
# monitored incorrectly.
# =====================================================================
$AllowServerInstall = $false
$ServerSystemType   = 'server'

if (-not $InstallerFile) {
    throw "InstallerFile was not provided by ImmyBot."
}

$InstallerPath = "$InstallerFile"

if ($InstallerFile.FullName) {
    $InstallerPath = "$($InstallerFile.FullName)"
}

# This must run in MetaScript context
try {
    $InstallToken = Get-IntegrationAgentInstallToken -ErrorAction Stop

    if ([string]::IsNullOrWhiteSpace($InstallToken)) {
        throw "Install token was empty."
    }
}
catch {
    throw "Get-IntegrationAgentInstallToken failed in MetaScript context: $($_.Exception.Message)"
}

# Validate BEFORE handing it to msiexec. If the integration returned an error
# string, a truncated value, or anything that is not a token, the MSI will still
# install happily and produce an agent that never checks in to ConnectWise —
# which then looks like a detection or registration fault instead of a bad
# token. The integration validates this too; both ends check because the failure
# is silent and expensive.
$InstallToken = "$InstallToken".Trim()
$parsedGuid = [Guid]::Empty

if (-not [Guid]::TryParse($InstallToken, [ref]$parsedGuid)) {
    $preview = if ($InstallToken.Length -gt 12) { $InstallToken.Substring(0, 12) + '...' } else { $InstallToken }
    throw "Install token is not a GUID (got '$preview', length $($InstallToken.Length)). Refusing to install an agent that cannot register. Check the integration's GetTenantInstallToken output and the tenant's company mapping."
}

Write-Host "Install token validated as a GUID."

Invoke-ImmyCommand {
    $ErrorActionPreference = "Stop"

    $InstallerPath      = $using:InstallerPath
    $InstallToken       = $using:InstallToken
    $AllowServerInstall = $using:AllowServerInstall
    $ServerSystemType   = $using:ServerSystemType

    if (-not (Test-Path -LiteralPath $InstallerPath)) {
        throw "Installer file was not found on endpoint: $InstallerPath"
    }

    Write-Host "Installer file found: $InstallerPath"

    $OS = Get-CimInstance Win32_OperatingSystem

    # ProductType: 1 = workstation, 2 = domain controller, 3 = server.
    if ($OS.ProductType -eq 1) {
        $SystemType = "desktop"
        Write-Host "Confirmed workstation OS. Using SYSTEM=$SystemType"
    }
    elseif ($AllowServerInstall) {
        $SystemType = $ServerSystemType
        Write-Warning "Server OS detected (ProductType=$($OS.ProductType)). Installing with SYSTEM=$SystemType — this value is NOT confirmed against ConnectWise Platform. Verify the agent registers in the correct mode."
    }
    else {
        throw "ConnectWise Platform install blocked. This script is workstation-only by default. ProductType=$($OS.ProductType). To enable servers, set `$AllowServerInstall = `$true after confirming the correct SYSTEM= value."
    }

    $LogPath = Join-Path $env:TEMP "ConnectWise-Platform-install.log"

    $Arguments = @(
        "/i"
        "`"$InstallerPath`""
        "/qn"
        "/norestart"
        "TOKEN=`"$InstallToken`""
        "SYSTEM=$SystemType"
        "/L*v"
        "`"$LogPath`""
    ) -join " "

    Write-Host "Running msiexec. Log path: $LogPath"

    $Process = Start-Process -FilePath "msiexec.exe" `
        -ArgumentList $Arguments `
        -Wait `
        -PassThru

    Write-Host "msiexec exit code: $($Process.ExitCode)"

    if ($Process.ExitCode -notin @(0, 3010, 1641)) {
        # Surface the tail of the MSI log with the failure. Without it, every
        # install failure needs a second round trip to the endpoint to find out
        # what actually happened.
        if (Test-Path -LiteralPath $LogPath) {
            Write-Warning "Last 30 lines of $LogPath :"
            Get-Content -LiteralPath $LogPath -Tail 30 | ForEach-Object { Write-Warning "  $_" }
        }

        throw "ConnectWise Platform MSI install failed with exit code $($Process.ExitCode). Log: $LogPath"
    }

    return [PSCustomObject]@{
        Installer      = $InstallerPath
        ExitCode       = $Process.ExitCode
        SystemType     = $SystemType
        RebootRequired = $Process.ExitCode -in @(3010, 1641)
        LogPath        = $LogPath
    }
}
