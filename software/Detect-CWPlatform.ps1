<#
.SYNOPSIS
    ImmyBot custom detection script for ConnectWise Platform (ITSPlatform).
    [v2.0.0-beta]

.DESCRIPTION
    The ConnectWise Platform agent self-updates, so we do not return the real
    installed agent version. Returning the real version can cause ImmyBot to
    compare it against the MSI bootstrapper version and attempt a downgrade.

    Returns 1.0.0 when the agent is installed, running, and registered.
    Returns nothing when the agent is missing or unhealthy.

    Beta change: the real agent version is still read and LOGGED (never
    returned). Alpha discarded it entirely, which meant there was no way to tell
    from ImmyBot whether a machine was running a current agent or one that had
    been failing to self-update for months.
#>

$PolicyVersion = "1.0.0"

$paths = @(
    "HKLM:\SOFTWARE\WOW6432Node\ITSPlatform",
    "HKLM:\SOFTWARE\ITSPlatform"
)

$service = Get-Service -Name "ITSPlatform" -ErrorAction SilentlyContinue

$privateEndpointId = $null
$actualVersion     = $null

foreach ($path in $paths) {
    if (-not (Test-Path $path)) { continue }

    $props = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
    if (-not $props) { continue }

    if (-not $privateEndpointId -and $props.privateendpointid) {
        $privateEndpointId = "$($props.privateendpointid)"
    }

    # Property name is not consistent across agent builds — take the first hit.
    if (-not $actualVersion) {
        foreach ($name in 'version', 'Version', 'agentVersion', 'AgentVersion', 'ProductVersion') {
            if ($props.PSObject.Properties[$name] -and $props.$name) {
                $actualVersion = "$($props.$name)"
                break
            }
        }
    }
}

if ($service -and $service.Status -eq "Running" -and $privateEndpointId) {
    $versionNote = if ($actualVersion) { "Agent version: $actualVersion" } else { "Agent version: not reported in registry" }
    Write-Host "ConnectWise Platform agent detected, running, and registered. EndpointId: $privateEndpointId. $versionNote (reporting $PolicyVersion to ImmyBot by design — the agent self-updates)."
    return $PolicyVersion
}

# Say which of the three conditions actually failed. Alpha logged one flat
# message for all three, so a half-installed agent and a missing one looked
# identical in the log.
$reasons = @()
if (-not $service)                        { $reasons += "ITSPlatform service not present" }
elseif ($service.Status -ne "Running")    { $reasons += "ITSPlatform service is $($service.Status)" }
if (-not $privateEndpointId)              { $reasons += "privateendpointid missing from registry (agent not registered)" }

Write-Host "ConnectWise Platform agent not detected: $($reasons -join '; ')."

# --------------------------------------------------------------------
# Leftover check -- REPORTED, never counted as installed.
#
# The product spans two naming generations: ITSPlatform (ConnectWise
# Platform) and SAAZOD / SaazOnDemand (the ITSupport247 lineage). Only the
# ITSPlatform service plus a privateendpointid proves the agent is
# registered with ConnectWise Platform, so that stays the sole basis for
# the version this script returns.
#
# Widening detection to accept SAAZOD would be actively harmful: a machine
# carrying only legacy leftovers would report as installed, ImmyBot would
# consider it compliant, and it would never be repaired -- the exact
# half-state that has to be cleaned up before a reinstall can succeed.
#
# Staying silent about them is the other failure. A machine reads as "not
# detected", ImmyBot installs, the MSI finds the old registration and
# no-ops with exit 0, and the loop repeats with nothing in the log to
# explain it. So: report loudly, return nothing.
# --------------------------------------------------------------------
$leftovers = @()

foreach ($legacyPath in @('HKLM:\SOFTWARE\WOW6432Node\SAAZOD', 'HKLM:\SOFTWARE\SAAZOD')) {
    if (Test-Path $legacyPath) {
        $lp   = Get-ItemProperty -Path $legacyPath -ErrorAction SilentlyContinue
        $bits = @("registry key $legacyPath")
        if ($lp.SITEID)      { $bits += "SITEID=$($lp.SITEID)" }
        if ($lp.MEMBERID)    { $bits += "MEMBERID=$($lp.MEMBERID)" }
        if ($lp.InstallDate) { $bits += "InstallDate=$($lp.InstallDate)" }
        $leftovers += ($bits -join ', ')
    }
}

foreach ($legacyDir in @("$env:ProgramFiles\SAAZOD", "${env:ProgramFiles(x86)}\SAAZOD")) {
    if ($legacyDir -and (Test-Path -LiteralPath $legacyDir)) { $leftovers += "directory $legacyDir" }
}

if ($leftovers.Count -gt 0) {
    Write-Host "NOTE: legacy SAAZOD registration is still on this machine even though the agent is not detected:"
    foreach ($l in $leftovers) { Write-Host "  - $l" }
    Write-Host "A reinstall can no-op while this remains (msiexec returns 0 and creates no service). The INSTALL script clears these before running msiexec — the uninstall action cannot, because ImmyBot skips it entirely when detection reports nothing ('No action to take because the software was not detected')."
}

return $null
