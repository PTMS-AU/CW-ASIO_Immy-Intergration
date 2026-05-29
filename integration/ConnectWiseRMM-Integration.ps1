<#
.SYNOPSIS
    ImmyBot Dynamic Integration for ConnectWise RMM (ASIO Partner Platform).

.DESCRIPTION
    Built on the PROVEN working auth flow: OAuth2 client_credentials exchange at
    POST /v1/token (JSON body) to obtain a Bearer access_token, which is then used
    on each API call. A fresh token is fetched per capability invocation and scoped
    to what that capability needs.

    Self-contained (no separate module required), mirroring the structure of the
    working GetClients implementation.

    Client mapping: ImmyBot tenants map to ConnectWise COMPANIES (companies are the
    top-level client returned by /company/companies). Devices are then pulled per
    company. (If you prefer site-level mapping, that's a variant we can switch to.)

    Credentials (ConnectWise RMM > Asio Integrations > Generate):
      - API Endpoint URL (regional gateway; AU = https://openapi.service.auplatform.connectwise.com)
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

    $IntegrationContext.ApiEndpoint   = $ApiEndpoint.ToString().TrimEnd('/')
    $IntegrationContext.ClientId      = "$ClientId"

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
    $IntegrationContext.ClientSecret  = $secretPlain

    [OpResult]::Ok()

} -HealthCheck {
    [CmdletBinding()]
    [OutputType([HealthCheckResult])]
    param()

    # Validate by fetching a token + one cheap companies call. Reuses the same
    # token helper logic inline (script blocks can't share functions easily, so
    # the token fetch is repeated in each block — this matches the working code).
    try {
        $baseUri      = $IntegrationContext.ApiEndpoint
        $clientId     = $IntegrationContext.ClientId
        $clientSecret = $IntegrationContext.ClientSecret

        $tokenBody = @{
            grant_type    = "client_credentials"
            client_id     = $clientId
            client_secret = "$clientSecret"
            scope         = "platform.companies.read platform.sites.read platform.devices.read platform.agent-token.read platform.asset.read platform.agent.read"
        } | ConvertTo-Json -Depth 5

        $token = Invoke-RestMethod -Uri "$baseUri/v1/token" -Method Post -Body $tokenBody `
            -ContentType "application/json" -TimeoutSec 30 -ErrorAction Stop

        if (-not $token.access_token) {
            return New-UnhealthyResult -Message "Token endpoint returned no access_token."
        }

        # Don't stop at "got a token" — exercise one real, cheap read so a missing
        # scope or revoked entitlement is caught at init rather than at first
        # GetClients. A token can issue successfully yet still lack read access.
        $headers = @{
            Authorization = "Bearer $($token.access_token)"
            Accept        = "application/json"
        }
        $null = Invoke-RestMethod -Uri "$baseUri/api/platform/v1/company/companies" `
            -Headers $headers -Method Get -TimeoutSec 30 -ErrorAction Stop

        return New-HealthyResult
    }
    catch {
        $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        return New-UnhealthyResult -Message "ConnectWise RMM health check failed: $detail"
    }
}

# =====================================================================
# ISupportsListingClients — list ConnectWise companies as ImmyBot clients
# =====================================================================
$Integration | Add-DynamicIntegrationCapability -Interface ISupportsListingClients -GetClients {
    [CmdletBinding()]
    [OutputType([IProviderClientDetails[]])]
    param()

    $baseUri      = $IntegrationContext.ApiEndpoint
    $clientId     = $IntegrationContext.ClientId
    $clientSecret = $IntegrationContext.ClientSecret

    # --- Get a scoped token (proven working pattern) ---
    $tokenBody = @{
        grant_type    = "client_credentials"
        client_id     = $clientId
        client_secret = "$clientSecret"
        scope         = "platform.companies.read platform.sites.read platform.devices.read platform.agent-token.read platform.asset.read platform.agent.read"
    } | ConvertTo-Json -Depth 5

    $token = Invoke-RestMethod -Uri "$baseUri/v1/token" -Method Post -Body $tokenBody `
        -ContentType "application/json" -TimeoutSec 30 -ErrorAction Stop

    $headers = @{
        Authorization = "Bearer $($token.access_token)"
        Accept        = "application/json"
    }

    $companies = Invoke-RestMethod -Uri "$baseUri/api/platform/v1/company/companies" `
        -Headers $headers -Method Get -TimeoutSec 30 -ErrorAction Stop

    foreach ($company in $companies) {
        $name = $company.friendlyName
        if (-not $name) { $name = $company.name }

        New-IntegrationClient -ClientId $company.id -ClientName $name
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

    $baseUri      = $IntegrationContext.ApiEndpoint
    $clientId     = $IntegrationContext.ClientId
    $clientSecret = $IntegrationContext.ClientSecret

    # Troubleshooting target. Set to $null or "" after validation.
    $TargetEndpointId = $null

    # --- Auth ---
    $tokenBody = @{
        grant_type    = "client_credentials"
        client_id     = $clientId
        client_secret = "$clientSecret"
        scope         = "platform.companies.read platform.sites.read platform.devices.read platform.agent-token.read platform.asset.read platform.agent.read"
    } | ConvertTo-Json -Depth 5

    $token = Invoke-RestMethod -Uri "$baseUri/v1/token" `
        -Method Post `
        -Body $tokenBody `
        -ContentType "application/json" `
        -TimeoutSec 30 `
        -ErrorAction Stop

    if (-not $token.access_token) {
        throw "ConnectWise RMM token endpoint returned no access_token."
    }

    $headers = @{
        Authorization  = "Bearer $($token.access_token)"
        Accept         = "application/json"
        "Content-Type" = "application/json"
    }

    # --- Build client batches ---
    $uri = "$baseUri/api/platform/v2/device/categories/platform/endpoints?field=system,os&limit=500"

    $batches = @()
    $current = @()

    foreach ($cid in $ClientIds) {
        if (-not $cid) { continue }

        $current += [string]$cid

        if ($current.Count -eq 4) {
            $batches += ,$current
            $current = @()
        }
    }

    if ($current.Count -gt 0) {
        $batches += ,$current
    }

    # --- PASS 1: collect endpoint inventory ---
    $collected = @()
    $diag = @()

    foreach ($batch in $batches) {
        $body = @{
            resourceType = "company"
            resources    = @($batch)
        } | ConvertTo-Json -Depth 5

        $nextUri = $uri

        while ($nextUri) {
            $resp = $null
            $respHeaders = $null

            try {
                $resp = Invoke-RestMethod -Uri $nextUri `
                    -Headers $headers `
                    -Method Get `
                    -Body $body `
                    -ResponseHeadersVariable respHeaders `
                    -TimeoutSec 60 `
                    -ErrorAction Stop
            }
            catch {
                if ($diag.Count -lt 3) {
                    $st = try { [int]$_.Exception.Response.StatusCode } catch { '?' }
                    $bd = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { '(no body)' }
                    $diag += "DEVICE call HTTP $st for companies [$($batch -join ',')]: $bd"
                }

                break
            }

            foreach ($group in @($resp.platform)) {
                if (-not $group) { continue }

                foreach ($ep in @($group.endpoints)) {
                    if (-not $ep) { continue }

                    $collected += @{
                        ep        = $ep
                        companyID = $group.companyID
                    }
                }
            }

            $nextUri = $null
            $linkHeader = $respHeaders.Link

            if ($linkHeader) {
                $linkValue = if ($linkHeader -is [array]) { $linkHeader -join ',' } else { "$linkHeader" }

                if ($linkValue -match '<([^>]+)>\s*;\s*rel="?next"?') {
                    $nextUri = $Matches[1]
                }
            }
        }
    }

    Write-Host "GetAgents: collected $($collected.Count) endpoint(s) from device listing."

    # --- PASS 2: online status via heartbeat ---
    $EnableHeartbeat = $true
    $onlineLookup = @{}

    if ($EnableHeartbeat -and $collected.Count -gt 0) {
        $allEndpointIds = @()

        foreach ($item in $collected) {
            $eid = $item.ep.endpointID
            if (-not $eid) { $eid = $item.ep.endpointId }
            if (-not $eid) { $eid = $item.ep.id }

            if ($eid) {
                $allEndpointIds += [string]$eid
            }
        }

        Write-Host "Heartbeat: collected $($allEndpointIds.Count) endpoint id(s)."

        # Keep chunks small to avoid long query strings.
        $hbChunks = @()
        $hbChunk = @()

        foreach ($eid in $allEndpointIds) {
            $hbChunk += $eid

            if ($hbChunk.Count -eq 25) {
                $hbChunks += ,$hbChunk
                $hbChunk = @()
            }
        }

        if ($hbChunk.Count -gt 0) {
            $hbChunks += ,$hbChunk
        }

        Write-Host "Heartbeat: created $($hbChunks.Count) chunk(s)."

        foreach ($chunk in $hbChunks) {
            $hbResources = ($chunk -join ',')
            $hbUri = "$baseUri/api/platform/v2/device/endpoints/heartbeat?resourceType=endpoints&availability=true&resources=$hbResources"

            try {
                $hb = Invoke-RestMethod -Uri $hbUri `
                    -Headers $headers `
                    -Method Get `
                    -TimeoutSec 60 `
                    -ErrorAction Stop

                if ($hb -and $hb.successfulRecords) {
                    foreach ($rec in @($hb.successfulRecords)) {
                        $heartbeatItems = @()

                        if ($rec.endpoints) {
                            $heartbeatItems += @($rec.endpoints)
                        }
                        else {
                            $heartbeatItems += $rec
                        }

                        foreach ($hbEp in $heartbeatItems) {
                            $hbId = $hbEp.EndpointID
                            if (-not $hbId) { $hbId = $hbEp.endpointID }
                            if (-not $hbId) { $hbId = $hbEp.endpointId }
                            if (-not $hbId) { $hbId = $hbEp.id }

                            if (-not $hbId) {
                                continue
                            }

                            $availability = $hbEp.Availability
                            if ($null -eq $availability) { $availability = $hbEp.availability }
                            if ($null -eq $availability) { $availability = $hbEp.online }
                            if ($null -eq $availability) { $availability = $hbEp.isOnline }
                            if ($null -eq $availability) { $availability = $hbEp.status }

                            $availabilityText = "$availability"
                            $isAvailable = $false

                            if ($availability -eq $true) {
                                $isAvailable = $true
                            }
                            elseif ($availabilityText -match '^(true|online|available|active|1)$') {
                                $isAvailable = $true
                            }

                            $onlineLookup[[string]$hbId] = $isAvailable

                        }
                    }
                }
                else {
                    if ($diag.Count -lt 3) {
                        $diag += "HEARTBEAT call returned no successfulRecords. Raw response: $($hb | ConvertTo-Json -Depth 5 -Compress)"
                    }
                }

                if ($hb -and $hb.failedRecords -and $diag.Count -lt 3) {
                    $diag += "HEARTBEAT failedRecords: $($hb.failedRecords | ConvertTo-Json -Depth 5 -Compress)"
                }
            }
            catch {
                if ($diag.Count -lt 3) {
                    $st = try { [int]$_.Exception.Response.StatusCode } catch { '?' }
                    $bd = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { '(no body)' }
                    $diag += "HEARTBEAT call HTTP ${st}: $bd"
                }
            }
        }

        $onlineCount = 0

        foreach ($key in $onlineLookup.Keys) {
            if ($onlineLookup[$key] -eq $true) {
                $onlineCount++
            }
        }

        Write-Host "Heartbeat: online lookup contains $($onlineLookup.Count) endpoint(s); $onlineCount online."
    }

# --- PASS 3: emit agents ---
$emittedCount = 0

Write-Host "PASS 3: starting agent emit loop. Collected count: $($collected.Count)"

foreach ($item in $collected) {
    $ep = $item.ep

    $endpointId = $ep.endpointID
    if (-not $endpointId) { $endpointId = $ep.endpointId }
    if (-not $endpointId) { $endpointId = $ep.id }
    if (-not $endpointId) { continue }

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

    $isOnline = $false
    $lookupVal = $onlineLookup[[string]$endpointId]

    if ($lookupVal -eq $true) {
        $isOnline = $true
    }

    $emittedCount++

    New-IntegrationAgent `
        -AgentId ([string]$endpointId) `
        -Name ([string]$name) `
        -ClientId ([string]$item.companyID) `
        -SerialNumber ([string]$serial) `
        -OSName ([string]$osName) `
        -Manufacturer ([string]$manufacturer) `
        -IsOnline:$isOnline `
        -SupportsRunningScripts:$false
}

Write-Host "GetAgents: emitted $emittedCount agent(s)."

    if ($diag.Count -gt 0) {
        Write-Warning ("CWRMM GetAgents diagnostics:`n" + ($diag -join "`n"))
    }
}

# =====================================================================
# ISupportsInventoryIdentification — match ImmyBot computers to CW endpoints
# =====================================================================
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

$MappedCompanyId = $ClientId
if (-not $MappedCompanyId) {
    $MappedCompanyId = $ProviderClientId
}

Write-Host "GetTenantInstallToken invoked. Mapped company id present: $([bool]$MappedCompanyId)"

if (-not $MappedCompanyId) {
    throw "GetTenantInstallToken received no mapped company id. Remap the tenant under Integration > Clients."
}

Write-Host "GetTenantInstallToken invoked. clientId=[$clientId]"

    $baseUri        = $IntegrationContext.ApiEndpoint
    $cwClientId     = $IntegrationContext.ClientId
    $cwClientSecret = $IntegrationContext.ClientSecret

    if (-not $baseUri)        { throw "IntegrationContext.ApiEndpoint is empty" }
    if (-not $cwClientId)     { throw "IntegrationContext.ClientId is empty" }
    if (-not $cwClientSecret) { throw "IntegrationContext.ClientSecret is empty" }
    if (-not $MappedCompanyId)       { throw "GetTenantInstallToken received an empty clientId — the calling tenant is probably not mapped to a CW company under Integration > Clients" }

    # --- Step 1: get a token scoped for agent-token retrieval -------------
    # This capability does TWO things with this token: (Step 2) a site lookup on
    # the /company/* endpoints, and (Step 3) the agent-token generation. So the
    # token must carry the relevant read scopes — requesting only agent-token.read
    # makes Step 2 fail with 403 "client has no access" on the sites call, because
    # that token has no company/site read rights. OAuth2 takes space-separated
    # scopes. sites.read is included explicitly because the /company/sites endpoint
    # may be gated by it rather than companies.read (the spec doesn't annotate it);
    # the key has all of these granted, so requesting them all is safe.
    Write-Host "Step 1: requesting OAuth token (full read scope set: companies/sites/devices/agent-token/asset/agent)"
    $tokenBody = @{
        grant_type    = "client_credentials"
        client_id     = $cwClientId
        client_secret = "$cwClientSecret"
        scope         = "platform.companies.read platform.sites.read platform.devices.read platform.agent-token.read platform.asset.read platform.agent.read"
    } | ConvertTo-Json -Depth 5

    $token = $null
    try {
        $token = Invoke-RestMethod -Uri "$baseUri/v1/token" -Method Post -Body $tokenBody `
            -ContentType "application/json" -TimeoutSec 30 -ErrorAction Stop
    } catch {
        $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        throw "Step 1 (OAuth token request) failed: $detail"
    }

    if (-not $token.access_token) {
        throw "Step 1 returned no access_token. Response: $($token | ConvertTo-Json -Depth 3)"
    }
    Write-Host "Step 1 OK: token length $($token.access_token.Length)"

    $headers = @{
        Authorization  = "Bearer $($token.access_token)"
        Accept         = "application/json"
        "Content-Type" = "application/json"
    }

    # --- Step 2: find a site id for this company -------------------------
    # The install-token endpoint needs BOTH clientID (company) and siteID, so we
    # look up the sites for this company. Prefer the per-company endpoint
    # /company/companies/{id}/sites (confirmed present in the OpenAPI spec) — it's
    # cheaper than pulling every site for the whole partner and filtering. Fall
    # back to the all-sites endpoint if the nested form ever 404s on a tenant.
    #
    # Site selection strategy for multi-site companies:
    #   - If only one site: use it.
    #   - If multiple: prefer the site matching the company name (the "default" site
    #     ConnectWise creates), then fall back to the first site.
    #   - Override: set $PreferredSiteName below to force a specific site name.
    $PreferredSiteName = $null  # e.g. "Main Office" — set to force a site choice
    Write-Host "Step 2: looking up sites for company $MappedCompanyId"
    $siteId = $null
    try {
        $matchingSites = $null
        try {
            $companySites = Invoke-RestMethod -Uri "$baseUri/api/platform/v1/company/companies/$MappedCompanyId/sites" `
                -Headers $headers -Method Get -TimeoutSec 30 -ErrorAction Stop
            $matchingSites = @($companySites)
            Write-Host "Step 2: used per-company sites endpoint"
        } catch {
            # Fall back to the all-sites endpoint and filter by company id.
            Write-Host "Step 2: per-company sites endpoint failed, falling back to all-sites filter"
            $allSites = Invoke-RestMethod -Uri "$baseUri/api/platform/v1/company/sites" `
                -Headers $headers -Method Get -TimeoutSec 30 -ErrorAction Stop
            $matchingSites = @($allSites) | Where-Object {
                $_.company -and $_.company.id -eq $MappedCompanyId
            }
        }

        $siteCount = @($matchingSites).Count
        Write-Host "Step 2: found $siteCount site(s) for company $MappedCompanyId"

        if ($siteCount -eq 0) {
            throw "No sites found for company $MappedCompanyId. Verify the company exists in CW RMM and has at least one site."
        }

        $chosenSite = $null

        # Try preferred site name first (if configured).
        if ($PreferredSiteName) {
            $chosenSite = @($matchingSites) | Where-Object { $_.name -eq $PreferredSiteName } | Select-Object -First 1
            if ($chosenSite) {
                Write-Host "Step 2: matched preferred site name '$PreferredSiteName'"
            }
        }

        # Try matching the company name (ConnectWise default site naming).
        if (-not $chosenSite -and $siteCount -gt 1) {
            # Look up the company name for matching.
            $companyName = $null
            $firstSiteCompany = @($matchingSites)[0].company
            if ($firstSiteCompany -and $firstSiteCompany.name) {
                $companyName = $firstSiteCompany.name
            }
            if ($companyName) {
                $chosenSite = @($matchingSites) | Where-Object { $_.name -eq $companyName } | Select-Object -First 1
                if ($chosenSite) {
                    Write-Host "Step 2: matched site by company name '$companyName'"
                }
            }
        }

        # Fall back to first site.
        if (-not $chosenSite) {
            $chosenSite = @($matchingSites)[0]
            if ($siteCount -gt 1) {
                Write-Host "Step 2: WARNING — $siteCount sites found, using first site. Set `$PreferredSiteName or switch to site-level mapping (v1) for precise control."
            }
        }

        $siteId = $chosenSite.id
        Write-Host "Step 2 OK: selected site '$($chosenSite.name)' ($siteId)"
    } catch {
        $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        throw "Step 2 (site lookup) failed: $detail"
    }

    if (-not $siteId) {
        throw "Step 2 ended with no siteId selected for company $MappedCompanyId"
    }

    # --- Step 3: generate the install token -------------------------------
    Write-Host "Step 3: generating install token for clientID=$MappedCompanyId siteID=$siteId"
    $body = @{
        clientID = $MappedCompanyId
        siteID   = $siteId
    } | ConvertTo-Json -Depth 5

    $resp = $null
    try {
$resp = Invoke-RestMethod -Uri "$baseUri/api/platform/v1/device/token" `
    -Headers $headers `
    -Method Post `
    -Body $body `
    -ContentType "application/json" `
    -TimeoutSec 30 `
    -ErrorAction Stop
    } catch {
        $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        throw "Step 3 (device/token POST) failed: $detail"
    }

    # The spec says response is a bare JSON string like "f4b2990c-...".
    # Invoke-RestMethod with a string JSON body typically returns a [string],
    # but be defensive about other shapes.
if ($null -eq $resp) {
    throw "Step 3 returned null from /api/platform/v1/device/token"
}

Write-Host "Step 3: received response from token endpoint"

    $resultToken = $null
    if ($resp -is [string])      { $resultToken = $resp }
    elseif ($resp.token)         { $resultToken = $resp.token }
    elseif ($resp.access_token)  { $resultToken = $resp.access_token }
    elseif ($resp -is [System.Collections.IEnumerable] -and @($resp).Count -gt 0) {
        $resultToken = "$(@($resp)[0])"
    } else {
        $resultToken = "$resp"
    }

    if ([string]::IsNullOrWhiteSpace($resultToken)) {
        throw "Step 3 returned an empty token. Raw response: $($resp | ConvertTo-Json -Depth 3)"
    }

    Write-Host "Step 3 OK: returning token (length $($resultToken.Length))"
    return $resultToken
}

# =====================================================================
# ISupportsHttpRequest — handle incoming webhooks from ConnectWise ASIO
# =====================================================================
# Once this capability is added, ImmyBot exposes a webhook URL at:
#   https://<instance>.immy.bot/plugins/api/v1/<providerLinkId>
# Configure that URL in ConnectWise RMM > Integrations > Webhooks to
# receive alerts and events. The $body parameter receives the parsed JSON
# payload from ConnectWise.
#
# This stub logs the incoming request and returns 200 OK. Extend the
# switch block below to trigger ImmyBot actions based on event types
# (e.g., agent-offline → schedule maintenance, alert → create ticket).
$Integration | Add-DynamicIntegrationCapability -Interface ISupportsHttpRequest -HandleHttpRequest {
    [CmdletBinding()]
    [OutputType([Microsoft.AspNetCore.Mvc.IActionResult])]
    param(
        [Parameter(Mandatory = $true)]
        [Microsoft.AspNetCore.Http.HttpContext]$httpContext,

        [Parameter(Mandatory = $false)]
        $body,

        [Parameter(Mandatory = $true)]
        $route
    )

    # Log the incoming request for diagnostics.
    $method = $httpContext.Request.Method
    $path   = $httpContext.Request.Path
    Write-Host "CWRMM Webhook received: $method $path"

    if ($body) {
        # ConnectWise ASIO webhook payloads typically include an event type
        # and endpoint/device identifiers. Extend this switch as needed.
        $eventType = $body.eventType
        if (-not $eventType) { $eventType = $body.type }
        if (-not $eventType) { $eventType = 'unknown' }

        Write-Host "CWRMM Webhook event type: $eventType"

        switch ($eventType) {
            'agent.offline' {
                # Example: an agent went offline — log it. Extend to trigger
                # a maintenance session or create an alert in ImmyBot.
                $endpointId = $body.endpointId
                if (-not $endpointId) { $endpointId = $body.endpointID }
                Write-Host "Agent offline event for endpoint: $endpointId"
            }
            'agent.online' {
                $endpointId = $body.endpointId
                if (-not $endpointId) { $endpointId = $body.endpointID }
                Write-Host "Agent online event for endpoint: $endpointId"
            }
            'alert' {
                Write-Host "Alert received: $($body.alertMessage ?? $body.message ?? 'no message')"
            }
            default {
                Write-Host "Unhandled event type '$eventType'. Body: $($body | ConvertTo-Json -Depth 3 -Compress)"
            }
        }
    }

    # Return 200 OK to acknowledge receipt.
    $res = [ObjectResult]::new('ok')
    $res.StatusCode = 200
    return $res
}

$Integration