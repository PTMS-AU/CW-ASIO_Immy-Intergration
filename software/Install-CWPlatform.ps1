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

# EXECUTION CONTEXT GUARD -- see the same note in Uninstall-CWPlatform.ps1.
# Get-IntegrationAgentInstallToken and Invoke-ImmyCommand exist only in
# METASCRIPT. A script left in the System/User context runs on the endpoint,
# where neither is defined, and fails with "The term 'X' is not recognized"
# rather than anything that points at the real cause.
$missing = @()
foreach ($cmd in 'Invoke-ImmyCommand', 'Get-IntegrationAgentInstallToken') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { $missing += $cmd }
}

if ($missing.Count -gt 0) {
    throw "Wrong execution context: $($missing -join ', ') $(if ($missing.Count -eq 1) { 'is' } else { 'are' }) not available here. This script requires ImmyBot's METASCRIPT context. Open the script in ImmyBot and set Execution Context to Metascript, then re-run."
}

if (-not $InstallerFile) {
    throw "InstallerFile was not provided by ImmyBot."
}

$InstallerPath = "$InstallerFile"

if ($InstallerFile.FullName) {
    $InstallerPath = "$($InstallerFile.FullName)"
}

try {
    $InstallToken = Get-IntegrationAgentInstallToken -ErrorAction Stop

    if ([string]::IsNullOrWhiteSpace($InstallToken)) {
        throw "Install token was empty."
    }
}
catch {
    # Do NOT say "failed in MetaScript context" here. The context guard above has
    # already proven the context is correct, and blaming it sends the reader
    # after the wrong thing -- ImmyBot's own message is the useful part, so lead
    # with it verbatim and only then add what it means.
    $detail = "$($_.Exception.Message)"
    $hint   = ''

    if ($detail -match 'not linked|provider link|integration is not linked') {
        $hint = " -- The software entry's Agent Integration is not bound to the deployment that ran this. Repointing the Agent Integration is not enough on its own: open the DEPLOYMENT for this software and re-save it so ImmyBot re-establishes the link, then confirm Software > Advanced > Agent Integration points at the ConnectWise Platform integration, and that the tenant is mapped under Integration > Clients."
    }
    elseif ($detail -match 'no mapped') {
        $hint = " -- The tenant is not mapped to a ConnectWise Platform company. Map it under Integration > Clients (map the one tenant by hand; do not Accept All on Suggested Mappings, which creates new tenants)."
    }

    throw "Get-IntegrationAgentInstallToken failed: $detail$hint"
}

# Validate BEFORE handing it to msiexec. If the integration returned an error
# string, a truncated value, or anything that is not a token, the MSI will still
# install happily and produce an agent that never checks in to ConnectWise —
# which then looks like a detection or registration fault instead of a bad
# token. The integration validates this too; both ends check because the failure
# is silent and expensive.
$InstallToken = "$InstallToken".Trim()

# Regex rather than [Guid]::TryParse — that needs [ref], and ImmyBot runs script
# blocks in ConstrainedLanguage mode where static calls outside the core types
# raise "Method invocation is supported only on core types in this language mode".
if ($InstallToken -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
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

    # A SUCCESSFUL exit is not proof the agent installed. Exit 0 in ~15 seconds
    # with no ITSPlatform service afterwards is the case this exists for: the
    # MSI can decide the product is already present and no-op, and it reports
    # that as success. Without these lines the log is the only evidence and it
    # takes another trip to the endpoint to read it.
    if (Test-Path -LiteralPath $LogPath) {
        $verdict = @(Get-Content -LiteralPath $LogPath -ErrorAction SilentlyContinue |
            Where-Object { $_ -match 'Installation (completed successfully|success or error status)|Product Version|Reconfiguration success|Removal success|already installed|Return Value 3|MainEngineThread is returning' })

        if ($verdict.Count -gt 0) {
            Write-Host "MSI log verdict lines:"
            foreach ($line in ($verdict | Select-Object -Last 12)) { Write-Host "  $line" }
        } else {
            Write-Warning "No recognisable verdict line found in $LogPath."
        }
    }

    # What actually landed. The barebone MSI is a bootstrapper -- the real agent
    # arrives afterwards -- so report the state at this instant rather than
    # implying the install is finished.
    $svcNow = @(Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '(?i)itsplatform|saaz' })

    if ($svcNow.Count -gt 0) {
        Write-Host "Agent services present now: $(($svcNow | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ', ')"
    } else {
        Write-Warning "No ITSPlatform or SAAZ service exists after a successful msiexec. Either the bootstrapper has not finished fetching the agent yet, or the MSI no-opped because leftover registration made it think the product was already installed. Check $LogPath and HKLM:\SOFTWARE\WOW6432Node\SAAZOD."
    }

    return [PSCustomObject]@{
        Installer      = $InstallerPath
        ExitCode       = $Process.ExitCode
        SystemType     = $SystemType
        RebootRequired = $Process.ExitCode -in @(3010, 1641)
        LogPath        = $LogPath
    }
}
