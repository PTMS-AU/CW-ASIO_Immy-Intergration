<#
.SYNOPSIS
    ImmyBot uninstall script for the ConnectWise Platform (ITSPlatform) agent.
    [v2.0.0-beta]

.DESCRIPTION
    Adapted from the working ConnectWise Automate uninstall pattern. Uses
    Detect-Software with the $DetectionString (a regex matching the SAAZOD /
    ITSPlatform display name) to locate the installed product, parses its
    UninstallString, and runs it silently.

    The SAAZOD agent's DisplayName is 'SaazOnDemand' (confirmed from discovery
    output), so the detection string passed in via the software entry should be
    something like:  ^(SaazOnDemand|ITSPlatform)$  or  SaazOnDemand|ITSPlatform

.PARAMETER DetectionString
    Regex used by Detect-Software to find the software entries to uninstall.
    Configured in the software entry's Uninstallation section.

.PARAMETER UninstallPassword
    Optional. If the MSI was installed with an uninstall password, supply it here.

.NOTES
    Beta fix: $UninstallLog is initialised before the loop. It used to be
    assigned only inside the unins000.exe branch, while the Invoke-ImmyCommand
    block referenced $using:UninstallLog unconditionally — so on the msiexec
    path (which is the actual ITSPlatform path) the variable was never defined
    and $using: had nothing to bind to. The uninstall itself had already
    succeeded by then, making it look like a mystery post-uninstall failure.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$DetectionString,

    [Parameter()]
    [string]$UninstallPassword
)

if ($null -eq $DetectionString -or $DetectionString -eq "") {
    throw "`$DetectionString is null or empty, this script requires a valid Regular Expression Detection String"
}

$Softwares = Detect-Software -RegExSoftwareSearchString $DetectionString

foreach ($Software in $Softwares) {
        # Set for every path, not just the unins000 branch, so the $using:
        # reference inside Invoke-ImmyCommand below always has something to bind.
        $UninstallLog = $null

        $UninstallString = "$($Software.UninstallString)"
        $CommandlinePattern = '(?:(?:"(?<FileName>[~()\s\w:\\{}.-]*)"|(?<FileName>[~()\s\w:\\{}.-]+\.(?:exe|msi)))){1}\s*(?<ArgumentList>.+)?$'
        $CommandlineMatches = ($UninstallString | Select-String -Pattern $CommandlinePattern)

        if ($null -ne $CommandlineMatches.Matches) {
            $CommandineItems = $CommandlineMatches.Matches[0]
            $FileName = $CommandineItems.Groups['FileName'].Value

            if ($FileName -notmatch "msiexec\.exe") {
                if ($FileName -match "unins000\.exe") {
                    $UninstallLog = Invoke-ImmyCommand { [IO.Path]::GetTempFileName() }
                    $ArgumentList = " /SILENT /VERYSILENT /SUPPRESSMSGBOXES /SP- /Log=`"$UninstallLog`" /NORESTART"
                } else {
                    $ArgumentList = "$($CommandineItems.Groups['ArgumentList'].Value) /S /norestart"
                    $ArgumentList = $ArgumentList -replace "/q0","/q2"
                }
            } else {
                if ($UninstallPassword) {
                    $ArgumentList = "$($CommandineItems.Groups['ArgumentList'].Value) /quiet /qn /norestart uninstallpassword=$UninstallPassword".Replace("/I{","/X{")
                } else {
                    $ArgumentList = "$($CommandineItems.Groups['ArgumentList'].Value) /quiet /qn /norestart".Replace("/I{","/X{")
                }
            }

            Write-Host "Uninstalling: $($Software.DisplayName)"
            Write-Host "Executing: $FileName $ArgumentList"

            $ExitCode = Invoke-ImmyCommand -Timeout 600 {
                $Process = Start-Process -Wait -FilePath $Using:FileName -ArgumentList $Using:ArgumentList -Passthru
                $ExitCode = $Process.ExitCode
                Write-Host "ExitCode: $ExitCode"
                if ($ExitCode -ne 0 -and $null -ne $using:UninstallLog) {
                    if (Test-Path $using:UninstallLog -ErrorAction Ignore) {
                        Get-Content -Path $using:UninstallLog | Select-Object -Last 50
                    }
                }
                return $ExitCode
            }

            if ($ExitCode -in 0, 1605) {
                Write-Host "Attempting Registry key removal for software: $($Software.DisplayName)"
                Remove-SoftwareRegKey -Software $Software -Force
            }
        }
}

# Belt-and-suspenders cleanup: ITSPlatform sometimes leaves the agentcore service
# and registry keys behind after MSI uninstall. Remove them so detection doesn't
# show a "half installed" state on the next sync.
Invoke-ImmyCommand {
    $services = @('ITSPlatform','ITSPlatformManager')
    foreach ($svc in $services) {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s) {
            try {
                if ($s.Status -ne 'Stopped') { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue }
                sc.exe delete $svc | Out-Null
                Write-Host "Removed service: $svc"
            } catch {
                Write-Warning "Could not remove service ${svc}: $_"
            }
        }
    }

    $regKeys = @(
        'HKLM:\SOFTWARE\WOW6432Node\ITSPlatform',
        'HKLM:\SOFTWARE\ITSPlatform'
    )
    foreach ($k in $regKeys) {
        if (Test-Path $k) {
            try {
                Remove-Item -Path $k -Recurse -Force -ErrorAction Stop
                Write-Host "Removed registry key: $k"
            } catch {
                Write-Warning "Could not remove registry key ${k}: $_"
            }
        }
    }
}