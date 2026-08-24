<#
.SYNOPSIS
    ImmyBot test script for ConnectWise Platform / ITSPlatform.  [v2.0.0-beta]

.DESCRIPTION
    Verifies the ConnectWise Platform agent is installed, running, and registered.

    Returns $true when healthy.
    Throws when unhealthy.
#>

[CmdletBinding()]
param()

# A freshly installed agent has to reach ConnectWise and write back its
# endpoint id before this can pass, so the wait is registration latency, not
# install time. Raise TimeoutMinutes on slow links.
$TimeoutMinutes = 5
$SleepSeconds = 15
$Deadline = (Get-Date).AddMinutes($TimeoutMinutes)

function Get-CWPlatformPrivateEndpointId {
    $regPaths = @(
        'HKLM:\SOFTWARE\WOW6432Node\ITSPlatform',
        'HKLM:\SOFTWARE\ITSPlatform'
    )

    foreach ($path in $regPaths) {
        if (Test-Path $path) {
            $props = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue

            if ($props.privateendpointid) {
                return "$($props.privateendpointid)"
            }
        }
    }

    return $null
}

$lastReasons = @()

do {
    $reasons = @()

    $svc = Get-Service -Name 'ITSPlatform' -ErrorAction SilentlyContinue

    if (-not $svc) {
        $reasons += "ITSPlatform service not present"
    }
    elseif ($svc.Status -ne 'Running') {
        $reasons += "ITSPlatform service is $($svc.Status), expected Running"

        try {
            Write-Host "Attempting to start ITSPlatform service..."
            Start-Service -Name 'ITSPlatform' -ErrorAction Stop
            Start-Sleep -Seconds 5
            $svc = Get-Service -Name 'ITSPlatform' -ErrorAction SilentlyContinue
        }
        catch {
            $reasons += "Could not start ITSPlatform service: $($_.Exception.Message)"
        }
    }

    $privateEndpointId = Get-CWPlatformPrivateEndpointId

    if (-not $privateEndpointId) {
        $reasons += "privateendpointid not found in registry"
    }

    if ($svc -and $svc.Status -eq 'Running' -and $privateEndpointId) {
        Write-Host "ConnectWise Platform agent test passed. EndpointId: $privateEndpointId"
        return $true
    }

    $lastReasons = $reasons

    Write-Host "ConnectWise Platform agent not healthy yet: $($reasons -join '; ')"
    Write-Host "Waiting $SleepSeconds seconds before retrying..."
    Start-Sleep -Seconds $SleepSeconds

} while ((Get-Date) -lt $Deadline)

throw "ConnectWise Platform agent test failed after $TimeoutMinutes minute(s) of polling: $($lastReasons -join '; '). If the service is Running but privateendpointid never appears, the agent installed but could not register — check the install token and the endpoint's outbound access to ConnectWise Platform."