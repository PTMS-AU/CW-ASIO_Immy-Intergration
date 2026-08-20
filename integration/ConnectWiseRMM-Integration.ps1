<#
.SYNOPSIS
    ImmyBot Dynamic Integration for ConnectWise Platform.  [v2.0.0-beta.2]

.DESCRIPTION
    Beta line. The known-good, in-production version is the `alpha` branch —
    keep that deployed while this is under test, and paste this into a SECOND
    Dynamic Integration.

    REQUIRES the CWPlatformAPI module. Paste integration/CWPlatformAPI.psm1 into
    ImmyBot as a Module named exactly "CWPlatformAPI" BEFORE initialising this
    integration, or every capability fails with "The term 'Connect-CwPlatformApi'
    is not recognized".

    Each capability block opens with Import-Module because ImmyBot serialises
    them independently — this is the same pattern the shipped DattoRMM and
    NinjaRMM integrations use.

    Config lives in the module (Get-CwConfigTable), not here.

    Credentials (ConnectWise Platform > Integrations > API Access > Generate):
      - API Endpoint URL (AU = https://openapi.service.auplatform.connectwise.com)
      - Client ID
      - Client Secret
#>

$Integration = New-DynamicIntegration -Init {
    [OutputType([OpResult])]
    param(
        [Parameter(Position = 0, Mandatory = $true)]
        [Uri]$ApiEndpoint,

        [Parameter(Position = 1, Mandatory = $true)]
        [string]$ClientId,

        [Parameter(Position = 2, Mandatory = $true)]
        [Password(StripValue = $true)]
        $ClientSecret
    )

    $IntegrationContext.ApiEndpoint = $ApiEndpoint.ToString().TrimEnd('/')
    $IntegrationContext.ClientId    = "$ClientId"

    # Coerce the [Password] wrapper to a plain string BEFORE storing it. With
    # StripValue=$true the value usually arrives usable, but round-tripping the
    # wrapper object through $IntegrationContext and re-interpolating it in each
    # capability block has been observed to yield a plausible-looking but WRONG
    # value (the 401 "token malformed/invalid" failure the v1 module documents).
    # Forcing [string] here, once, removes that whole failure class.
    $secretPlain = "$ClientSecret"
    if ([string]::IsNullOrWhiteSpace($secretPlain) -or
        $secretPlain -match '^\*+$' -or
        $secretPlain -like '*System.*' -or
        $secretPlain -like '*Password*') {
        # Direct interpolation looked masked — try the wrapper's common members.
        foreach ($m in 'Value','Password','PlainText','SecretValue') {
            $p = $ClientSecret.PSObject.Properties[$m]
            if ($p -and $p.Value) { $secretPlain = "$($p.Value)"; break }
        }
    }
    $IntegrationContext.ClientSecret = $secretPlain
    $IntegrationContext.TokenCache   = @{}

    Import-Module CWPlatformAPI
    $null = Connect-CwPlatformApi

    Write-Host "ConnectWise Platform integration initialised against $($IntegrationContext.ApiEndpoint)"

    [OpResult]::Ok()

} -HealthCheck {
    [CmdletBinding()]
    [OutputType([HealthCheckResult])]
    param()

    try {
        Import-Module CWPlatformAPI
    }
    catch {
        return New-UnhealthyResult -Message "The CWPlatformAPI module is not available. Paste integration/CWPlatformAPI.psm1 into ImmyBot as a Module named 'CWPlatformAPI', then re-initialise. ($($_.Exception.Message))"
    }

    try {
        $null = Connect-CwPlatformApi

        # A token can issue successfully yet still lack read access, so exercise
        # one real read rather than stopping at "got a token".
        #
        # ONE PAGE, deliberately — not Get-CwCompany. This job runs every
        # minute; paginating the whole partner on each pass would mean a full
        # company sweep every 60 seconds, which is both pointless (page one
        # proves read access just as well) and a rate-limit risk on a large
        # partner. Alpha made a single unpaginated call here for the same reason.
        $probe = Invoke-CwApi -Uri "$($IntegrationContext.ApiEndpoint)/api/platform/v1/company/companies" -TimeoutSec 30

        Write-Host "HealthCheck OK: token minted, $(@($probe.Data).Count) company record(s) readable on the first page."
        return New-HealthyResult
    }
    catch {
        $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        return New-UnhealthyResult -Message "ConnectWise Platform health check failed: $detail"
    }
}

# =====================================================================
# ISupportsListingClients — companies (or company/site pairs) as ImmyBot clients
# =====================================================================
$Integration | Add-DynamicIntegrationCapability -Interface ISupportsListingClients -GetClients {
    [CmdletBinding()]
    [ScriptTimeout(TimeoutSeconds = 300)]
    [OutputType([Immybot.Backend.Domain.Providers.IProviderClientDetails[]])]
    param()

    Import-Module CWPlatformAPI
    $null = Connect-CwPlatformApi

    $siteLevel = [bool](Get-CwConfig -Name 'SiteLevelClients' -Default $false)
    $companies = Get-CwCompany

    Write-Host "GetClients: $(@($companies).Count) company record(s) after pagination. SiteLevelClients=$siteLevel"

    if (-not $siteLevel) {
        foreach ($company in $companies) {
            if (-not $company.id) { continue }

            $name = $company.friendlyName
            if (-not $name) { $name = $company.name }

            New-IntegrationClient -ClientId ([string]$company.id) -ClientName ([string]$name)
        }
        return
    }

    # ---- Site-level mode -------------------------------------------------
    # One ImmyBot client per company/site pair, so a multi-office company maps
    # each office to its own tenant and gets an install token for the RIGHT site
    # instead of GetTenantInstallToken guessing "first site wins".
    #
    # One paginated sweep of all sites rather than /companies/{id}/sites per
    # company — the per-company form is N+1 on every client sync.
    # .Keys -contains rather than .ContainsKey(): ImmyBot runs this in
    # ConstrainedLanguage mode, where a method call on a Hashtable raises
    # "Method invocation is supported only on core types in this language mode".
    $sitesByCompany = @{}
    $allSitesOk     = $true

    try {
        foreach ($site in (Get-CwSite)) {
            if (-not $site.id) { continue }

            $cid = Get-CwSiteCompanyId -Site $site
            if (-not $cid) { continue }

            if ($sitesByCompany.Keys -notcontains $cid) { $sitesByCompany[$cid] = @() }
            $sitesByCompany[$cid] += $site
        }
        Write-Host "GetClients: site index built for $($sitesByCompany.Count) company/companies."
    }
    catch {
        $allSitesOk = $false
        Write-Warning "GetClients: all-sites sweep failed ($($_.Exception.Message)). Falling back to per-company lookups."
    }

    foreach ($company in $companies) {
        if (-not $company.id) { continue }

        $companyId = "$($company.id)"
        $name = $company.friendlyName
        if (-not $name) { $name = $company.name }

        $sites = @()
        if ($allSitesOk) {
            if ($sitesByCompany.Keys -contains $companyId) { $sites = @($sitesByCompany[$companyId]) }
        }
        else {
            try { $sites = @(Get-CwSite -CompanyId $companyId) }
            catch { Write-Warning "GetClients: site lookup failed for '$name' ($companyId): $($_.Exception.Message)" }
        }

        # No sites resolvable — emit the company so the tenant is still mappable
        # rather than disappearing from the list entirely.
        if (@($sites).Count -eq 0) {
            New-IntegrationClient -ClientId ([string]$companyId) -ClientName ([string]$name)
            continue
        }

        foreach ($site in $sites) {
            if (-not $site.id) { continue }

            $siteName = $site.name
            if (-not $siteName) { $siteName = "$($site.id)" }

            New-IntegrationClient `
                -ClientId ([string]"$companyId|$($site.id)") `
                -ClientName ([string]"$name / $siteName")
        }
    }
}

# =====================================================================
# ISupportsListingAgents — endpoints for the mapped companies
# =====================================================================
$Integration | Add-DynamicIntegrationCapability -Interface ISupportsListingAgents -GetAgents {
    [CmdletBinding()]
    [ScriptTimeout(TimeoutSeconds = 300)]
    [OutputType([IProviderAgentDetails[]])]
    param(
        [Parameter()]
        [string[]]$ClientIds = $null
    )

    # FIRST line of output, before anything can fail or return. Alpha returned
    # silently when ImmyBot passed no client ids, which makes "invoked with an
    # empty list" and "never invoked at all" look identical in the audit log —
    # two completely different problems with the same symptom.
    Write-Host "GetAgents invoked. ClientIds received: $(@($ClientIds).Count)"

    if (-not $ClientIds) {
        Write-Warning ("GetAgents received no client ids, so there is nothing to sync. " +
                       "ImmyBot passes the clients that are linked AND enabled for agent import — " +
                       "check the Clients (Tenants) tab: the client needs a Linked Tenant, then " +
                       "'Sync agents for selected clients'.")
        return
    }

    Write-Host "GetAgents client ids: $($ClientIds -join ', ')"

    Import-Module CWPlatformAPI

    # --- DIAGNOSTIC BISECT -------------------------------------------------
    # Emits a synthetic agent and touches no API. Separates "ImmyBot never calls
    # this capability" from "our device path returns nothing" — two problems
    # that look identical from the Agents tab. Runs before Connect so a
    # credential fault cannot muddy the result.
    if ([bool](Get-CwConfig -Name 'DiagnosticEmitTestAgent' -Default $false)) {
        Write-Warning "DIAGNOSTIC MODE ACTIVE — emitting synthetic agents, making no API calls. Set DiagnosticEmitTestAgent back to `$false in CWPlatformAPI when done."

        foreach ($cid in $ClientIds) {
            $ref = Resolve-CwClientRef -ClientRef $cid
            if (-not $ref) { continue }

            New-IntegrationAgent `
                -AgentId ([string]"diagnostic-$($ref.CompanyId)") `
                -Name ([string]"ZZZ-DIAGNOSTIC-$($ref.CompanyId)") `
                -ClientId ([string]$ref.Raw) `
                -SerialNumber '00000000' `
                -OSName 'Diagnostic' `
                -Manufacturer 'Diagnostic' `
                -AgentVersion '0.0.0' `
                -IsOnline $false `
                -SupportsRunningScripts $false

            Write-Host "DIAGNOSTIC: emitted synthetic agent for client $($ref.Raw)"
        }

        return
    }

    $null = Connect-CwPlatformApi

    $discovery = [bool](Get-CwConfig -Name 'VerboseDiscovery' -Default $false)

    # An incoming client id is either a bare company GUID or "<company>|<site>".
    # Resolve once, key everything off company (the device listing only
    # understands companies), and re-attach the original ref when emitting.
    $refsByCompany = @{}
    $siteMode      = $false

    foreach ($cid in $ClientIds) {
        $ref = Resolve-CwClientRef -ClientRef $cid
        if (-not $ref) { continue }

        if ($ref.SiteId) { $siteMode = $true }
        if ($refsByCompany.Keys -notcontains $ref.CompanyId) { $refsByCompany[$ref.CompanyId] = @() }
        $refsByCompany[$ref.CompanyId] += $ref
    }

    $companyIds = @($refsByCompany.Keys)
    if ($companyIds.Count -eq 0) { return }

    Write-Host "GetAgents: $(@($ClientIds).Count) mapped client(s) -> $($companyIds.Count) distinct company/companies. SiteMode=$siteMode"

    $collected = Get-CwEndpoint -CompanyIds $companyIds
    Write-Host "GetAgents: collected $(@($collected).Count) endpoint(s) from device listing."

    if ($discovery -and @($collected).Count -gt 0) {
        Write-Host "DISCOVERY first endpoint object:`n$(@($collected)[0].ep | ConvertTo-Json -Depth 6)"
        Write-Host "DISCOVERY first group wrapper:`n$(@($collected)[0].group | Select-Object -ExcludeProperty endpoints | ConvertTo-Json -Depth 4)"
    }

    $onlineLookup = Get-CwHeartbeatLookup -CompanyIds $companyIds
    $onlineCount  = @($onlineLookup.Keys | Where-Object { $onlineLookup[$_] }).Count
    Write-Host "Heartbeat: lookup contains $($onlineLookup.Count) endpoint(s); $onlineCount online."

    $emitted                = 0
    $unresolvedSite         = 0
    $unparsedVersionExample = $null

    foreach ($item in $collected) {
        $ep = $item.ep

        $endpointId = $ep.endpointID
        if (-not $endpointId) { $endpointId = $ep.endpointId }
        if (-not $endpointId) { $endpointId = $ep.id }
        if (-not $endpointId) { continue }

        $candidateRefs = @()
        if ($refsByCompany.Keys -contains $item.companyID) { $candidateRefs = @($refsByCompany[$item.companyID]) }
        if ($candidateRefs.Count -eq 0) { continue }

        # Company mode: one ref, done. Site mode: pick the ref whose site matches
        # this endpoint. Guessing here would file a machine under the wrong
        # tenant, which is worse than not listing it — so an unresolvable site is
        # counted and reported, never assumed.
        $chosenRef = $candidateRefs[0]

        if ($siteMode -and @($candidateRefs | Where-Object { $_.SiteId }).Count -gt 0) {
            $epSiteId = Get-CwEndpointSiteId -Endpoint $ep -Group $item.group

            if (-not $epSiteId) { $unresolvedSite++; continue }

            $match = @($candidateRefs | Where-Object { $_.SiteId -eq $epSiteId }) | Select-Object -First 1
            if (-not $match) { continue }   # site exists but is not mapped to a tenant
            $chosenRef = $match
        }

        $name = $ep.deviceName
        if (-not $name) { $name = $ep.friendlyName }
        if (-not $name) { $name = $endpointId }

        $serial = $ep.system.serialNumber
        if (-not $serial) { $serial = '00000000' }

        $osName = $ep.os.product
        if (-not $osName) { $osName = $ep.os.type }
        if (-not $osName) { $osName = 'Unknown' }

        $manufacturer = $ep.system.product
        if (-not $manufacturer) { $manufacturer = 'Unknown' }

        $emitted++

        $agentParams = @{
            AgentId                = [string]$endpointId
            Name                   = [string]$name
            ClientId               = [string]$chosenRef.Raw
            SerialNumber           = [string]$serial
            OSName                 = [string]$osName
            Manufacturer           = [string]$manufacturer
            IsOnline               = ($onlineLookup[[string]$endpointId] -eq $true)
            SupportsRunningScripts = $true
        }

        # AgentVersion is typed [Version] by ImmyBot, so a placeholder like
        # 'Unknown' throws "'Unknown' is not a valid version string" — once per
        # agent, which fails the whole sync. The CW device listing does not
        # reliably carry an agent version, so the parameter is only supplied
        # when the value actually parses, and omitted otherwise.
        #
        # Reported for visibility only either way. Detection deliberately still
        # returns a fixed 1.0.0 because the agent self-updates (doc §10.1).
        $agentVersion = $ep.agentVersion
        if (-not $agentVersion) { $agentVersion = $ep.version }

        if ($agentVersion -and "$agentVersion" -match '^\d+(\.\d+){0,3}$') {
            $agentParams.AgentVersion = [string]$agentVersion
        }
        elseif ($agentVersion -and $unparsedVersionExample -eq $null) {
            # Log the first odd value only — one line, not one per agent.
            $unparsedVersionExample = "$agentVersion"
            Write-Host "GetAgents: endpoint version '$agentVersion' is not a parseable version string; omitting AgentVersion for affected agents."
        }

        New-IntegrationAgent @agentParams
    }

    Write-Host "GetAgents: emitted $emitted agent(s)."

    if ($unresolvedSite -gt 0) {
        throw ("GetAgents: SiteLevelClients is on but $unresolvedSite endpoint(s) carried no resolvable site id, so they were not emitted rather than being filed under the wrong tenant. " +
               "Set VerboseDiscovery=`$true in the module and re-run to dump the raw endpoint object, then add the real field name to Get-CwEndpointSiteId.")
    }
}

# =====================================================================
# ISupportsInventoryIdentification — match ImmyBot computers to CW endpoints
# =====================================================================
# The Invoke-ImmyCommand wrapper is load-bearing: returning the raw scriptblock
# hands ImmyBot the AST, which it renders as inventory data instead of executing
# it (doc §9.4).
$Integration | Add-DynamicIntegrationCapability -Interface ISupportsInventoryIdentification -GetInventoryScript {
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param()

    $privateEndpointId = Invoke-ImmyCommand {
        $paths = @(
            'HKLM:\SOFTWARE\WOW6432Node\ITSPlatform',
            'HKLM:\SOFTWARE\ITSPlatform'
        )

        foreach ($path in $paths) {
            if (Test-Path $path) {
                $props = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue

                if ($props.privateendpointid) {
                    return "$($props.privateendpointid)"
                }
            }
        }

        return $null
    }

    if ($privateEndpointId) {
        return "$privateEndpointId".Trim()
    }

    return $null
}

# =====================================================================
# ISupportsTenantInstallToken — per-tenant agent install token
# =====================================================================
$Integration | Add-DynamicIntegrationCapability -Interface ISupportsTenantInstallToken -GetTenantInstallToken {
    [CmdletBinding()]
    [OutputType([System.String])]
    param(
        [Parameter(Position = 0)]
        [string]$ClientId,

        [Parameter()]
        [string]$ProviderClientId
    )

    Import-Module CWPlatformAPI
    $null = Connect-CwPlatformApi

    $mappedRef = $ClientId
    if (-not $mappedRef) { $mappedRef = $ProviderClientId }
    if (-not $mappedRef) {
        throw "GetTenantInstallToken received no mapped client id. Remap the tenant under Integration > Clients."
    }

    $ref       = Resolve-CwClientRef -ClientRef $mappedRef
    $companyId = $ref.CompanyId
    $siteId    = $ref.SiteId

    Write-Host "GetTenantInstallToken: company=$companyId site=$(if ($siteId) { $siteId } else { '(resolve)' })"

    # In site-level mapping the tenant already carries its site, so the whole
    # lookup-and-guess below is skipped — that guess is what lands agents in the
    # wrong office on multi-site companies.
    if (-not $siteId) {
        $preferredSiteName = [string](Get-CwConfig -Name 'PreferredSiteName' -Default '')
        $sites = @(Get-CwSite -CompanyId $companyId)

        Write-Host "Step 1: found $($sites.Count) site(s) for company $companyId"

        if ($sites.Count -eq 0) {
            throw "No sites found for company $companyId. Verify the company exists in ConnectWise Platform and has at least one site."
        }

        $chosenSite = $null

        if ($preferredSiteName) {
            $chosenSite = $sites | Where-Object { $_.name -eq $preferredSiteName } | Select-Object -First 1
            if ($chosenSite) { Write-Host "Step 1: matched preferred site name '$preferredSiteName'" }
        }

        # ConnectWise Platform names a company's default site after the company.
        if (-not $chosenSite -and $sites.Count -gt 1) {
            $companyName = $null
            if ($sites[0].company -and $sites[0].company.name) { $companyName = $sites[0].company.name }

            if ($companyName) {
                $chosenSite = $sites | Where-Object { $_.name -eq $companyName } | Select-Object -First 1
                if ($chosenSite) { Write-Host "Step 1: matched site by company name '$companyName'" }
            }
        }

        if (-not $chosenSite) {
            $chosenSite = $sites[0]
            if ($sites.Count -gt 1) {
                Write-Warning "Step 1: $($sites.Count) sites found for company $companyId and none matched — using '$($chosenSite.name)'. Set PreferredSiteName, or turn on SiteLevelClients to map each site to its own tenant."
            }
        }

        $siteId = $chosenSite.id
        Write-Host "Step 1 OK: selected site '$($chosenSite.name)' ($siteId)"
    }

    if (-not $siteId) { throw "Step 1 ended with no siteId for company $companyId" }

    $token = New-CwInstallToken -CompanyId $companyId -SiteId $siteId
    Write-Host "Step 2 OK: returning install token for site $siteId"

    return $token
}

# =====================================================================
# IRunScriptProvider — run a script on a ConnectWise Platform endpoint
# =====================================================================
$Integration | Add-DynamicIntegrationCapability -Interface IRunScriptProvider -RunScript {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [IProviderAgentDetails]$agent,

        [Parameter(Mandatory)]
        [string]$scriptCode,

        [Parameter(Mandatory)]
        [ScriptLanguage]$scriptLanguage,

        [Parameter(Mandatory)]
        [int]$timeout,

        [Parameter(Mandatory)]
        [string]$scriptPath
    )

    Import-Module CWPlatformAPI
    $null = Connect-CwPlatformApi -IncludeWrite

    # ExternalAgentId = the GUID emitted as -AgentId in GetAgents = endpoint GUID
    # in the MANAGED_ENDPOINT space (same id the heartbeat keys on).
    $targetEndpointId = "$($agent.ExternalAgentId)"
    if ([string]::IsNullOrWhiteSpace($targetEndpointId)) {
        throw "RunScript: agent.ExternalAgentId was empty; cannot target the ConnectWise Platform endpoint."
    }

    $taskId = Invoke-CwScriptTask -EndpointId $targetEndpointId -ScriptCode $scriptCode -TimeoutSec $timeout

    if (-not [bool](Get-CwConfig -Name 'RunScriptPollForResult' -Default $false)) {
        # Alpha's behaviour, and the right default for ImmyBot's own use of this
        # capability: the 201 means ACCEPTED, and ImmyBot's bootstrap connects
        # back out-of-band, so there is nothing to wait for.
        return $taskId
    }

    $output = Wait-CwScriptTask -TaskId $taskId -TimeoutSec $timeout
    if ($null -eq $output) { return $taskId }
    return $output

} -get_DefaultTimeout { 600 }

# =====================================================================
# ISupportsExternalProviderAgentUrl — deep link to the endpoint in CW
# =====================================================================
# Off until the console URL shape is confirmed (BETA-NOTES probe J). Returning a
# wrong URL is worse than returning none — it sends techs to a 404 mid-incident.
$Integration | Add-DynamicIntegrationCapability -Interface ISupportsExternalProviderAgentUrl -GetExternalProviderAgentUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [IProviderAgentDetails]$device
    )

    Import-Module CWPlatformAPI

    $template = [string](Get-CwConfig -Name 'ConsoleUrlTemplate' -Default '')
    if (-not $template) { return $null }

    return ($template -replace '\{endpointId\}', "$($device.ExternalAgentId)")
}

# =====================================================================
# ISupportsHttpRequest — inbound webhook receiver
# =====================================================================
# Responds at plugins/api/v1/{providerLinkId}.
#
# Deliberately inert: it logs and returns 200. ConnectWise Platform's webhook
# payload shape is unconfirmed, so this exists to CAPTURE one (BETA-NOTES probe
# H) rather than to act on it. Wire actions only once a real event is in hand.
$Integration | Add-DynamicIntegrationCapability -Interface ISupportsHttpRequest -HandleHttpRequest {
    [CmdletBinding()]
    [OutputType([Microsoft.AspNetCore.Mvc.IActionResult])]
    param(
        [Parameter(Mandatory = $True)]
        [Microsoft.AspNetCore.Http.HttpContext]$httpContext,

        [Parameter(Mandatory = $false)]
        $body,

        [Parameter(Mandatory = $True)]
        $route
    )

    Write-Host "CW Platform webhook received. route=$route method=$($httpContext.Request.Method)"

    if ($null -ne $body) {
        Write-Host "Payload:`n$($body | ConvertTo-Json -Depth 8)"
    } else {
        Write-Host "Payload: (empty body)"
    }

    $res = [ObjectResult]::new('ok')
    $res.StatusCode = 200
    return $res
}

$Integration
