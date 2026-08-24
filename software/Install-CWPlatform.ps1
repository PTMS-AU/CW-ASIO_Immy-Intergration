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

    Proven in situ 2026-08-24 on PT-WIN11LAB (session #425809): the agent
    installs, starts and registers, and ConnectWise's own installer validates
    the minted token via its checkTokenAction. The endpoint id is REUSED on
    reinstall rather than duplicated, so there is no stale record to clear
    from the console first — deleting it would discard the mapping.
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

# -Timeout is NOT optional here. Invoke-ImmyCommand defaults to 120 seconds,
# and this block does far more than that: de-register the old product, stop
# services and processes, delete directories, then run an agent install whose
# StartServices step alone waits 60s. The first real install died at
# "Script timed out after 120 seconds" with msiexec still running, which
# leaves the endpoint mid-install with no result reported.
Invoke-ImmyCommand -Timeout 1500 {
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

    # ----------------------------------------------------------------
    # Clear blocking legacy registration BEFORE msiexec.
    #
    # This lives here, not in the uninstall script, because the uninstall
    # action cannot be relied on to run. ImmyBot skips it entirely when
    # detection reports nothing -- "No action to take because the software
    # was not detected" -- and detection correctly reports nothing when the
    # ITSPlatform service and privateendpointid are absent. So a machine
    # holding only SAAZOD leftovers can never reach the uninstall path, and
    # the install is the one action that does run.
    #
    # Removing this is safe precisely here: the only reason this script is
    # executing is that detection already established no working agent is
    # present. What is being deleted is stale registration from a previous
    # generation of the product, which is what makes msiexec exit 0 without
    # creating a service.
    # ----------------------------------------------------------------
    # ----------------------------------------------------------------
    # De-register the orphaned MSI product FIRST. This is the actual cause
    # of the silent no-op, proven from the MSI log:
    #
    #   Product registered: entering maintenance mode
    #   ProductState = 5
    #   Skipping RemoveExistingProducts: current configuration is
    #     maintenance mode
    #   Feature: MainFeature; Installed: Local; Request: Null; Action: Null
    #   Windows Installer reconfigured the product ... status: 0
    #
    # Windows Installer still has ITSPlatform {18F39771-...} 5.0.3.3573
    # registered, so msiexec /i treats a fresh install as a reconfigure of
    # something already present, does nothing, and exits 0. Every component
    # reads Action: Null -- no files, no service, no work at all.
    #
    # Deleting the service and registry keys does NOT fix this. Those are
    # the product's own state; the registration lives in the Windows
    # Installer database and outlives them, which is exactly how this
    # machine ended up orphaned: files gone, registration intact.
    #
    # So the product has to be properly uninstalled by ProductCode before
    # an install can do anything. 1605 (not currently installed) is a
    # success here -- it means the registration was already clean.
    # ----------------------------------------------------------------
    $arpRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    $stale = @()

    foreach ($root in $arpRoots) {
        if (-not (Test-Path $root)) { continue }

        foreach ($sub in (Get-ChildItem -Path $root -ErrorAction SilentlyContinue)) {
            $props = Get-ItemProperty -Path $sub.PSPath -ErrorAction SilentlyContinue
            if (-not $props.DisplayName) { continue }
            if ($props.DisplayName -notmatch '(?i)^(ITSPlatform|SaazOnDemand)$') { continue }

            # The ProductCode is the key name for an MSI-installed product.
            # De-duplicated: the same code is visible under both the 32- and
            # 64-bit ARP views, and uninstalling twice just earns a 1605 on
            # the second pass.
            if ($sub.PSChildName -match '^\{[0-9A-Fa-f-]{36}\}$') {
                $already = @($stale | Where-Object { $_.Code -eq $sub.PSChildName })
                if ($already.Count -eq 0) {
                    $stale += @{
                        Code    = $sub.PSChildName
                        Name    = "$($props.DisplayName)"
                        Version = "$($props.DisplayVersion)"
                    }
                }
            }
        }
    }

    if ($stale.Count -eq 0) {
        Write-Host "No existing ITSPlatform/SaazOnDemand product registration found."
    }

    foreach ($prod in $stale) {
        Write-Host "De-registering existing product $($prod.Name) $($prod.Version) $($prod.Code) — msiexec /i no-ops while this is registered."

        $rmArgs = "/x `"$($prod.Code)`" /qn /norestart REBOOT=ReallySuppress"
        $rm = Start-Process -FilePath 'msiexec.exe' -ArgumentList $rmArgs -Wait -PassThru

        if ($rm.ExitCode -in @(0, 1605, 3010, 1641)) {
            Write-Host "  removed (exit $($rm.ExitCode))"
        } else {
            Write-Warning "  msiexec /x returned $($rm.ExitCode); the install may still no-op."
        }
    }

    # Stop whatever is holding the legacy files open. Removing the
    # directory failed in situ with:
    #
    #   Cannot remove item ...\SAAZOD\SAAZDPMACTL.exe:
    #   Access to the path 'SAAZDPMACTL.exe' is denied.
    #
    # which on an .exe means a service or process from the previous
    # generation is still running. Detection never reports these: it looks
    # only at the ITSPlatform service, and these are SAAZ-named. Discovered
    # by pattern rather than a fixed list, because the SAAZ service names
    # are not knowable from the ImmyBot side.
    $legacyDirs = @("$env:ProgramFiles\SAAZOD", "${env:ProgramFiles(x86)}\SAAZOD")

    $legacySvc = @(Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '(?i)itsplatform|saaz' })

    # PROCESSES FIRST, THEN SERVICES. Deleting a service whose executable is
    # still running only marks it for deletion -- the SCM keeps the entry
    # until the last handle closes, and a machine left in that state can
    # refuse to start a newly installed service. The first attempt did this
    # in the wrong order (delete, then kill) and the install then failed with
    # "Error 1920. Service 'ITSPlatform Service' (ITSPlatform) failed to
    # start", so the order here is deliberate.
    foreach ($d in $legacyDirs) {
        if (-not $d) { continue }
        $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $path = $null
            try { $path = $_.Path } catch { $path = $null }
            $path -and $path.StartsWith($d, [System.StringComparison]::OrdinalIgnoreCase)
        })

        foreach ($pr in $procs) {
            try {
                Stop-Process -Id $pr.Id -Force -ErrorAction Stop
                Write-Host "  stopped process $($pr.ProcessName) (pid $($pr.Id)) running from $d"
            } catch {
                Write-Warning "  could not stop $($pr.ProcessName) (pid $($pr.Id)): $_"
            }
        }
    }

    if ($legacySvc.Count -gt 0) {
        Write-Host "Stopping legacy services: $(($legacySvc | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ', ')"
        foreach ($s in $legacySvc) {
            try {
                if ($s.Status -ne 'Stopped') { Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue }
                sc.exe delete $s.Name | Out-Null
                Write-Host "  removed service $($s.Name)"
            } catch {
                Write-Warning "  could not remove service $($s.Name): $_"
            }
        }

        Start-Sleep -Seconds 5

        # A name still resolving here is marked-for-deletion, not gone, and
        # that is a reboot-to-clear condition rather than something this
        # script can force.
        $stillThere = @(Get-Service -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '(?i)itsplatform|saaz' })

        if ($stillThere.Count -gt 0) {
            Write-Warning "These services are still registered after deletion, which means the SCM has them marked for deletion pending a reboot: $(($stillThere | ForEach-Object { $_.Name }) -join ', '). If the install fails with Error 1920 (service failed to start), reboot this machine and re-run -- the new agent's service cannot be created cleanly while the old entries linger."
        }
    }

    $legacyKeys = @(
        'HKLM:\SOFTWARE\WOW6432Node\SAAZOD',
        'HKLM:\SOFTWARE\SAAZOD',
        'HKLM:\SOFTWARE\WOW6432Node\ITSPlatform',
        'HKLM:\SOFTWARE\ITSPlatform'
    )

    $cleared = @()

    foreach ($k in $legacyKeys) {
        if (Test-Path $k) {
            $props = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
            $note  = $k
            if ($props.SITEID)      { $note += " (SITEID=$($props.SITEID)" }
            if ($props.InstallDate) { $note += ", InstallDate=$($props.InstallDate)" }
            if ($props.SITEID)      { $note += ")" }

            try {
                Remove-Item -Path $k -Recurse -Force -ErrorAction Stop
                $cleared += $note
            } catch {
                Write-Warning "Could not clear ${k}: $_ -- the install may no-op while it remains."
            }
        }
    }

    foreach ($d in $legacyDirs) {
        if ($d -and (Test-Path -LiteralPath $d)) {
            try {
                Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction Stop
                $cleared += "directory $d"
            } catch {
                Write-Warning "Could not remove ${d}: $_ -- the install may no-op while it remains."
            }
        }
    }

    if ($cleared.Count -gt 0) {
        Write-Host "Cleared stale registration before installing:"
        foreach ($c in $cleared) { Write-Host "  - $c" }
    } else {
        Write-Host "No stale ITSPlatform or SAAZOD registration found — clean install."
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

        # The MSI log reports THAT the service would not start; the agent's own
        # setup log is the only place that says why.
        $agentLogs = @(
            "$env:ProgramFiles\ITSPlatformSetupLogs\ITSPlatform-AppManager.log",
            "${env:ProgramFiles(x86)}\ITSPlatformSetupLogs\ITSPlatform-AppManager.log"
        )

        foreach ($al in $agentLogs) {
            if ($al -and (Test-Path -LiteralPath $al)) {
                Write-Warning "Last 40 lines of $al :"
                Get-Content -LiteralPath $al -Tail 40 -ErrorAction SilentlyContinue |
                    ForEach-Object { Write-Warning "  $_" }
            }
        }

        if ($Process.ExitCode -eq 1603) {
            Write-Warning "Exit 1603 with 'Error 1920 ... failed to start' in the MSI log is usually one of: services still marked for deletion pending a reboot (see the warning above), or endpoint security blocking the new service binary. Reboot and re-run before investigating further."
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
