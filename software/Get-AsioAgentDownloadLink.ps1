<#
.SYNOPSIS
    ImmyBot Dynamic Versions script for the ConnectWise Platform (ITSPlatform)
    agent.

.DESCRIPTION
    Returns a fixed policy version of 1.0.0 paired with the generic, non-tokenized
    barebone MSI URL.

    ** YOU MUST UPDATE $URL BELOW ** to point to your own hosted copy of the
    ConnectWise Platform barebone MSI. See the README and docs for instructions
    on downloading and hosting the MSI.

    The install token is not included in the URL. It must be supplied at install
    time by the install script using the MSI property TOKEN=<guid>.

    The agent self-updates after install, so ImmyBot should treat this as a binary
    installed/healthy check rather than enforcing the MSI/bootstrapper version.
#>

[CmdletBinding()]
param()

$Version  = "1.0.0"
# ── CHANGE THIS URL ──────────────────────────────────────────────────────────
# Point this to your own hosted copy of the ConnectWise Platform barebone MSI.
# Download the MSI from:
#   https://setup.auplatform.connectwise.com/windows/BareboneAgent/32/ITSagent/MSI/setup
# Then upload it to your own storage (Azure Blob, S3, file share, etc.) and
# paste the direct-download URL below.
# ─────────────────────────────────────────────────────────────────────────────
$URL      = "https://YOUR-STORAGE-URL/ITSPlatform.msi"
$FileName = "ConnectWise-Platform-BareboneAgent.msi"

if ($URL -match 'YOUR-STORAGE-URL') {
    throw "Get-AsioAgentDownloadLink: `$URL has not been configured. Update the URL in this script to point to your own hosted copy of the ConnectWise Platform barebone MSI."
}

Write-Host "Returning fixed version $Version with generic barebone MSI URL."

$Response = New-Object PSObject -Property @{
    Versions = @(
        New-DynamicVersion -Version $Version -Uri $URL -FileName $FileName
    )
}

return $Response