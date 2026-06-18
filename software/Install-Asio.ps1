<#
.SYNOPSIS
    ImmyBot Software Action: install the ConnectWise Platform (ITSPlatform) agent.

.DESCRIPTION
    Installs the generic barebone MSI downloaded by ImmyBot.

    The MSI is downloaded from the generic non-tokenized URL returned by the
    Dynamic Versions script. The install token is retrieved at install time and
    passed to msiexec using the MSI property:

        TOKEN=<guid>

    This package is workstation-only and installs with:

        SYSTEM=desktop

    Servers are intentionally blocked for now. Create a separate server software
    package/deployment after validating the correct ConnectWise Platform server
    install property.
#>

[CmdletBinding()]
param()

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

Invoke-ImmyCommand {
    $ErrorActionPreference = "Stop"

    $InstallerPath = $using:InstallerPath
    $InstallToken   = $using:InstallToken

    if (-not (Test-Path -LiteralPath $InstallerPath)) {
        throw "Installer file was not found on endpoint: $InstallerPath"
    }

    Write-Host "Installer file found: $InstallerPath"

    $OS = Get-CimInstance Win32_OperatingSystem

    if ($OS.ProductType -ne 1) {
        throw "ConnectWise Platform install blocked. This script is workstation-only. ProductType=$($OS.ProductType)"
    }

    $SystemType = "desktop"
    Write-Host "Confirmed workstation OS. Using SYSTEM=$SystemType"

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
        throw "ConnectWise Platform MSI install failed with exit code $($Process.ExitCode). Log: $LogPath"
    }

    return [PSCustomObject]@{
        Installer      = $InstallerPath
        ExitCode       = $Process.ExitCode
        RebootRequired = $Process.ExitCode -in @(3010, 1641)
        LogPath        = $LogPath
    }
}
