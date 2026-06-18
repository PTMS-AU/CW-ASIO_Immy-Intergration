<#
.SYNOPSIS
    ImmyBot custom detection script for ConnectWise Platform (ITSPlatform).

.DESCRIPTION
    The ConnectWise Platform agent self-updates, so we do not return the real
    installed agent version. Returning the real version can cause ImmyBot to
    compare it against the MSI bootstrapper version and attempt a downgrade.

    Returns 1.0.0 when the agent is installed, running, and registered.
    Returns nothing when the agent is missing or unhealthy.
#>

$PolicyVersion = "1.0.0"

$service = Get-Service -Name "ITSPlatform" -ErrorAction SilentlyContinue

$privateEndpointId = $null
$paths = @(
    "HKLM:\SOFTWARE\WOW6432Node\ITSPlatform",
    "HKLM:\SOFTWARE\ITSPlatform"
)

foreach ($path in $paths) {
    if (Test-Path $path) {
        $props = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue

        if ($props.privateendpointid) {
            $privateEndpointId = "$($props.privateendpointid)"
            break
        }
    }
}

if ($service -and $service.Status -eq "Running" -and $privateEndpointId) {
    Write-Host "ConnectWise Platform agent detected, running, and registered. EndpointId: $privateEndpointId"
    return $PolicyVersion
}

Write-Host "ConnectWise Platform agent not detected, not running, or not registered."
return $null