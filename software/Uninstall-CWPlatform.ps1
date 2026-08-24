<#
.SYNOPSIS
    ImmyBot uninstall script for the ConnectWise Platform (ITSPlatform) agent.
    [v2.0.0-beta]

.DESCRIPTION
    Derived from ImmyBot's own shipped Global script
    "Uninstall Multiple Versions - RegEx Detection String Required.ps1"
    (Global > Software > Action). That script is the authority for this
    contract; two things were confirmed against it directly.

    ** THE SOFTWARE ENTRY'S SEARCH MODE MUST BE 'REGEX'. **

    It is in the shipped script's own name. $DetectionString is handed straight
    to Detect-Software -RegExSoftwareSearchString with no conversion, so a
    'Contains' or 'Traditional' entry is not what this consumes. ImmyBot does
    ship Convert-DetectionStringToRegex for bridging the modes, but the shipped
    uninstall script does not call it -- it requires the entry be in RegEx mode
    -- and this script follows that rather than inventing a different contract.

    The SAAZOD agent's DisplayName is 'SaazOnDemand' (confirmed from discovery
    output), so the Search Filter should be:  SaazOnDemand|ITSPlatform

    Two values are supplied by ImmyBot and must NOT be declared in a param()
    block here (see the note below the help):

      $DetectionString    Regex used by Detect-Software to find the software
                          entries to uninstall. Configured in the software
                          entry's Uninstallation section.
      $UninstallPassword  Optional. Set if the MSI was installed with an
                          uninstall password.

.NOTES
    Beta fix: $UninstallLog is initialised before the loop. It used to be
    assigned only inside the unins000.exe branch, while the Invoke-ImmyCommand
    block referenced $using:UninstallLog unconditionally — so on the msiexec
    path (which is the actual ITSPlatform path) the variable was never defined
    and $using: had nothing to bind to. The uninstall itself had already
    succeeded by then, making it look like a mystery post-uninstall failure.

    Worth knowing: ImmyBot's shipped script has this same latent bug — it
    assigns $UninstallLog only in the unins000 branch and references
    $using:UninstallLog unconditionally. It goes unnoticed there because the
    products it is usually pointed at take the unins000 path. ITSPlatform takes
    the msiexec path, which is why it surfaced here. The fix is ours, not a
    divergence to reconcile back.
#>

# NO param() BLOCK. ImmyBot injects $DetectionString and $UninstallPassword into
# this slot itself, so declaring them here raises a PARSE error before a single
# line executes:
#
#     Duplicate parameter $DetectionString in parameter list.
#
# ImmyBot then reports "Cannot attempt to uninstall using the latest version's
# uninstall script because it is not present" — the script is present, it just
# never compiled. Both values are read below as ambient variables.
#
# If a future ImmyBot build stops supplying them, the guard below fails loudly
# with a clear message rather than silently uninstalling nothing.

# EXECUTION CONTEXT GUARD. This script must run as METASCRIPT. Detect-Software,
# Remove-SoftwareRegKey and Invoke-ImmyCommand exist only there -- a script left
# in the System/User context runs ON the endpoint, where none of them are
# defined. The symptom is a pile of "The term 'X' is not recognized" errors,
# zero matched products, and an uninstall that reports failure while never
# having touched the machine. Set Execution Context to Metascript in the script
# editor; it is not something this file can change about itself.
$missing = @()
foreach ($cmd in 'Invoke-ImmyCommand', 'Detect-Software', 'Remove-SoftwareRegKey') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { $missing += $cmd }
}

if ($missing.Count -gt 0) {
    throw "Wrong execution context: $($missing -join ', ') $(if ($missing.Count -eq 1) { 'is' } else { 'are' }) not available here. This script requires ImmyBot's METASCRIPT context. Open the script in ImmyBot and set Execution Context to Metascript, then re-run."
}

if ($null -eq $DetectionString -or $DetectionString -eq "") {
    throw "`$DetectionString is null or empty, this script requires a valid Regular Expression Detection String"
}

$Softwares = @(Detect-Software -RegExSoftwareSearchString $DetectionString)

Write-Host "Detect-Software matched $($Softwares.Count) product(s) for detection string '$DetectionString'."

# Discovery logging. A zero-match run used to be silent: the loop simply did not
# execute and the log showed nothing between the detection string and the
# cleanup. The DisplayName is the one thing that has to be right here, and it is
# not knowable from ImmyBot's side, so dump the candidates from the endpoint's
# own uninstall keys rather than making someone RDP in to look.
if ($Softwares.Count -eq 0) {
    Write-Warning "No installed product matched '$DetectionString'. Detect-Software takes a REGEX -- check the software entry's Search Mode is set to 'Regex' and not 'Contains' or 'Traditional'. ImmyBot's own shipped uninstall script carries the same requirement in its name."
    Write-Warning "Enumerating candidate products on the endpoint:"

    Invoke-ImmyCommand {
        $keys = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )

        $all = @(Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName })
        Write-Host "  $($all.Count) installed product(s) found on this endpoint."

        $candidates = @($all | Where-Object { $_.DisplayName -match 'saaz|itsplatform|its agent|connectwise|continuum|command' })

        if ($candidates.Count -eq 0) {
            Write-Host "  No product name matched saaz/itsplatform/connectwise/continuum/command."
        } else {
            foreach ($c in $candidates) {
                Write-Host "  CANDIDATE DisplayName: '$($c.DisplayName)'"
                Write-Host "                 Uninstall: $($c.UninstallString)"
            }
        }
    }
}

$attempted = $false

foreach ($Software in $Softwares) {
        $attempted = $true

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
#
# Gated on an uninstall actually having been attempted. Unconditionally it is
# destructive in the one case where it must not run: if the detection string
# matched nothing, the MSI is still registered in Add/Remove Programs, and
# ripping out the service and registry keys anyway leaves the agent in a state
# that is worse than either installed or removed -- ARP still lists it, but
# nothing can uninstall or re-register it.
if (-not $attempted) {
    Write-Warning "Skipping residual service/registry cleanup: no product was matched, so there was no uninstall to clean up after. Fix the detection string and re-run."
    return
}

Invoke-ImmyCommand {
    # Discovered by name rather than from a fixed list. The product spans two
    # naming generations -- ITSPlatform (ConnectWise Platform) and SAAZOD /
    # SaazOnDemand (the ITSupport247 lineage, DisplayName 'SaazOnDemand',
    # installed under C:\Program Files (x86)\SAAZOD) -- and earlier versions of
    # this cleanup only knew about the first. That left the whole SAAZOD half
    # behind on every uninstall.
    $found = @(Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '(?i)itsplatform|saaz' })

    if ($found.Count -eq 0) {
        Write-Host "No ITSPlatform or SAAZ services remain."
    } else {
        Write-Host "Residual services to remove: $(($found | ForEach-Object { $_.Name }) -join ', ')"
    }

    foreach ($s in $found) {
        $svc = $s.Name
        try {
            if ($s.Status -ne 'Stopped') { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue }
            sc.exe delete $svc | Out-Null
            Write-Host "Removed service: $svc"
        } catch {
            Write-Warning "Could not remove service ${svc}: $_"
        }
    }

    # SAAZOD carries SITEID / MEMBERID / REGID from the ORIGINAL registration.
    # Leaving it behind is not cosmetic: a reinstall can find that state and
    # either no-op or re-register against the old tenant.
    $regKeys = @(
        'HKLM:\SOFTWARE\WOW6432Node\ITSPlatform',
        'HKLM:\SOFTWARE\ITSPlatform',
        'HKLM:\SOFTWARE\WOW6432Node\SAAZOD',
        'HKLM:\SOFTWARE\SAAZOD'
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

    # The install directory outlives the MSI too. Reported rather than silently
    # deleted so the log shows what was actually still on disk.
    $dirs = @(
        (Join-Path ${env:ProgramFiles(x86)} 'SAAZOD'),
        (Join-Path $env:ProgramFiles 'SAAZOD'),
        (Join-Path ${env:ProgramFiles(x86)} 'ITSPlatform'),
        (Join-Path $env:ProgramFiles 'ITSPlatform')
    )
    foreach ($d in $dirs) {
        if ($d -and (Test-Path -LiteralPath $d)) {
            Write-Host "Residual directory: $d"
            try {
                Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction Stop
                Write-Host "Removed directory: $d"
            } catch {
                Write-Warning "Could not remove ${d}: $_ -- a reinstall may no-op while this remains."
            }
        }
    }
}