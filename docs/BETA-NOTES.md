# ConnectWise Platform — ImmyBot Integration, v2.0.0-beta

Test plan and open questions for the beta line.

**`alpha` stays deployed.** Paste the beta integration into a **second** Dynamic
Integration in ImmyBot so the live one keeps running. Every new behaviour is
flag-gated and defaults to alpha's behaviour, so a fresh paste should be a
no-op difference until you turn something on.

---

## 0. Drift found while building this

`alpha` in git and the live ImmyBot script had diverged, in both directions:

| Thing | git `alpha` | Live ImmyBot | Beta |
| --- | --- | --- | --- |
| Heartbeat `resourceType` | `clients` — now returns **HTTP 400 Invalid Resource Type** | `companies` (working) | `companies`, and now a config value |
| Product naming | rebranded to "ConnectWise Platform" | pre-rebrand "ConnectWise RMM / ASIO" | rebranded |
| `docs/index.html` §9.1 + changelog | says `endpoints` | — | corrected |

The heartbeat value has now changed **twice** (`endpoints` → 403, `clients` →
400, `companies` → works). It is no longer a literal buried in a comment; it is
`HeartbeatResourceType` in the Init config block, so the next change is a config
edit rather than a code hunt.

The doc previously told you to set it to `endpoints` and asserted the script was
already correct. Both statements were wrong. Fixed.

---

## 1. Structural change to validate first

Beta stops copy-pasting the OAuth block into every capability. The helper
functions live in a here-string on `$IntegrationContext.HelperSource`, and each
capability block dot-sources it:

```powershell
. ([scriptblock]::Create($IntegrationContext.HelperSource))
```

This is necessary because ImmyBot serialises each capability scriptblock
independently — a function defined at file scope is **not** visible inside them,
which is why alpha inlined the same token block five times.

**The unknown:** whether your ImmyBot build round-trips extra properties added to
`$IntegrationContext` (alpha only ever set three). If it does not, every
capability fails at once.

**How it fails safely:** HealthCheck checks for `HelperSource` explicitly and
dot-sources it before doing anything else. So this is caught at *Initialise*,
with a named error, rather than at first sync.

> **Test 1.** Paste beta, configure, hit Initialise.
> Healthy → the pattern works, continue.
> "Integration context is missing HelperSource" → stop and tell me; there is a
> fallback shape (inline the helpers per block) that costs duplication but has
> no dependency on context round-tripping.

---

## 2. Tests that need no new API knowledge

| # | Test | Expected |
| --- | --- | --- |
| 2 | Initialise → Clients tab | Company list matches alpha. Log line: `GetClients: N company record(s) after pagination.` Compare N to alpha's count — if beta finds **more**, alpha was silently truncating at a page boundary. |
| 3 | Agent sync on a mapped tenant | Same agents as alpha, same online status. Log: `GetAgents: … SiteMode=False`, `Heartbeat: … N online.` |
| 3b | Install to a test workstation | Install script now logs `Install token validated as a GUID.` before msiexec. A non-GUID token now fails the install instead of installing an agent that never registers. |
| 3c | Uninstall from a test workstation | The `$using:UninstallLog` bug is fixed — it was only assigned on the `unins000.exe` branch while being referenced unconditionally, so the msiexec path (the real ITSPlatform path) referenced an undefined variable *after* a successful uninstall. Watch for whether alpha was actually throwing here. |

---

## 3. Rewst validation worksheet

These are the API facts I could not confirm — the Asio Platform API reference is
behind the partner login and the public results are all ConnectWise *Manage*
(a different API). Everything below is built defensively and **off by default**,
so nothing here blocks tests 1–3.

Auth for all probes: `POST {base}/v1/token`, JSON body, `grant_type=client_credentials`,
scope = the full read string (add `platform.automation.read platform.automation.create`
for the automation probes).

### Probe A — RunScript result endpoint *(blocks: RunScriptPollForResult)*

Dispatch a task the way the integration does, keep the `taskId`, then find what
reads it back.

```
POST {base}/api/platform/v2/automation/endpoints/schedule-tasks   → note taskId
GET  {base}/api/platform/v2/automation/endpoints/schedule-tasks/{taskId}
```

**Tell me:** the working path; the field carrying status and its terminal values
(`COMPLETED`? `SUCCESS`?); the field carrying stdout; whether output is on the
task or per-target under something like `endpoints[]` / `results[]`.

Beta already polls a **configurable** template (`RunScriptResultUriTemplate`)
and probes several status/output field names, degrading to "return the taskId"
rather than failing the run. So the answer may be a config edit, not a code change.

### Probe B — endpoint → site id *(blocks: SiteLevelClients)*

```
GET {base}/api/platform/v2/device/categories/platform/endpoints?field=system,os&limit=500
    body: {"resourceType":"company","resources":["<companyId>"]}
```

**Tell me:** does an endpoint object carry a site id, and under what name? Does
adding `site` to the `field=` selector change what comes back? Is the site id on
the endpoint or on the `platform[]` group wrapper alongside `companyID`?

Beta tries `siteID` / `siteId` / `site.id` / `siteid` on the endpoint and
`siteID` / `siteId` on the group. If none hit, it **refuses to emit** those
agents rather than filing them under the wrong tenant, and throws telling you to
turn on `VerboseDiscovery`.

### Probe C — all-sites shape *(improves: SiteLevelClients cost)*

```
GET {base}/api/platform/v1/company/sites
```

**Tell me:** is the owning company under `company.id`, `companyID`, or
`clientID`? Does it return a `Link: rel="next"` header, and at what page size?

Beta reads all three shapes and pages on `Link`. Confirmation just lets me drop
the guessing.

### Probe D — companies pagination *(confirms a Tier-0 fix)*

```
GET {base}/api/platform/v1/company/companies
```

**Tell me:** is there a `Link` header? What is the page size? How many companies
does your partner account actually have?

Alpha called this once and took whatever came back. If your count is under the
page size this was never biting you — worth knowing either way.

### Probe E — endpoint deregistration *(not built)*

```
DELETE {base}/api/platform/v2/device/endpoints/{endpointId}   (path unknown)
```

**Tell me:** is there any endpoint-delete/archive call?

Uninstalling via ImmyBot leaves the endpoint in the ConnectWise console forever.
**Not in this beta** — a software script has no route back to the integration's
credentials (`Get-IntegrationAgentInstallToken` has no uninstall equivalent), so
this needs an integration-side capability. Worth building once the call is known.

### Probe F — heartbeat resource types *(hardens what just broke twice)*

```
GET {base}/api/platform/v2/device/endpoints/heartbeat?resourceType=companies&resources=<id>,<id>
```

**Tell me:** the currently valid `resourceType` values, and whether the 4-id cap
is documented or empirical.

### Probe G — device-listing batch cap *(pure cost saving)*

The 4-id batch limit is documented for the *heartbeat*. Alpha applied the same
cap to the device listing, which may be unnecessary.

**Tell me:** does the device listing accept more than 4 ids in `resources`? 10?
50? Every doubling halves the API calls per sync — set `ClientBatchSize` to match.

> Note: `ClientBatchSize` currently drives **both** passes. If the device
> listing allows more but heartbeat does not, tell me and I will split them.

### Probe H — webhooks *(blocks: webhook receiver)*

**Tell me:** does ConnectWise Platform support outbound webhooks / event
subscriptions at all? If so: how is an endpoint registered, which events fire,
and what does the payload look like?

alpha's README and doc §6 both advertised a webhook receiver that was never
implemented. Beta has a real (inert) handler gated behind
`$BetaEnableWebhookCapability` at the top of the file, and its registration is
wrapped in try/catch — a wrong interface name throws at *parse* time and would
otherwise take every other capability down with it. **Leave it `$false`** until
both the ImmyBot handler contract and the CW payload are confirmed.

### Probe I — server install *(blocks: AllowServerInstall)*

Not an API question — a ConnectWise support question.

**Tell me:** the correct `SYSTEM=` MSI property value for a server install.
`software/Install-Asio.ps1` has `$AllowServerInstall = $false` and
`$ServerSystemType = 'server'` (a guess). Do not enable it on production until
confirmed; a wrong mode registers but licenses and monitors incorrectly.

---

## 4. Config reference

All runtime flags live in one `$Config` block at the top of `-Init`. Edit, save,
re-initialise.

| Flag | Default | Effect |
| --- | --- | --- |
| `EnableHeartbeat` | `$true` | Online status. Off = every agent reports offline. |
| `HeartbeatResourceType` | `'companies'` | See §0. Never `endpoints`. |
| `ClientBatchSize` | `4` | Company ids per call, both passes. See Probe G. |
| `DeviceFieldSelector` | `'system,os'` | `field=` on the device listing. See Probe B. |
| `FailSyncOnPartialResults` | `$true` | **Behaviour change.** A failed device batch throws instead of emitting a truncated fleet. Set `$false` for alpha's behaviour. |
| `SiteLevelClients` | `$false` | Company/site mapping. **Re-map tenants after changing.** Needs Probe B. |
| `PreferredSiteName` | `''` | Company mode: force a site by name instead of "first site wins". |
| `RunScriptPollForResult` | `$false` | Wait for output instead of fire-and-forget. Needs Probe A. |
| `RunScriptResultUriTemplate` | see script | `{taskId}` placeholder. Correct it here, not in code. |
| `RunScriptPollIntervalSec` | `10` | Poll interval. |
| `VerboseDiscovery` | `$false` | Dumps raw payloads for the unconfirmed shapes. **On while probing, off after** — it logs full API responses. |

Plus `$BetaEnableWebhookCapability` at the **top of the file** (load-time, not in
`$Config` — it gates whether the capability is registered at all).

---

## 5. Behaviour changes to be aware of

1. **`FailSyncOnPartialResults = $true`.** Alpha `break`ed out of the pagination
   loop on an HTTP error and emitted whatever it had, so one 429 or 502 mid-sweep
   silently truncated the fleet and ImmyBot saw agents disappear. Beta throws
   instead. **You may see syncs fail that used to "succeed"** — that is the point;
   they were succeeding with wrong data.
2. **Retry/backoff.** All calls now retry 429/5xx up to 4 attempts with
   exponential backoff, honouring `Retry-After`. Syncs may take longer under
   rate limiting instead of losing data.
3. **Token caching + 401 refresh.** One token per scope per invocation, refreshed
   at 80% of `expires_in`, re-minted once on a 401. Alpha minted a token per
   capability call and rode it through every batch and pagination hop with no
   refresh path — a long `GetAgents` could outlive its own token.
4. **Install token GUID validation**, at both ends (integration and install script).

---

## 6. Local checks

```bash
pwsh -File tests/Test-CwHelpers.ps1        # 35 assertions, no dependencies
```

Covers client-ref parsing, `Link` header pagination, batching, site-id
resolution, config round-tripping as both Hashtable and PSObject, and token
cache expiry. It extracts the helper source from the here-string the same way a
capability block does, so it fails if that extraction ever breaks.

CI (`.github/workflows/validate.yml`) runs the parse check and these tests as
hard gates, plus PSScriptAnalyzer as advisory. It previously triggered on
`main`, which does not exist in this repo — **CI had never run.**
