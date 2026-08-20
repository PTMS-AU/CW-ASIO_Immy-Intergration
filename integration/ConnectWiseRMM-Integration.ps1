<#
.SYNOPSIS
    ImmyBot Dynamic Integration for ConnectWise Platform.  [v2.0.0-beta]

.DESCRIPTION
    Beta line. The known-good, in-production version is the `alpha` branch — keep
    that one deployed while this is under test. Paste this script into a SECOND
    Dynamic Integration in ImmyBot so alpha keeps running untouched.

    Auth is unchanged from alpha and still the proven flow: OAuth2
    client_credentials at POST /v1/token (JSON body) -> Bearer access_token.

    What changed in beta (see docs/BETA-NOTES.md for the test plan):
      - Shared helpers (token cache + retry/backoff + pagination) instead of the
        same token block copy-pasted into every capability.
      - GetClients now follows Link: rel="next" pagination.
      - GetAgents fails loudly on a partial sync instead of silently emitting a
        truncated fleet.
      - Optional site-level client mapping.
      - Optional RunScript result polling.
      - Optional webhook receiver.

    Every new behaviour is flag-gated and defaults to alpha's behaviour, so a
    fresh paste of this file should behave exactly like alpha until you turn
    something on.

    Credentials (ConnectWise Platform > Integrations > API Access > Generate):
      - API Endpoint URL (regional gateway; AU = https://openapi.service.auplatform.connectwise.com)
      - Client ID
      - Client Secret
#>

# =====================================================================
# LOAD-TIME FLAGS
# ---------------------------------------------------------------------
# These are read when ImmyBot parses the file, so they can gate whether a
# capability is REGISTERED at all. Runtime behaviour flags live in the $Config
# block inside -Init instead (this scope is not visible from capability blocks).
#
# Leave this $false until the ISupportsHttpRequest contract is confirmed against
# your ImmyBot build — see docs/BETA-NOTES.md, test 6.
# =====================================================================
$BetaEnableWebhookCapability = $false

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

    # =================================================================
    # BETA CONFIG — runtime behaviour. Edit here, re-save, re-initialise.
    # These reach every capability block via $IntegrationContext, which is the
    # only channel that crosses the block boundary.
    # =================================================================
    $Config = @{
        # --- Proven in alpha, safe to leave as-is ---
        EnableHeartbeat          = $true    # online status via the heartbeat endpoint
        ClientBatchSize          = 4        # company ids per call (heartbeat caps at 4)
        DeviceFieldSelector      = 'system,os'

        # The heartbeat resourceType is VOLATILE — it has changed twice on us:
        #   endpoints -> 403 Forbidden on this AU partner key (still true)
        #   clients   -> worked, now returns HTTP 400 "Invalid Resource Type"
        #   companies -> current working value
        # It lives here rather than buried in a literal so the next change is a
        # config edit, not a code hunt. Do NOT set this back to 'endpoints'.
        HeartbeatResourceType    = 'companies'

        # --- New in beta, behaviour-changing ---
        # $true = a failed device-listing batch throws instead of quietly
        # emitting a partial fleet. Alpha's behaviour was a silent partial.
        FailSyncOnPartialResults = $true

        # --- New in beta, OFF by default ---
        # Map ImmyBot tenants to company+site instead of company. Changing this
        # invalidates existing tenant mappings — you must re-map under
        # Integration > Clients. See docs/BETA-NOTES.md, test 4.
        SiteLevelClients         = $false
        PreferredSiteName        = ''       # company mode only: force a site by name

        # RunScript result polling. Alpha is fire-and-forget (returns taskId).
        # The result URI is UNVERIFIED — it is a template here precisely so you
        # can correct it in situ without editing logic. See BETA-NOTES.md test 5.
        RunScriptPollForResult     = $false
        RunScriptResultUriTemplate = '/api/platform/v2/automation/endpoints/schedule-tasks/{taskId}'
        RunScriptPollIntervalSec   = 10

        # Logs the raw shape of responses we have not confirmed (task results,
        # endpoint site ids, webhook payloads). Turn on while testing, off after.
        VerboseDiscovery           = $false
    }

    $IntegrationContext.ApiEndpoint = $ApiEndpoint.ToString().TrimEnd('/')
    $IntegrationContext.ClientId    = "$ClientId"
    $IntegrationContext.Config      = $Config

    # One scope string, defined once. Alpha repeated this literal in five places
    # and they had already drifted (RunScript's carried two extra scopes).
    $IntegrationContext.ScopeRead  = 'platform.companies.read platform.sites.read platform.devices.read platform.agent-token.read platform.asset.read platform.agent.read'
    $IntegrationContext.ScopeWrite = "$($IntegrationContext.ScopeRead) platform.automation.read platform.automation.create"

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

    # =================================================================
    # SHARED HELPERS
    # -----------------------------------------------------------------
    # ImmyBot serialises each capability scriptblock independently, so a
    # function defined at file scope is NOT visible inside them — which is why
    # alpha inlined the same token block five times. Instead we stash the helper
    # SOURCE here and each block dot-sources it into its own scope. One
    # definition, still no cross-block dependency at runtime.
    #
    # Consequence: PSScriptAnalyzer sees this as a string. CI extracts and lints
    # it separately (.github/workflows/validate.yml).
    # =================================================================
    $IntegrationContext.HelperSource = @'
$script:CwTokenCache = @{}

function Get-CwConfig {
    # $IntegrationContext round-trips the config as either a Hashtable or a
    # deserialised PSObject depending on the ImmyBot build. Read both shapes.
    param([Parameter(Mandatory)][string]$Name, $Default = $null)

    $cfg = $IntegrationContext.Config
    if (-not $cfg) { return $Default }

    $val = $null
    try { $val = $cfg[$Name] } catch { Write-Debug "Config index lookup failed for $Name" }
    if ($null -eq $val) {
        try { $val = $cfg.$Name } catch { Write-Debug "Config property lookup failed for $Name" }
    }
    if ($null -eq $val) { return $Default }
    return $val
}

function Get-CwToken {
    param([switch]$IncludeWrite, [switch]$ForceRefresh)

    $scope = if ($IncludeWrite) { $IntegrationContext.ScopeWrite } else { $IntegrationContext.ScopeRead }
    if ([string]::IsNullOrWhiteSpace($scope)) {
        throw "Get-CwToken: no scope string on IntegrationContext. Re-initialise the integration (Integrations > your integration > Initialize)."
    }

    if ($null -eq $script:CwTokenCache) { $script:CwTokenCache = @{} }

    $cached = $script:CwTokenCache[$scope]
    if (-not $ForceRefresh -and $cached -and $cached.Expires -gt (Get-Date)) {
        return $cached.Token
    }

    $body = @{
        grant_type    = 'client_credentials'
        client_id     = $IntegrationContext.ClientId
        client_secret = "$($IntegrationContext.ClientSecret)"
        scope         = $scope
    } | ConvertTo-Json -Depth 5

    $resp = Invoke-RestMethod -Uri "$($IntegrationContext.ApiEndpoint)/v1/token" -Method Post `
        -Body $body -ContentType 'application/json' -TimeoutSec 30 -ErrorAction Stop

    if (-not $resp.access_token) {
        throw "Token endpoint returned no access_token."
    }

    # Refresh at 80% of stated lifetime. A full GetAgents run over a large
    # partner can outlive a token, and alpha had no refresh path at all — it
    # minted once and rode it through every batch and every pagination hop.
    $lifetime = 3600
    if ($resp.expires_in) { $lifetime = [int]$resp.expires_in }

    $script:CwTokenCache[$scope] = @{
        Token   = $resp.access_token
        Expires = (Get-Date).AddSeconds([Math]::Max(60, [int]($lifetime * 0.8)))
    }

    return $resp.access_token
}

function Get-CwNextLink {
    param($Headers)

    if (-not $Headers) { return $null }

    $link = $null
    try { $link = $Headers.Link } catch { Write-Debug "No .Link member on response headers" }
    if (-not $link) {
        try { $link = $Headers['Link'] } catch { Write-Debug "No ['Link'] key on response headers" }
    }
    if (-not $link) { return $null }

    $value = if ($link -is [array]) { $link -join ',' } else { "$link" }
    if ($value -match '<([^>]+)>\s*;\s*rel="?next"?') { return $Matches[1] }
    return $null
}

function Invoke-CwApi {
    <#
        Single HTTP path for every capability: bearer injection, one 401 re-mint,
        exponential backoff on 429/5xx, and the Link header parsed out for the
        caller. Returns .Data / .Headers / .NextLink.
    #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'Get',
        $Body,
        [switch]$IncludeWrite,
        [int]$TimeoutSec = 60,
        [int]$MaxAttempts = 4
    )

    $attempt   = 0
    $refreshed = $false

    while ($true) {
        $attempt++

        $headers = @{
            Authorization  = "Bearer $(Get-CwToken -IncludeWrite:$IncludeWrite)"
            Accept         = 'application/json'
            'Content-Type' = 'application/json'
        }

        $respHeaders = $null

        try {
            $params = @{
                Uri                     = $Uri
                Headers                 = $headers
                Method                  = $Method
                TimeoutSec              = $TimeoutSec
                ResponseHeadersVariable = 'respHeaders'
                ErrorAction             = 'Stop'
            }
            if ($null -ne $Body) { $params.Body = $Body }

            $data = Invoke-RestMethod @params

            return [pscustomobject]@{
                Data     = $data
                Headers  = $respHeaders
                NextLink = Get-CwNextLink -Headers $respHeaders
            }
        }
        catch {
            $status = 0
            try { $status = [int]$_.Exception.Response.StatusCode } catch { $status = 0 }

            $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                $_.ErrorDetails.Message
            } else {
                $_.Exception.Message
            }

            # A 401 partway through a run is almost always an expired token
            # rather than bad credentials. Re-mint once; a second 401 is real.
            if ($status -eq 401 -and -not $refreshed) {
                $refreshed = $true
                Write-Host "CW API: 401 on $Method $Uri — re-minting token and retrying once."
                $null = Get-CwToken -IncludeWrite:$IncludeWrite -ForceRefresh
                continue
            }

            $retryable = ($status -eq 429 -or $status -ge 500 -or $status -eq 0)
            if (-not $retryable -or $attempt -ge $MaxAttempts) {
                throw "CW API $Method $Uri failed (HTTP $status): $detail"
            }

            $delay = [int][Math]::Pow(2, $attempt)

            $retryAfterSec = 0
            try {
                $ra = $_.Exception.Response.Headers.RetryAfter
                if ($ra -and $ra.Delta) { $retryAfterSec = [int]$ra.Delta.TotalSeconds }
            } catch { Write-Debug "No parseable Retry-After header" }
            if ($retryAfterSec -gt 0) { $delay = $retryAfterSec }

            Write-Host "CW API: HTTP $status on $Method $Uri — retry $attempt/$MaxAttempts in ${delay}s."
            Start-Sleep -Seconds $delay
        }
    }
}

function Resolve-CwClientRef {
    <#
        Site-level client ids are emitted as "<companyId>|<siteId>"; company-level
        ids are the bare company GUID. Both shapes have to survive a round trip
        through ImmyBot's tenant mapping, so parsing lives in one place.
    #>
    param([string]$ClientRef)

    if ([string]::IsNullOrWhiteSpace($ClientRef)) { return $null }

    $parts = "$ClientRef".Split('|')

    return [pscustomobject]@{
        Raw       = "$ClientRef"
        CompanyId = $parts[0]
        SiteId    = $(if ($parts.Count -gt 1 -and $parts[1]) { $parts[1] } else { $null })
    }
}

function Get-CwEndpointSiteId {
    # The device listing's site field name is not confirmed. Try the plausible
    # shapes and let the caller decide what to do when none of them hit.
    param($Endpoint, $Group)

    foreach ($candidate in @(
        $Endpoint.siteID, $Endpoint.siteId, $Endpoint.site.id, $Endpoint.siteid,
        $Group.siteID,    $Group.siteId
    )) {
        if ($candidate) { return "$candidate" }
    }
    return $null
}

function Get-CwBatch {
    param([string[]]$Items, [int]$Size = 4)

    $batches = @()
    $current = @()

    foreach ($item in $Items) {
        if (-not $item) { continue }
        $current += [string]$item
        if ($current.Count -eq $Size) {
            $batches += ,$current
            $current = @()
        }
    }
    if ($current.Count -gt 0) { $batches += ,$current }

    return ,$batches
}
'@

    [OpResult]::Ok()

} -HealthCheck {
    [CmdletBinding()]
    [OutputType([HealthCheckResult])]
    param()

    try {
        if (-not $IntegrationContext.HelperSource) {
            return New-UnhealthyResult -Message "Integration context is missing HelperSource — this build of ImmyBot may not round-trip added context properties. Re-initialise; if it persists, see docs/BETA-NOTES.md test 1."
        }

        . ([scriptblock]::Create($IntegrationContext.HelperSource))

        # Health check earns its keep by exercising the things that actually
        # break: helper dot-sourcing (beta's one structural change), the token
        # exchange, and one real read. A token can issue fine and still lack
        # read access, so "got a token" alone is not a pass.
        $probe = Invoke-CwApi -Uri "$($IntegrationContext.ApiEndpoint)/api/platform/v1/company/companies" -TimeoutSec 30

        $count = @($probe.Data).Count
        Write-Host "HealthCheck OK: helpers loaded, token minted, $count company record(s) readable."

        return New-HealthyResult
    }
    catch {
        $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        return New-UnhealthyResult -Message "ConnectWise Platform health check failed: $detail"
    }
}

# =====================================================================
# ISupportsListingClients — list ConnectWise Platform companies as ImmyBot clients
# =====================================================================
$Integration | Add-DynamicIntegrationCapability -Interface ISupportsListingClients -GetClients {
    [CmdletBinding()]
    [OutputType([IProviderClientDetails[]])]
    param()

    . ([scriptblock]::Create($IntegrationContext.HelperSource))

    $baseUri   = $IntegrationContext.ApiEndpoint
    $siteLevel = [bool](Get-CwConfig -Name 'SiteLevelClients' -Default $false)

    # Alpha called /company/companies exactly once and emitted whatever came
    # back. The device listing in the same API family pages at 500 via
    # Link: rel="next", so a partner over that limit was silently losing
    # companies — and a company that never appears simply cannot be mapped to a
    # tenant, which looks like an ImmyBot problem rather than a paging one.
    $companies = @()
    $nextUri   = "$baseUri/api/platform/v1/company/companies"

    while ($nextUri) {
        $page = Invoke-CwApi -Uri $nextUri -TimeoutSec 30
        $companies += @($page.Data)
        $nextUri = $page.NextLink
    }

    Write-Host "GetClients: $($companies.Count) company record(s) after pagination. SiteLevelClients=$siteLevel"

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
    # One ImmyBot client per company/site pair, so a multi-office company can map
    # each office to its own tenant and get an install token for the RIGHT site
    # instead of GetTenantInstallToken's "first site wins" guess.
    #
    # Pull every site in one paginated sweep rather than /companies/{id}/sites
    # per company — the per-company form is N+1 and would mean one API call per
    # company on every client sync.
    $sitesByCompany = @{}
    $allSitesOk     = $true

    try {
        $nextUri = "$baseUri/api/platform/v1/company/sites"
        while ($nextUri) {
            $page = Invoke-CwApi -Uri $nextUri -TimeoutSec 60
            foreach ($site in @($page.Data)) {
                if (-not $site.id) { continue }

                $cid = $null
                if ($site.company -and $site.company.id) { $cid = "$($site.company.id)" }
                elseif ($site.companyID)                 { $cid = "$($site.companyID)" }
                elseif ($site.clientID)                  { $cid = "$($site.clientID)" }
                if (-not $cid) { continue }

                if (-not $sitesByCompany.ContainsKey($cid)) { $sitesByCompany[$cid] = @() }
                $sitesByCompany[$cid] += $site
            }
            $nextUri = $page.NextLink
        }
        Write-Host "GetClients: site index built for $($sitesByCompany.Count) company/companies."
    }
    catch {
        $allSitesOk = $false
        Write-Warning "GetClients: all-sites sweep failed ($($_.Exception.Message)). Falling back to per-company site lookups."
    }

    foreach ($company in $companies) {
        if (-not $company.id) { continue }

        $companyId = "$($company.id)"
        $name = $company.friendlyName
        if (-not $name) { $name = $company.name }

        $sites = @()
        if ($allSitesOk) {
            if ($sitesByCompany.ContainsKey($companyId)) { $sites = @($sitesByCompany[$companyId]) }
        }
        else {
            try {
                $siteResp = Invoke-CwApi -Uri "$baseUri/api/platform/v1/company/companies/$companyId/sites" -TimeoutSec 30
                $sites = @($siteResp.Data)
            }
            catch {
                Write-Warning "GetClients: site lookup failed for '$name' ($companyId): $($_.Exception.Message)"
            }
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
# ISupportsListingAgents — list devices (endpoints) for the mapped companies
# =====================================================================
$Integration | Add-DynamicIntegrationCapability -Interface ISupportsListingAgents -GetAgents {
    [CmdletBinding()]
    [OutputType([IProviderAgentDetails[]])]
    param(
        [Parameter()]
        [string[]]$ClientIds = $null
    )

    if (-not $ClientIds) { return }

    . ([scriptblock]::Create($IntegrationContext.HelperSource))

    $baseUri       = $IntegrationContext.ApiEndpoint
    $batchSize     = [int](Get-CwConfig -Name 'ClientBatchSize'          -Default 4)
    $fieldSelector = [string](Get-CwConfig -Name 'DeviceFieldSelector'   -Default 'system,os')
    $failOnPartial = [bool](Get-CwConfig -Name 'FailSyncOnPartialResults' -Default $true)
    $hbEnabled     = [bool](Get-CwConfig -Name 'EnableHeartbeat'          -Default $true)
    $hbResourceTyp = [string](Get-CwConfig -Name 'HeartbeatResourceType'  -Default 'companies')
    $discovery     = [bool](Get-CwConfig -Name 'VerboseDiscovery'         -Default $false)

    # An incoming client id is either a bare company GUID or "<company>|<site>".
    # Resolve once, then key everything off company (the device listing only
    # understands companies) and re-attach the original ref when emitting.
    $refs           = @()
    $refsByCompany  = @{}

    foreach ($cid in $ClientIds) {
        $ref = Resolve-CwClientRef -ClientRef $cid
        if (-not $ref) { continue }

        $refs += $ref
        if (-not $refsByCompany.ContainsKey($ref.CompanyId)) { $refsByCompany[$ref.CompanyId] = @() }
        $refsByCompany[$ref.CompanyId] += $ref
    }

    if ($refs.Count -eq 0) { return }

    $siteMode = @($refs | Where-Object { $_.SiteId }).Count -gt 0
    $companyIds = @($refsByCompany.Keys)

    Write-Host "GetAgents: $($ClientIds.Count) mapped client(s) -> $($companyIds.Count) distinct company/companies. SiteMode=$siteMode"

    $batches = Get-CwBatch -Items $companyIds -Size $batchSize
    $uri     = "$baseUri/api/platform/v2/device/categories/platform/endpoints?field=$fieldSelector&limit=500"

    # --- PASS 1: collect endpoint inventory ---
    $collected      = @()
    $diag           = @()
    $failedBatches  = @()

    foreach ($batch in $batches) {
        # The OpenAPI spec declares POST here; the live AU tenant requires
        # GET-with-body. Do NOT "fix" this to POST.
        $body = @{
            resourceType = "company"
            resources    = @($batch)
        } | ConvertTo-Json -Depth 5

        $nextUri = $uri

        while ($nextUri) {
            try {
                $page = Invoke-CwApi -Uri $nextUri -Method Get -Body $body -TimeoutSec 60
            }
            catch {
                # Alpha did `break` here and then emitted whatever it had, so one
                # 429 or 502 mid-sweep silently truncated the fleet and ImmyBot
                # saw agents disappear. Record the batch and decide at the end.
                $failedBatches += ,$batch
                $diag += "DEVICE listing failed for companies [$($batch -join ',')]: $($_.Exception.Message)"
                break
            }

            foreach ($group in @($page.Data.platform)) {
                if (-not $group) { continue }

                foreach ($ep in @($group.endpoints)) {
                    if (-not $ep) { continue }

                    $collected += @{
                        ep        = $ep
                        group     = $group
                        companyID = "$($group.companyID)"
                    }
                }
            }

            $nextUri = $page.NextLink
        }
    }

    Write-Host "GetAgents: collected $($collected.Count) endpoint(s) from device listing."

    if ($discovery -and $collected.Count -gt 0) {
        Write-Host "DISCOVERY first endpoint object:`n$(@($collected)[0].ep | ConvertTo-Json -Depth 6)"
        Write-Host "DISCOVERY first group wrapper:`n$(@($collected)[0].group | Select-Object -ExcludeProperty endpoints | ConvertTo-Json -Depth 4)"
    }

    if ($failedBatches.Count -gt 0 -and $failOnPartial) {
        throw ("GetAgents aborted: $($failedBatches.Count) of $($batches.Count) device-listing batch(es) failed, so the endpoint list is incomplete. " +
               "Emitting a partial fleet would make ImmyBot prune healthy agents. Details:`n" + ($diag -join "`n"))
    }

    # --- PASS 2: online status via heartbeat ---
    # resourceType is config-driven — see the HeartbeatResourceType note in Init.
    # The cap is 4 ids per call, which is why it reuses the PASS 1 batches.
    $onlineLookup = @{}

    if ($hbEnabled -and $batches.Count -gt 0) {
        foreach ($batch in $batches) {
            $hbUri = "$baseUri/api/platform/v2/device/endpoints/heartbeat?resourceType=$hbResourceTyp&resources=$($batch -join ',')"

            try {
                $hb = (Invoke-CwApi -Uri $hbUri -TimeoutSec 60).Data

                foreach ($rec in @($hb.successfulRecords)) {
                    foreach ($hbEp in @($rec.endpoints)) {
                        $hbId = $hbEp.EndpointID
                        if (-not $hbId) { $hbId = $hbEp.endpointID }
                        if (-not $hbId) { continue }

                        $avail = $hbEp.Availability
                        if ($null -eq $avail) { $avail = $hbEp.availability }

                        $onlineLookup[[string]$hbId] = ($avail -eq $true)
                    }
                }

                if ($hb.failedRecords -and @($hb.failedRecords).Count -gt 0) {
                    $diag += "HEARTBEAT failedRecords for [$($batch -join ',')]: $($hb.failedRecords | ConvertTo-Json -Depth 5 -Compress)"
                }
            }
            catch {
                # Heartbeat failure costs online status, not the agent list, so
                # this stays non-fatal even under FailSyncOnPartialResults.
                $diag += "HEARTBEAT (resourceType=$hbResourceTyp) failed for [$($batch -join ',')]: $($_.Exception.Message)"
            }
        }

        $onlineCount = @($onlineLookup.Keys | Where-Object { $onlineLookup[$_] }).Count
        Write-Host "Heartbeat: lookup contains $($onlineLookup.Count) endpoint(s); $onlineCount online."
    }

    # --- PASS 3: emit agents ---
    $emittedCount  = 0
    $unresolvedSite = 0

    foreach ($item in $collected) {
        $ep = $item.ep

        $endpointId = $ep.endpointID
        if (-not $endpointId) { $endpointId = $ep.endpointId }
        if (-not $endpointId) { $endpointId = $ep.id }
        if (-not $endpointId) { continue }

        $candidateRefs = @()
        if ($refsByCompany.ContainsKey($item.companyID)) { $candidateRefs = @($refsByCompany[$item.companyID]) }
        if ($candidateRefs.Count -eq 0) { continue }

        # Company mode: one ref, done. Site mode: pick the ref whose site matches
        # this endpoint. Guessing here would file a machine under the wrong
        # tenant, which is worse than not listing it — so an unresolvable site is
        # counted and reported, never assumed.
        $chosenRef = $candidateRefs[0]

        if ($siteMode -and @($candidateRefs | Where-Object { $_.SiteId }).Count -gt 0) {
            $epSiteId = Get-CwEndpointSiteId -Endpoint $ep -Group $item.group

            if (-not $epSiteId) {
                $unresolvedSite++
                continue
            }

            $match = @($candidateRefs | Where-Object { $_.SiteId -eq $epSiteId }) | Select-Object -First 1
            if (-not $match) { continue }   # site exists but isn't mapped to a tenant
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

        $isOnline = ($onlineLookup[[string]$endpointId] -eq $true)

        $emittedCount++

        New-IntegrationAgent `
            -AgentId ([string]$endpointId) `
            -Name ([string]$name) `
            -ClientId ([string]$chosenRef.Raw) `
            -SerialNumber ([string]$serial) `
            -OSName ([string]$osName) `
            -Manufacturer ([string]$manufacturer) `
            -IsOnline:$isOnline `
            -SupportsRunningScripts:$true
    }

    Write-Host "GetAgents: emitted $emittedCount agent(s)."

    if ($diag.Count -gt 0) {
        Write-Warning ("CW Platform GetAgents diagnostics:`n" + ($diag -join "`n"))
    }

    if ($unresolvedSite -gt 0) {
        throw ("GetAgents: SiteLevelClients is on but $unresolvedSite endpoint(s) carried no resolvable site id, so they were not emitted rather than being filed under the wrong tenant. " +
               "Set VerboseDiscovery=`$true and re-run to dump the raw endpoint object, then add the real field name to Get-CwEndpointSiteId (or add the site field to DeviceFieldSelector).")
    }
}

# =====================================================================
# ISupportsInventoryIdentification — match ImmyBot computers to CW endpoints
# =====================================================================
# Unchanged from alpha. The Invoke-ImmyCommand wrapper is load-bearing: returning
# the raw scriptblock hands ImmyBot the AST, which it then renders as inventory
# data instead of executing it (doc §9.4).
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
# ISupportsTenantInstallToken — generate an agent install token for a company
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

    . ([scriptblock]::Create($IntegrationContext.HelperSource))

    $mappedRef = $ClientId
    if (-not $mappedRef) { $mappedRef = $ProviderClientId }

    if (-not $mappedRef) {
        throw "GetTenantInstallToken received no mapped client id. Remap the tenant under Integration > Clients."
    }

    $baseUri = $IntegrationContext.ApiEndpoint
    if (-not $baseUri) { throw "IntegrationContext.ApiEndpoint is empty — re-initialise the integration." }

    $ref = Resolve-CwClientRef -ClientRef $mappedRef
    $companyId = $ref.CompanyId
    $siteId    = $ref.SiteId

    Write-Host "GetTenantInstallToken: company=$companyId site=$(if ($siteId) { $siteId } else { '(resolve)' })"

    # --- Step 1: resolve the site -----------------------------------------
    # In site-level mapping the tenant already carries its site, so the whole
    # lookup-and-guess dance below is skipped — that guess ("first site wins")
    # is what lands agents in the wrong office on multi-site companies.
    if (-not $siteId) {
        $preferredSiteName = [string](Get-CwConfig -Name 'PreferredSiteName' -Default '')

        $matchingSites = @()
        try {
            # Prefer the per-company endpoint; it is cheaper than pulling every
            # site for the partner and filtering.
            $resp = Invoke-CwApi -Uri "$baseUri/api/platform/v1/company/companies/$companyId/sites" -TimeoutSec 30
            $matchingSites = @($resp.Data)
            Write-Host "Step 1: used per-company sites endpoint"
        }
        catch {
            Write-Host "Step 1: per-company sites endpoint failed, falling back to all-sites filter"
            $resp = Invoke-CwApi -Uri "$baseUri/api/platform/v1/company/sites" -TimeoutSec 60
            $matchingSites = @($resp.Data) | Where-Object { $_.company -and $_.company.id -eq $companyId }
        }

        $siteCount = @($matchingSites).Count
        Write-Host "Step 1: found $siteCount site(s) for company $companyId"

        if ($siteCount -eq 0) {
            throw "No sites found for company $companyId. Verify the company exists in ConnectWise Platform and has at least one site."
        }

        $chosenSite = $null

        if ($preferredSiteName) {
            $chosenSite = @($matchingSites) | Where-Object { $_.name -eq $preferredSiteName } | Select-Object -First 1
            if ($chosenSite) { Write-Host "Step 1: matched preferred site name '$preferredSiteName'" }
        }

        # ConnectWise Platform names a company's default site after the company.
        if (-not $chosenSite -and $siteCount -gt 1) {
            $companyName = $null
            $firstSiteCompany = @($matchingSites)[0].company
            if ($firstSiteCompany -and $firstSiteCompany.name) { $companyName = $firstSiteCompany.name }

            if ($companyName) {
                $chosenSite = @($matchingSites) | Where-Object { $_.name -eq $companyName } | Select-Object -First 1
                if ($chosenSite) { Write-Host "Step 1: matched site by company name '$companyName'" }
            }
        }

        if (-not $chosenSite) {
            $chosenSite = @($matchingSites)[0]
            if ($siteCount -gt 1) {
                Write-Warning "Step 1: $siteCount sites found for company $companyId and none matched — using '$($chosenSite.name)'. Set PreferredSiteName, or turn on SiteLevelClients to map each site to its own tenant."
            }
        }

        $siteId = $chosenSite.id
        Write-Host "Step 1 OK: selected site '$($chosenSite.name)' ($siteId)"
    }

    if (-not $siteId) { throw "Step 1 ended with no siteId for company $companyId" }

    # --- Step 2: generate the install token -------------------------------
    Write-Host "Step 2: generating install token for clientID=$companyId siteID=$siteId"

    $body = @{
        clientID = $companyId
        siteID   = $siteId
    } | ConvertTo-Json -Depth 5

    $resp = (Invoke-CwApi -Uri "$baseUri/api/platform/v1/device/token" -Method Post -Body $body -TimeoutSec 30).Data

    if ($null -eq $resp) {
        throw "Step 2 returned null from /api/platform/v1/device/token"
    }

    # The spec says the response is a bare JSON string like "f4b2990c-...", but
    # be defensive about other shapes.
    $resultToken = $null
    if ($resp -is [string])     { $resultToken = $resp }
    elseif ($resp.token)        { $resultToken = $resp.token }
    elseif ($resp.access_token) { $resultToken = $resp.access_token }
    elseif ($resp -is [System.Collections.IEnumerable] -and @($resp).Count -gt 0) {
        $resultToken = "$(@($resp)[0])"
    }
    else { $resultToken = "$resp" }

    if ([string]::IsNullOrWhiteSpace($resultToken)) {
        throw "Step 2 returned an empty token. Raw response: $($resp | ConvertTo-Json -Depth 3)"
    }

    # Fail here rather than handing a stray error string to msiexec TOKEN=, which
    # installs an agent that never registers and looks like a detection bug days
    # later. The install script re-checks this independently.
    $guid = [Guid]::Empty
    if (-not [Guid]::TryParse($resultToken.Trim(), [ref]$guid)) {
        throw "Step 2 returned a token that is not a GUID: '$resultToken'. Refusing to hand this to the installer."
    }

    Write-Host "Step 2 OK: returning install token for site $siteId"
    return $resultToken.Trim()
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

    . ([scriptblock]::Create($IntegrationContext.HelperSource))

    # ExternalAgentId = the GUID emitted as -AgentId in GetAgents = endpoint GUID
    # in the MANAGED_ENDPOINT space (same id the heartbeat keys on).
    $targetEndpointId = "$($agent.ExternalAgentId)"
    if ([string]::IsNullOrWhiteSpace($targetEndpointId)) {
        throw "RunScript: agent.ExternalAgentId was empty; cannot target the ConnectWise Platform endpoint."
    }

    $baseUri   = $IntegrationContext.ApiEndpoint
    $poll      = [bool](Get-CwConfig -Name 'RunScriptPollForResult'   -Default $false)
    $pollEvery = [int](Get-CwConfig  -Name 'RunScriptPollIntervalSec' -Default 10)
    $resultTpl = [string](Get-CwConfig -Name 'RunScriptResultUriTemplate' -Default '/api/platform/v2/automation/endpoints/schedule-tasks/{taskId}')
    $discovery = [bool](Get-CwConfig -Name 'VerboseDiscovery'         -Default $false)

    # --- Inner parameters: a JSON STRING, per the runner template's jsonSchema ---
    # Both keys required; additionalProperties:false, so add nothing else.
    # $timeout arrives in seconds and maps straight onto expectedExecutionTimeSec.
    $innerParams = @{
        body                     = $scriptCode
        expectedExecutionTimeSec = $timeout
    } | ConvertTo-Json -Depth 5 -Compress

    # --- Outer body: mirrors the working Rewst run_powershell template ---
    # $innerParams is assigned as a string; ConvertTo-Json on the outer object
    # serialises it as an escaped JSON string (the double-encoding the platform
    # expects). Do NOT re-wrap it.
    $outerJson = @{
        name          = "ImmyBot RunScript"
        targets       = @($targetEndpointId)
        schedule      = @{
            repeat         = $null
            endDate        = $null
            category       = "STZ"
            timeZone       = $null
            startDate      = $null
            regularity     = "Immediate"
            endDateType    = $null
            triggerType    = $null
            endTimeFrame   = $null
            scheduleType   = "TIME"
            timeFrameType  = $null
            startTimeFrame = $null
        }
        parameters    = $innerParams
        targetType    = "MANAGED_ENDPOINT"
        templateID    = "51a74346-e19b-11e7-9809-0800279505d9"
        description   = $null
        templateType  = "script"
        resourcesType = "Both"
    } | ConvertTo-Json -Depth 8

    $resp = (Invoke-CwApi -Uri "$baseUri/api/platform/v2/automation/endpoints/schedule-tasks" `
        -Method Post -Body $outerJson -IncludeWrite -TimeoutSec 60).Data

    $taskId = "$($resp.taskId)"
    Write-Host "RunScript dispatched to $targetEndpointId. taskId=$taskId state=$($resp.stateToBeSubmitted)"

    if (-not $poll) {
        # Alpha's behaviour, and the right default for ImmyBot's own use of this
        # capability: the 201 means ACCEPTED, and ImmyBot's bootstrap connects
        # back out-of-band, so there is nothing to wait for.
        return $taskId
    }

    # --- Optional: wait for the task and return its output -----------------
    # UNVERIFIED against the live API. The result URI is a config template and
    # the response shape is probed rather than assumed, so a wrong guess degrades
    # to "returned the taskId" instead of failing the script run. Turn on
    # VerboseDiscovery to capture the real shape, then tighten this.
    if (-not $taskId) {
        Write-Warning "RunScript: polling requested but no taskId came back; returning empty."
        return ""
    }

    $resultUri = "$baseUri$($resultTpl -replace '\{taskId\}', $taskId)"
    $deadline  = (Get-Date).AddSeconds([Math]::Max(30, $timeout))
    $terminal  = @('COMPLETED','COMPLETE','SUCCESS','SUCCEEDED','FAILED','FAILURE','ERROR','CANCELLED','CANCELED','TIMEOUT')

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds ([Math]::Max(2, $pollEvery))

        $task = $null
        try {
            $task = (Invoke-CwApi -Uri $resultUri -IncludeWrite -TimeoutSec 30 -MaxAttempts 2).Data
        }
        catch {
            Write-Warning "RunScript: result poll failed against $resultUri — $($_.Exception.Message). Correct RunScriptResultUriTemplate in the Init config, or set RunScriptPollForResult=`$false. Returning taskId."
            return $taskId
        }

        if ($discovery) {
            Write-Host "DISCOVERY task result payload:`n$($task | ConvertTo-Json -Depth 6)"
        }

        $state = $null
        foreach ($c in @($task.status, $task.state, $task.taskStatus, $task.executionStatus)) {
            if ($c) { $state = "$c"; break }
        }

        if (-not $state) {
            Write-Warning "RunScript: could not find a status field in the task result. Set VerboseDiscovery=`$true to dump the payload. Returning taskId."
            return $taskId
        }

        if ($terminal -notcontains $state.ToUpperInvariant()) { continue }

        Write-Host "RunScript: task $taskId reached terminal state '$state'."

        foreach ($c in @(
            $task.output, $task.stdout, $task.result, $task.scriptOutput,
            $task.data.output, @($task.results)[0].output, @($task.endpoints)[0].output
        )) {
            if ($null -ne $c -and "$c".Trim()) { return "$c" }
        }

        Write-Warning "RunScript: task finished as '$state' but no output field was found. Set VerboseDiscovery=`$true to dump the payload."
        return $taskId
    }

    Write-Warning "RunScript: task $taskId did not reach a terminal state within ${timeout}s. Returning taskId."
    return $taskId

} -get_DefaultTimeout { 600 }

# =====================================================================
# ISupportsHttpRequest — inbound webhook receiver  [BETA, OFF BY DEFAULT]
# =====================================================================
# alpha's README and doc §6 both advertised this capability; no such block ever
# existed in the script. This is the real thing, but the ImmyBot handler contract
# is not confirmed for this build, so:
#   - it is gated behind $BetaEnableWebhookCapability at the top of this file, and
#   - registration is wrapped, because a wrong -Interface or handler name throws
#     at PARSE time and would take every other capability down with it.
# Confirm against your ImmyBot version before turning it on. See BETA-NOTES test 6.
if ($BetaEnableWebhookCapability) {
    try {
        $Integration | Add-DynamicIntegrationCapability -Interface ISupportsHttpRequest -HttpRequestHandler {
            [CmdletBinding()]
            param($Request)

            . ([scriptblock]::Create($IntegrationContext.HelperSource))

            $discovery = [bool](Get-CwConfig -Name 'VerboseDiscovery' -Default $false)

            # Payload shape is unconfirmed — probe the usual carriers rather than
            # binding to one and silently dropping every event.
            $payload = $null
            foreach ($c in @($Request.Body, $Request.body, $Request.Content, $Request.RawBody, $Request)) {
                if ($null -ne $c) { $payload = $c; break }
            }

            if ($discovery) {
                Write-Host "DISCOVERY webhook payload:`n$($payload | ConvertTo-Json -Depth 8)"
            }

            $eventType = $null
            foreach ($c in @($payload.eventType, $payload.type, $payload.event, $payload.action)) {
                if ($c) { $eventType = "$c"; break }
            }

            $endpointId = $null
            foreach ($c in @($payload.endpointID, $payload.endpointId, $payload.deviceId, $payload.id)) {
                if ($c) { $endpointId = "$c"; break }
            }

            Write-Host "CW Platform webhook received. eventType=$eventType endpointId=$endpointId"

            # Deliberately inert until the payload shape is confirmed in situ.
            # Wire actions (targeted inventory refresh, agent re-sync) only once
            # test 6 has captured a real event.
            return @{ status = 200; body = 'ok' }
        }

        Write-Host "Webhook capability registered."
    }
    catch {
        Write-Warning "Webhook capability could not be registered on this ImmyBot build ($($_.Exception.Message)). Every other capability is unaffected. Set `$BetaEnableWebhookCapability = `$false to silence this."
    }
}

$Integration
