<#
.SYNOPSIS
    ImmyBot Dynamic Versions script for the ConnectWise RMM (ASIO / ITSPlatform)
    agent on the Australia platform.

.DESCRIPTION
    Returns a fixed policy version of 1.0.0 paired with the generic, non-tokenized
    Australia barebone MSI URL.

    The install token is not included in the URL. It must be supplied at install
    time by the install script using the MSI property TOKEN=<guid>.

    ASIO self-updates after install, so ImmyBot should treat this as a binary
    installed/healthy check rather than enforcing the MSI/bootstrapper version.
#>

[CmdletBinding()]
param()

$Version  = "1.0.0"
$URL      = "https://platinumfilestorage.blob.core.windows.net/installer/asio/ITSPlatform.msi"
$FileName = "ConnectWise-ASIO-BareboneAgent.msi"

Write-Host "Returning fixed version $Version with generic ASIO barebone MSI URL."

$Response = New-Object PSObject -Property @{
    Versions = @(
        New-DynamicVersion -Version $Version -Uri $URL -FileName $FileName
    )
}

return $Response