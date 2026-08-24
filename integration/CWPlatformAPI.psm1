<#
.SYNOPSIS
    ConnectWise Platform API module for the ImmyBot integration.

.DESCRIPTION
    Paste this into ImmyBot as a Module named CWPlatformAPI. Every capability
    block in ConnectWiseRMM-Integration.ps1 opens with:

        Import-Module CWPlatformAPI
        Connect-CwPlatformApi

    This mirrors how the shipped DattoRMM and NinjaRMM integrations work
    (Import-Module DattoRMM-API / NinjaRMMApi at the top of each block), and it
    exists because ImmyBot serialises each capability scriptblock independently
    — a function defined at integration-script scope is not visible inside them.

    Two earlier attempts are worth not repeating:
      - Copy-pasting the OAuth block into every capability (alpha). It drifted;
        RunScript's scope string ended up different from everyone else's.
      - Stashing helper source on $IntegrationContext and dot-sourcing it by
        constructing a scriptblock at runtime (beta.1). That produced
        "The term 'Resolve-CwClientRef' is not recognized" on every sync.

    ImmyBot runs these blocks in ConstrainedLanguage mode. That is the single
    constraint that shapes this file:

        Cannot invoke method. Method invocation is supported only on core
        types in this language mode.

    So: no [Math], no runtime scriptblock construction, no static calls outside
    the handful of core types, and no [pscustomobject] casts — return plain
    hashtables instead, which read identically at the call site. Use operators
    and cmdlets in place of method calls. alpha's entire
    proven-safe surface is [OpResult]::Ok and [string]::IsNullOrWhiteSpace, and
    tests/Test-ConstrainedLanguage.ps1 keeps it that way.

    Note the context was never the problem: arbitrary $IntegrationContext
    properties round-trip fine (NinjaRMM keeps a whole nested lookup table on
    one).
#>

# =====================================================================
# CONFIG — runtime behaviour. Edit here, re-save the module in ImmyBot.
# =====================================================================
function Get-CwConfigTable {
    [CmdletBinding()]
    param()

    @{
        # --- Proven in alpha ---
        EnableHeartbeat          = $true
        ClientBatchSize          = 4
        DeviceFieldSelector      = 'system,os'

        # The heartbeat resourceType is VOLATILE — it has changed twice:
        #   endpoints -> 403 Forbidden on this AU partner key (still true)
        #   clients   -> worked, now returns HTTP 400 "Invalid Resource Type"
        #   companies -> current working value
        # Do NOT set this back to 'endpoints'.
        HeartbeatResourceType    = 'companies'

        # --- Behaviour-changing ---
        # $true = a failed device-listing batch throws instead of quietly
        # emitting a partial fleet. Alpha's behaviour was a silent partial.
        FailSyncOnPartialResults = $true

        # --- OFF by default ---
        # Map ImmyBot tenants to company+site instead of company. Changing this
        # invalidates existing tenant mappings — re-map under Integration >
        # Clients. Needs BETA-NOTES probe B first.
        SiteLevelClients         = $false
        PreferredSiteName        = ''

        # RunScript result polling. Alpha is fire-and-forget (returns taskId).
        # The result URI is UNVERIFIED — a template so it can be corrected
        # without editing logic. See BETA-NOTES probe A.
        RunScriptPollForResult     = $false
        RunScriptResultUriTemplate = '/api/platform/v2/automation/endpoints/schedule-tasks/{taskId}'
        RunScriptPollIntervalSec   = 10

        # Deep link from an ImmyBot agent to the endpoint in the CW console.
        # UNVERIFIED console URL shape — see BETA-NOTES probe J.
        ConsoleUrlTemplate         = ''

        # Logs raw payloads for shapes we have not confirmed. On while probing,
        # off after — it logs full API responses.
        VerboseDiscovery           = $false

        # DIAGNOSTIC. When $true, GetAgents emits one synthetic agent per mapped
        # client and makes NO API calls at all. It exists to answer one question
        # that logs cannot: does ImmyBot ever invoke GetAgents?
        #   agent appears  -> invocation works; the fault is in our device path
        #   nothing at all -> ImmyBot never calls the capability; nothing in this
        #                     repo can fix that, it is instance-side
        # Set back to $false the moment you have the answer.
        DiagnosticEmitTestAgent    = $false
    }
}

function Get-CwConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, $Default = $null)

    $cfg = Get-CwConfigTable
    if ($cfg.Keys -notcontains $Name) { return $Default }

    $val = $cfg[$Name]
    if ($null -eq $val) { return $Default }
    return $val
}

function Get-CwScope {
    [CmdletBinding()]
    param([switch]$IncludeWrite)

    # One definition. Alpha repeated this literal in five places and they had
    # already drifted — RunScript's carried two extra scopes.
    $read = 'platform.companies.read platform.sites.read platform.devices.read platform.agent-token.read platform.asset.read platform.agent.read'

    if ($IncludeWrite) { return "$read platform.automation.read platform.automation.create" }
    return $read
}

function Connect-CwPlatformApi {
    <#
        Mints an OAuth token and caches it on $IntegrationContext so it is
        reused across capability invocations, not just within one.

        Alpha minted a fresh token per capability call and rode it through every
        batch and every pagination hop with no refresh path — a long GetAgents
        run could outlive its own token.
    #>
    [CmdletBinding()]
    param(
        [switch]$IncludeWrite,
        [switch]$Force
    )

    $scope   = Get-CwScope -IncludeWrite:$IncludeWrite
    $baseUri = $IntegrationContext.ApiEndpoint

    if ([string]::IsNullOrWhiteSpace($baseUri)) {
        throw "Connect-CwPlatformApi: IntegrationContext.ApiEndpoint is empty. Re-initialise the integration."
    }

    $script:CwApiUri = $baseUri

    if (-not $IntegrationContext.TokenCache) { $IntegrationContext.TokenCache = @{} }
    $cached = $IntegrationContext.TokenCache[$scope]

    if (-not $Force -and $cached -and $cached.Token -and [datetime]$cached.Expires -gt (Get-Date)) {
        $script:CwAccessToken = $cached.Token
        return $cached.Token
    }

    $body = @{
        grant_type    = 'client_credentials'
        client_id     = "$($IntegrationContext.ClientId)"
        client_secret = "$($IntegrationContext.ClientSecret)"
        scope         = $scope
    } | ConvertTo-Json -Depth 5

    $resp = Invoke-RestMethod -Uri "$baseUri/v1/token" -Method Post `
        -Body $body -ContentType 'application/json' -TimeoutSec 30 -ErrorAction Stop

    if (-not $resp.access_token) {
        throw "Connect-CwPlatformApi: token endpoint returned no access_token."
    }

    # Refresh at 80% of stated lifetime.
    $lifetime = 3600
    if ($resp.expires_in) { $lifetime = [int]$resp.expires_in }

    $refreshSec = [int]($lifetime * 0.8)
    if ($refreshSec -lt 60) { $refreshSec = 60 }

    $IntegrationContext.TokenCache[$scope] = @{
        Token   = $resp.access_token
        Expires = (Get-Date) + (New-TimeSpan -Seconds $refreshSec)
    }

    $script:CwAccessToken = $resp.access_token
    return $resp.access_token
}

function Get-CwNextLink {
    [CmdletBinding()]
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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'Get',
        $Body,
        [switch]$IncludeWrite,
        [int]$TimeoutSec = 60,
        [int]$MaxAttempts = 4
    )

    $token = $script:CwAccessToken
    if (-not $token) { $token = Connect-CwPlatformApi -IncludeWrite:$IncludeWrite }

    $attempt   = 0
    $refreshed = $false

    while ($true) {
        $attempt++

        $headers = @{
            Authorization  = "Bearer $token"
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

            # A plain hashtable, NOT [pscustomobject]. ConstrainedLanguage
            # rejects the cast with "Cannot convert value to type
            # ...InternalPSCustomObject. Only core types are supported in this
            # language mode" — and because it throws inside the try below, it
            # surfaced as a bogus "HTTP 0" and got retried four times.
            # Member access ($result.Data) reads the same on a hashtable.
            return @{
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
                $token = Connect-CwPlatformApi -IncludeWrite:$IncludeWrite -Force
                continue
            }

            # Invoke-RestMethod failures surface with no status code, but so
            # does any exception thrown inside the try — including a
            # ConstrainedLanguage violation. Retrying those just multiplies one
            # error into five and hides the real message, so status 0 is only
            # retried when it actually reads like a network fault.
            $looksTransient = $detail -match '(?i)timed out|timeout|connection|refused|reset|temporarily unavailable|could not resolve|unreachable|handshake'
            $retryable = ($status -eq 429 -or $status -ge 500 -or ($status -eq 0 -and $looksTransient))
            if (-not $retryable -or $attempt -ge $MaxAttempts) {
                throw "CW API $Method $Uri failed (HTTP $status): $detail"
            }

            # Exponential backoff without [Math] — see the ConstrainedLanguage
            # note at the top of this file.
            $delay = switch ($attempt) { 1 { 2 } 2 { 4 } 3 { 8 } default { 16 } }

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
    [CmdletBinding()]
    param([string]$ClientRef)

    if ([string]::IsNullOrWhiteSpace($ClientRef)) { return $null }

    $parts = @("$ClientRef" -split '\|')

    # Hashtable, not [pscustomobject] — see the note in Invoke-CwApi.
    return @{
        Raw       = "$ClientRef"
        CompanyId = $parts[0]
        SiteId    = $(if ($parts.Count -gt 1 -and $parts[1]) { $parts[1] } else { $null })
    }
}

function Get-CwEndpointSiteId {
    # The device listing's site field name is not confirmed. Try the plausible
    # shapes and let the caller decide what to do when none of them hit.
    [CmdletBinding()]
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
    [CmdletBinding()]
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

function Get-CwCompany {
    <#
        Alpha called /company/companies once and emitted whatever came back. The
        device listing in the same API family pages at 500 via Link: rel="next",
        so a partner over that limit silently lost companies — and a company that
        never appears cannot be mapped to a tenant.
    #>
    [CmdletBinding()]
    param()

    $companies = @()
    $nextUri   = "$($IntegrationContext.ApiEndpoint)/api/platform/v1/company/companies"

    while ($nextUri) {
        $page = Invoke-CwApi -Uri $nextUri -TimeoutSec 30
        $companies += @($page.Data)
        $nextUri = $page.NextLink
    }

    return $companies
}

function Get-CwSite {
    [CmdletBinding()]
    param([string]$CompanyId)

    $baseUri = $IntegrationContext.ApiEndpoint

    if ($CompanyId) {
        # Cheaper than pulling every site for the partner and filtering.
        try {
            return @((Invoke-CwApi -Uri "$baseUri/api/platform/v1/company/companies/$CompanyId/sites" -TimeoutSec 30).Data)
        }
        catch {
            Write-Host "Get-CwSite: per-company endpoint failed for $CompanyId, falling back to all-sites filter."
            return @(Get-CwSite) | Where-Object { $_.company -and $_.company.id -eq $CompanyId }
        }
    }

    $sites   = @()
    $nextUri = "$baseUri/api/platform/v1/company/sites"

    while ($nextUri) {
        $page = Invoke-CwApi -Uri $nextUri -TimeoutSec 60
        $sites += @($page.Data)
        $nextUri = $page.NextLink
    }

    return $sites
}

function Get-CwSiteCompanyId {
    # Owning-company field name on a site is unconfirmed — see BETA-NOTES probe C.
    [CmdletBinding()]
    param($Site)

    if ($Site.company -and $Site.company.id) { return "$($Site.company.id)" }
    if ($Site.companyID)                     { return "$($Site.companyID)" }
    if ($Site.clientID)                      { return "$($Site.clientID)" }
    return $null
}

function Get-CwEndpoint {
    <#
        Batched, paginated device listing.

        The OpenAPI spec declares POST here; the live AU tenant requires
        GET-with-body. Do NOT "fix" this to POST.

        Alpha broke out of the pagination loop on an HTTP error and emitted
        whatever it had, so one 429 or 502 mid-sweep silently truncated the
        fleet and ImmyBot saw agents disappear. FailSyncOnPartialResults decides
        whether that now throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$CompanyIds)

    $baseUri       = $IntegrationContext.ApiEndpoint
    $batchSize     = [int](Get-CwConfig -Name 'ClientBatchSize'           -Default 4)
    $fieldSelector = [string](Get-CwConfig -Name 'DeviceFieldSelector'    -Default 'system,os')
    $failOnPartial = [bool](Get-CwConfig -Name 'FailSyncOnPartialResults' -Default $true)

    $uri     = "$baseUri/api/platform/v2/device/categories/platform/endpoints?field=$fieldSelector&limit=500"
    $batches = Get-CwBatch -Items $CompanyIds -Size $batchSize

    $collected = @()
    $failures  = @()

    foreach ($batch in $batches) {
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
                $failures += "companies [$($batch -join ',')]: $($_.Exception.Message)"
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

    if ($failures.Count -gt 0) {
        $msg = "$($failures.Count) of $($batches.Count) device-listing batch(es) failed:`n" + ($failures -join "`n")
        if ($failOnPartial) {
            throw "GetAgents aborted — the endpoint list is incomplete and emitting a partial fleet would make ImmyBot prune healthy agents. $msg"
        }
        Write-Warning $msg
    }

    return $collected
}

function Get-CwHeartbeatLookup {
    <#
        Returns @{ endpointId = $true/$false }. Heartbeat failure costs online
        status, not the agent list, so this never throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$CompanyIds)

    $lookup = @{}

    if (-not [bool](Get-CwConfig -Name 'EnableHeartbeat' -Default $true)) { return $lookup }

    $baseUri      = $IntegrationContext.ApiEndpoint
    $resourceType = [string](Get-CwConfig -Name 'HeartbeatResourceType' -Default 'companies')
    $batchSize    = [int](Get-CwConfig -Name 'ClientBatchSize' -Default 4)

    foreach ($batch in (Get-CwBatch -Items $CompanyIds -Size $batchSize)) {
        $hbUri = "$baseUri/api/platform/v2/device/endpoints/heartbeat?resourceType=$resourceType&resources=$($batch -join ',')"

        try {
            $hb = (Invoke-CwApi -Uri $hbUri -TimeoutSec 60).Data

            foreach ($rec in @($hb.successfulRecords)) {
                foreach ($hbEp in @($rec.endpoints)) {
                    $hbId = $hbEp.EndpointID
                    if (-not $hbId) { $hbId = $hbEp.endpointID }
                    if (-not $hbId) { continue }

                    $avail = $hbEp.Availability
                    if ($null -eq $avail) { $avail = $hbEp.availability }

                    $lookup[[string]$hbId] = ($avail -eq $true)
                }
            }

            if ($hb.failedRecords -and @($hb.failedRecords).Count -gt 0) {
                Write-Warning "Heartbeat failedRecords for [$($batch -join ',')]: $($hb.failedRecords | ConvertTo-Json -Depth 5 -Compress)"
            }
        }
        catch {
            Write-Warning "Heartbeat (resourceType=$resourceType) failed for [$($batch -join ',')]: $($_.Exception.Message)"
        }
    }

    return $lookup
}

function New-CwInstallToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CompanyId,
        [Parameter(Mandatory)][string]$SiteId
    )

    # companyID, NOT clientID. Confirmed against the published API reference
    # 2026-08-24 after beta.2 shipped clientID and got back
    # HTTP 400 { "code": "bad_request", "message": "ErrClientIDNotAllowed" }.
    # The spec's own 400 example is ErrCompanyIDNotProvided, so the field was
    # simply absent. Do not "tidy" this back to clientID -- see the note about
    # the heartbeat resourceType at the top of this file; this API family has
    # retired "client" terminology once already.
    # tests/Test-CwHelpers.ps1 guards both names.
    $body = @{
        companyID = $CompanyId
        siteID    = $SiteId
    } | ConvertTo-Json -Depth 5

    # Log the identifiers being sent. Invoke-CwApi reports the URI and the
    # response body but never the request body, which is the half that matters
    # when this endpoint rejects a pairing.
    Write-Host "New-CwInstallToken: POST device/token companyID=$CompanyId siteID=$SiteId"

    try {
        $resp = (Invoke-CwApi -Uri "$($IntegrationContext.ApiEndpoint)/api/platform/v1/device/token" `
            -Method Post -Body $body -TimeoutSec 30).Data
    }
    catch {
        # Re-throw carrying the identifiers. Invoke-CwApi reports the URI and the
        # response body but not the request body, which is the half that matters
        # here.
        throw "device/token failed for companyID=$CompanyId siteID=$SiteId. $($_.Exception.Message)"
    }

    if ($null -eq $resp) { throw "device/token returned null for company $CompanyId site $SiteId" }

    # The spec says the response is a bare JSON string like "f4b2990c-...", but
    # be defensive about other shapes.
    $token = $null
    if ($resp -is [string])     { $token = $resp }
    elseif ($resp.token)        { $token = $resp.token }
    elseif ($resp.access_token) { $token = $resp.access_token }
    elseif ($resp -is [System.Collections.IEnumerable] -and @($resp).Count -gt 0) { $token = "$(@($resp)[0])" }
    else { $token = "$resp" }

    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "device/token returned an empty token. Raw: $($resp | ConvertTo-Json -Depth 3)"
    }

    $token = $token.Trim()

    # Fail here rather than handing a stray error string to msiexec TOKEN=, which
    # installs an agent that never registers and looks like a detection bug days
    # later. The install script re-checks this independently.
    #
    # Regex rather than [Guid]::TryParse — that needs [ref], and static calls
    # outside the core types are not available in ConstrainedLanguage.
    if ($token -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        throw "device/token returned a value that is not a GUID: '$token'. Refusing to hand this to the installer."
    }

    return $token
}

function Invoke-CwScriptTask {
    <#
        Dispatches the built-in PowerShell runner template against one endpoint.
        Returns the taskId.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EndpointId,
        [Parameter(Mandatory)][string]$ScriptCode,
        [int]$TimeoutSec = 600
    )

    # Inner parameters are a JSON STRING, per the runner template's jsonSchema.
    # Both keys required; additionalProperties:false, so add nothing else.
    $innerParams = @{
        body                     = $ScriptCode
        expectedExecutionTimeSec = $TimeoutSec
    } | ConvertTo-Json -Depth 5 -Compress

    # Mirrors the working Rewst run_powershell template. $innerParams is assigned
    # as a string; ConvertTo-Json serialises it as an escaped JSON string, which
    # is the double-encoding the platform expects. Do NOT re-wrap it.
    $outerJson = @{
        name          = "ImmyBot RunScript"
        targets       = @($EndpointId)
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

    $resp = (Invoke-CwApi -Uri "$($IntegrationContext.ApiEndpoint)/api/platform/v2/automation/endpoints/schedule-tasks" `
        -Method Post -Body $outerJson -IncludeWrite -TimeoutSec 60).Data

    Write-Host "RunScript dispatched to $EndpointId. taskId=$($resp.taskId) state=$($resp.stateToBeSubmitted)"
    return "$($resp.taskId)"
}

function Wait-CwScriptTask {
    <#
        UNVERIFIED against the live API — see BETA-NOTES probe A. The result URI
        is a config template and the response shape is probed rather than
        assumed, so a wrong guess degrades to "return the taskId" instead of
        failing the script run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [int]$TimeoutSec = 600
    )

    $pollEvery = [int](Get-CwConfig    -Name 'RunScriptPollIntervalSec'   -Default 10)
    $resultTpl = [string](Get-CwConfig -Name 'RunScriptResultUriTemplate' -Default '/api/platform/v2/automation/endpoints/schedule-tasks/{taskId}')
    $discovery = [bool](Get-CwConfig   -Name 'VerboseDiscovery'           -Default $false)

    if ($pollEvery -lt 2)  { $pollEvery = 2 }
    $waitSec = $TimeoutSec
    if ($waitSec -lt 30) { $waitSec = 30 }

    $resultUri = "$($IntegrationContext.ApiEndpoint)$($resultTpl -replace '\{taskId\}', $TaskId)"
    $deadline  = (Get-Date) + (New-TimeSpan -Seconds $waitSec)
    $terminal  = @('COMPLETED','COMPLETE','SUCCESS','SUCCEEDED','FAILED','FAILURE','ERROR','CANCELLED','CANCELED','TIMEOUT')

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $pollEvery

        $task = $null
        try {
            $task = (Invoke-CwApi -Uri $resultUri -IncludeWrite -TimeoutSec 30 -MaxAttempts 2).Data
        }
        catch {
            Write-Warning "Result poll failed against $resultUri — $($_.Exception.Message). Correct RunScriptResultUriTemplate in the module config, or set RunScriptPollForResult=`$false."
            return $null
        }

        if ($discovery) { Write-Host "DISCOVERY task result payload:`n$($task | ConvertTo-Json -Depth 6)" }

        $state = $null
        foreach ($c in @($task.status, $task.state, $task.taskStatus, $task.executionStatus)) {
            if ($c) { $state = "$c"; break }
        }

        if (-not $state) {
            Write-Warning "No status field found in the task result. Set VerboseDiscovery=`$true to dump the payload."
            return $null
        }

        if ($terminal -notcontains $state) { continue }

        Write-Host "Task $TaskId reached terminal state '$state'."

        foreach ($c in @(
            $task.output, $task.stdout, $task.result, $task.scriptOutput,
            $task.data.output, @($task.results)[0].output, @($task.endpoints)[0].output
        )) {
            if ($null -ne $c -and "$c".Trim()) { return "$c" }
        }

        Write-Warning "Task finished as '$state' but no output field was found. Set VerboseDiscovery=`$true to dump the payload."
        return $null
    }

    Write-Warning "Task $TaskId did not reach a terminal state within ${TimeoutSec}s."
    return $null
}

Export-ModuleMember -Function @(
    'Get-CwConfigTable',
    'Get-CwConfig',
    'Get-CwScope',
    'Connect-CwPlatformApi',
    'Invoke-CwApi',
    'Get-CwNextLink',
    'Resolve-CwClientRef',
    'Get-CwEndpointSiteId',
    'Get-CwBatch',
    'Get-CwCompany',
    'Get-CwSite',
    'Get-CwSiteCompanyId',
    'Get-CwEndpoint',
    'Get-CwHeartbeatLookup',
    'New-CwInstallToken',
    'Invoke-CwScriptTask',
    'Wait-CwScriptTask'
)
