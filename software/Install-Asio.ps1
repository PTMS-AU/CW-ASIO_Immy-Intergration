<#
.SYNOPSIS
    ImmyBot Software Action: install the ConnectWise RMM (ASIO / ITSPlatform) agent.

.DESCRIPTION
    Installs the generic barebone MSI downloaded by ImmyBot.

    The MSI is downloaded from the generic non-tokenized URL returned by the
    Dynamic Versions script. The install token is retrieved at install time and
    passed to msiexec using the MSI property:

        TOKEN=<guid>

    This package is workstation-only and installs with:

        SYSTEM=desktop

    Servers are intentionally blocked for now. Create a separate server software
    package/deployment after validating the correct ConnectWise ASIO server
    install property.
#>

[CmdletBinding()]
param()

# --- 1. Validate installer file from ImmyBot -------------------------------

if (-not $InstallerFile) {
    throw "InstallerFile was not provided by ImmyBot. Verify the dynamic version returned a valid URI/FileName and the package downloaded successfully."
}

$InstallerPath = "$InstallerFile"

# If ImmyBot supplied a FileInfo-like object, prefer FullName.
if ($InstallerFile.FullName) {
    $InstallerPath = "$($InstallerFile.FullName)"
}

if (-not (Test-Path -LiteralPath $InstallerPath)) {
    throw "Installer file was not found: $InstallerPath"
}

Write-Host "Installer file found: $InstallerPath"

# --- 2. Confirm this is a workstation --------------------------------------
# Win32_OperatingSystem ProductType:
#   1 = Workstation
#   2 = Domain Controller
#   3 = Server

try {
    $ProductType = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop |
        Select-Object -ExpandProperty ProductType
}
catch {
    throw "Could not determine OS ProductType. Aborting to avoid installing ASIO with the wrong SYSTEM mode. Error: $($_.Exception.Message)"
}

if ($ProductType -ne 1) {
    throw "This ConnectWise ASIO package is configured for workstations only using SYSTEM=desktop. Detected OS ProductType=$ProductType. Create a separate server package after validating the correct server install property."
}

$SystemMode = "desktop"
Write-Host "Confirmed workstation OS. Using ASIO SYSTEM=$SystemMode"

# --- 3. Fetch per-tenant install token -------------------------------------

try {
    $TokenGuid = Get-IntegrationAgentInstallToken -ErrorAction Stop
}
catch {
    throw "Get-IntegrationAgentInstallToken failed: $($_.Exception.Message)"
}

if (-not $TokenGuid) {
    throw "Get-IntegrationAgentInstallToken returned nothing. Verify the ConnectWise RMM integration is enabled and that the tenant is mapped to exactly one company under Integration > Clients."
}

$TokenGuid = "$TokenGuid".Trim()

if ($TokenGuid -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
    throw "Install token was returned but does not look like a GUID. Length: $($TokenGuid.Length)"
}

Write-Host "Retrieved install token. Length: $($TokenGuid.Length)"

# --- 4. Build MSI arguments -------------------------------------------------
# Do not log the token value.

$MsiArguments = "TOKEN=$TokenGuid SYSTEM=$SystemMode"

Write-Host "Installing ConnectWise ASIO agent with arguments: TOKEN=<redacted> SYSTEM=$SystemMode"

# --- 5. Install -------------------------------------------------------------
# Install-MSI handles msiexec, quiet mode, logging, and exit code interpretation.

Install-MSI -Path $InstallerPath -Arguments $MsiArguments