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

## 1. Architecture — corrected in beta.2

### What broke in beta.1

Every sync logged, repeatedly:

```
The term 'Resolve-CwClientRef' is not recognized as a name of a cmdlet, function,
script file, or executable program.
```

beta.1 stashed the helper source on `$IntegrationContext.HelperSource` and
dot-sourced it per block with `[scriptblock]::Create()`.

**My first diagnosis was wrong.** I concluded that properties added to
`$IntegrationContext` do not survive rehydration. The shipped integrations
disprove that outright — NinjaRMM keeps a whole nested `AgentLUT` hashtable on
the context and *mutates it across invocations*, and DattoRMM keeps
`ApiUrl`/`ApiKey`/`ComponentUID` there. Arbitrary context properties are fine.

The real cause is `[scriptblock]::Create()`, which ImmyBot's runspace does not
permit. HealthCheck appeared to pass because it runs in the same process as
`-Init`; the error was in the truncated portion of the log.

### What beta.2 does instead

The idiomatic ImmyBot answer, confirmed against the shipped DattoRMM and
NinjaRMM integrations: **a module, imported at the top of every capability
block.**

```powershell
Import-Module CWPlatformAPI
$null = Connect-CwPlatformApi
```

This is the same shape as `Import-Module DattoRMM-API` / `Import-Module
NinjaRMMApi`. It removes the code duplication *and* the mechanism that failed.

### The constraint behind both failures: ConstrainedLanguage

beta.2's first paste failed at Init with:

```
Cannot invoke method. Method invocation is supported only on core types in
this language mode.
```

**ImmyBot runs integration script blocks in PowerShell ConstrainedLanguage
mode.** That single fact explains both betas:

| Attempt | Construct | Why it failed |
| --- | --- | --- |
| beta.1 | built a scriptblock at runtime to share helpers | scriptblock construction is not permitted |
| beta.2 | `[Math]::Max`, `[Math]::Pow` | `System.Math` is not a core type |
| beta.2 | `$hash.ContainsKey($k)` | method call on a Hashtable |
| beta.2 | `[pscustomobject]@{...}` | the cast itself is rejected |

None of it reproduces locally: a normal `pwsh` runs FullLanguage and executes all
of it happily. So the rule is now a **CI gate**
(`tests/Test-ConstrainedLanguage.ps1`, AST-based) rather than something to
remember:

- static member access only on core types, plus `OpResult` and `ObjectResult`;
- no runtime scriptblock construction;
- no `[pscustomobject]` / `[psobject]` casts;
- a denylist of instance methods on non-core types (`AddSeconds`, `ContainsKey`,
  `ToUpperInvariant`, …), each pointing at the operator or cmdlet to use instead.

alpha's entire proven-safe surface is `[OpResult]::Ok` and
`[string]::IsNullOrWhiteSpace`. That is the bar new code is held to.

The `[pscustomobject]` one was the nastiest, and worth remembering. `Invoke-CwApi`
returned one on every successful call, so the cast threw **inside its own try
block** — which reported it as `HTTP 0` and then retried it four times. One
mistake became five identical log lines and 15 seconds per call, with the real
message buried. Two fixes: return plain hashtables (`$result.Data` reads
identically), and only retry a status-0 failure when the message actually looks
like a network fault, so a language-mode error now fails fast and legibly.

Rewrites applied: `[pscustomobject]@{}` → plain hashtables;
`[Math]::Max/Pow` → comparisons and a `switch`;
`(Get-Date).AddSeconds(n)` → `(Get-Date) + (New-TimeSpan -Seconds n)`;
`.ContainsKey($k)` → `.Keys -contains $k`; `[Guid]::TryParse` → a regex;
`.Split('|')` → the `-split` operator; `.ToUpperInvariant()` dropped, since
`-contains` is already case-insensitive.

> Scope note: this applies to `integration/` only. The `software/` scripts run in
> MetaScript and endpoint contexts, which are FullLanguage — alpha has shipped
> `[IO.Path]::GetTempFileName()` in the uninstall script for as long as it has
> existed.

### You now paste TWO things

| File | Paste into ImmyBot as | Order |
| --- | --- | --- |
| `integration/CWPlatformAPI.psm1` | a **Module** named exactly `CWPlatformAPI` | **first** |
| `integration/ConnectWiseRMM-Integration.ps1` | a **Dynamic Integration** | second |

Create the module first. If the integration initialises without it, every
capability fails with "The term 'Connect-CwPlatformApi' is not recognized" —
HealthCheck now detects this specific case and says so.

The integration script went from ~2,470 lines to ~536. The generator build
(`integration/src/`, `build/`) is gone; it existed only to work around the
mechanism that turned out to be wrong.

**Config now lives in the module** (`Get-CwConfigTable` at the top of
`CWPlatformAPI.psm1`), not in the integration script. Edit there, re-save the
module.

### Also corrected from the shipped examples

| Thing | beta.1 | beta.2 |
| --- | --- | --- |
| Webhook handler parameter | `-HttpRequestHandler` (guessed, **wrong**) | `-HandleHttpRequest` with `$httpContext`/`$body`/`$route`, returning `[ObjectResult]` |
| Agent version | not reported | `-AgentVersion` on `New-IntegrationAgent` (both shipped integrations use it) |
| Long-running blocks | no timeout attribute | `[ScriptTimeout(TimeoutSeconds = 600)]` on `GetAgents` |
| Console deep-link | none | `ISupportsExternalProviderAgentUrl` (off until probe J) |

The webhook is now **enabled**, because the ImmyBot side is confirmed and the
handler is deliberately inert — it logs the payload and returns 200. That makes
it the capture tool for probe H rather than a guess. It answers at
`plugins/api/v1/{providerLinkId}`.

## 1b. Validated in situ — 2026-08-20

First full end-to-end run against the AU tenant (integration id 313, ~3,500
endpoints across 38 linked clients).

| Capability | Status | Evidence |
| --- | --- | --- |
| Init | working | 277–310 ms, module loads, token mints |
| HealthCheck | working | ~650 ms on a 60-second cadence |
| GetClients | working | paginates, 38 clients listed |
| GetAgents | working | ~3,500 agents imported with serial, OS, tenant |
| Heartbeat (`resourceType=companies`) | **working** | see reasoning below |
| Agent identification | working | `PATMANWKS05` matched existing computer #5618 and assigned |
| RunScript | working | dispatches, 320–700 ms, drives ephemeral agent sessions |
| GetInventoryScript | registers | ran at 0 ms; the registry path itself is still unexercised |

**Probe F is answered without needing the log.** Emission does
`$onlineLookup[$endpointId] -eq $true`, so an empty heartbeat would make *every*
agent offline, ImmyBot would find no online agent, and no ephemeral session
could ever start. Sessions do start, so the heartbeat returns real availability.
`resourceType=companies` is confirmed good.

### Bugs this run found, in order

1. `[Math]::Max` / `[Math]::Pow` — ConstrainedLanguage. Init failed.
2. `[pscustomobject]@{}` — ConstrainedLanguage rejects the cast. Every API call
   failed, and because it threw inside `Invoke-CwApi`'s own try block it
   surfaced as a bogus `HTTP 0` and got retried four times.
3. `.ContainsKey()` — ConstrainedLanguage. Caught by the new test, not by ImmyBot.
4. `-AgentVersion 'Unknown'` — the parameter is typed `[Version]`, so the
   placeholder copied from the DattoRMM example threw once per agent.

Every one of them passed 70+ local assertions first. A normal `pwsh` runs
FullLanguage and executes all of it happily. **This integration cannot be
validated locally** — the tests catch regressions, the live instance finds the
class of bug that matters.

### Not yet exercised *(as of 2026-08-20 — largely superseded, see 1c)*

- **`ISupportsInventoryIdentification`** — `PATMANWKS05` matched on trusted
  manufacturer + serial, which short-circuits before the inventory script runs.
  The `privateendpointid` registry path is still unproven. **Still open.**
- ~~**`GetTenantInstallToken`**~~ — proven 2026-08-24, see 1c.
- ~~**The four changed `software/` scripts**~~ — proven 2026-08-24, see 1c.
- Site-level mapping, RunScript result polling, webhook payload, console URL —
  all still off, all still needing their probes.

## 1c. Full agent lifecycle proven in situ — 2026-08-24

`PT-WIN11LAB`, maintenance session #425809. Uninstall and install both green,
Detect / Install / Test / Verify all passing, result **Compliant**.

This closes Tier 1 items 1 and 2 of the handoff. The whole install chain is now
proven end to end, and the ConnectWise installer itself validated the pieces we
could previously only assert:

| Custom action inside the agent MSI | Result |
| --- | --- |
| `checkdiskspaceAction` | 1 |
| `checkUrlAction` — reaches the data centre | 1 |
| `checkTokenAction` — the token we minted | **1** |
| `checklegacycfgAction` | 1 |

So `GetTenantInstallToken` -> `device/token` -> `TOKEN=` -> agent registration
is confirmed by ConnectWise's own installer, not just by our GUID check.

### The endpoint id is REUSED, not duplicated

The agent came back as `a978a23b-d258-423e-9a75-71138daeaf46` — **the same
`privateendpointid` it had before the uninstall**. ConnectWise matched the
machine and reissued its existing endpoint rather than creating a new one.

Confirmed from the ConnectWise side as well: the endpoint came back **online
and checking in**, and it **overwrote the existing sessions** rather than
appearing alongside them.

This corrects earlier guidance in this repo and in the handoff, which warned
that an uninstall/reinstall would strand the old endpoint and produce a
duplicate, and advised deleting the stale record from the ConnectWise console
first. **Do not do that.** Deleting it discards the mapping the reinstall
relies on. There is no duplicate to clean up.

Probe E (endpoint deregistration) is therefore less important than it looked:
reinstall is idempotent from ConnectWise's side.

### Four defects this run surfaced, in order

1. **The MSI product registration outlives its files.** Windows Installer still
   held ITSPlatform `{18F39771-F9D8-4CFD-9654-F6C67C8AD9F4}` 5.0.3.3573 as
   installed after the service, registry and files were gone, so `msiexec /i`
   entered maintenance mode, reported `Action: Null` for every component, and
   exited 0 in 15 seconds having done nothing. The install now de-registers by
   ProductCode first. Note this is a state the residual cleanup can *create*.

2. **`Invoke-ImmyCommand` defaults to a 120-second timeout.** The install block
   exceeds that comfortably — `StartServices` alone waits 60s — and it died
   mid-install with no result reported. Now `-Timeout 1500`.

3. **Deleting a service whose process is still running only marks it for
   deletion.** Doing that then installing produced
   `Error 1920. Service 'ITSPlatform Service' (ITSPlatform) failed to start`,
   a rollback, and exit 1603. Processes are now killed before their services,
   and a lingering name is reported as a reboot-to-clear condition.

4. **A reboot was required** to clear the services left marked-for-deletion by
   the earlier ordering. The install succeeded on the first attempt afterwards.

### Still open after this run

- `ISupportsInventoryIdentification` on a machine that does **not** match by
  serial — the last untested item in Tier 1.
- Every deployment still carrying the deleted integration 245 needs re-saving,
  not just the one used here. See 3b.

### Operational note: the import storm

Linking 38 clients at once imported ~3,500 agents, and ImmyBot enqueues
identification for every newly imported agent. Each identification needs an
ephemeral session, each session calls `RunScript`, and each `RunScript` creates a
real automation task in ConnectWise — roughly one per second, sustained, until
the backlog drains.

It is volume rather than a retry loop (the heartbeat is good, so sessions
succeed rather than timing out), but it puts thousands of tasks into a
production console. **Link one small tenant for beta testing, not the whole
book.**

## 2. Tests that need no new API knowledge

| # | Test | Expected |
| --- | --- | --- |
| 0 | Create the `CWPlatformAPI` **Module** before initialising | Skipping this fails every capability with "The term 'Connect-CwPlatformApi' is not recognized". |
| 1 | Initialise, then **run an agent sync** | HealthCheck alone is not a pass — it runs in the same process as Init and gave a false green on beta.1. The sync is the real test. |
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

### Probe H — webhooks *(half answered)*

The **ImmyBot side is confirmed** from `Example - Inbound Webhook.ps1`:
`ISupportsHttpRequest` / `-HandleHttpRequest`, answering at
`plugins/api/v1/{providerLinkId}`. beta.2 implements it and it is **live**.

Still open on the **ConnectWise side:** does the Platform support outbound
webhooks or event subscriptions at all? If so, how is a receiver URL registered
and which events fire?

The handler is inert by design — it logs the payload and returns 200. Point a CW
webhook (or a manual `curl`) at the integration's plugin URL and the log will
show you the exact payload shape, which is what any real handling needs.

### Probe J — console URL for an endpoint *(blocks: agent deep-link)*

`ISupportsExternalProviderAgentUrl` lets ImmyBot show a link straight to the
device in the vendor console — DattoRMM builds
`https://{platform}.rmm.datto.com/device/{id}`.

**Tell me:** the URL of an endpoint's page in the ConnectWise Platform console,
and which id it keys on (the same endpoint GUID we emit as `AgentId`?).

Set `ConsoleUrlTemplate` in the module config to e.g.
`https://.../endpoint/{endpointId}`. Empty (the default) returns `$null` and
ImmyBot shows no link — a wrong URL would send techs to a 404 mid-incident,
which is worse than no link.

### Probe K — device/token field names *(RESOLVED 2026-08-24, no probe needed)*

Answered by the published API reference before the worksheet was ever run.
Kept because the wrong value cost a full install cycle and the failure gave no
hint what to change.

beta.2 shipped the request body as `clientID` and the live API answered:

```
POST {endpoint}/api/platform/v1/device/token
{ "clientID": "<companyId>", "siteID": "<siteId>" }

-> HTTP 400
   { "code": "bad_request", "message": "ErrClientIDNotAllowed" }
```

The reference is unambiguous:

| | |
| --- | --- |
| Body | `{ "companyID": "<uuid>", "siteID": "<uuid>" }` |
| api-scope | `platform.devices.read` |
| 200 | a bare JSON string — `"f4b2990c-075a-4132-967c-2fa3431e89df"` |
| 400 | missing companyID or siteID, e.g. `ErrCompanyIDNotProvided` |
| 401 | `access_denied` / bearer token is invalid |
| 429 | rate limited, `text/plain` body |

So `ErrClientIDNotAllowed` was the endpoint reporting an absent `companyID`,
not a permissions problem. Both readings the worksheet proposed were wrong:
the field name was simply incorrect.

Three things follow.

**The scope was never the issue.** The documented scope is
`platform.devices.read`, which the read scope in `Get-CwScope` already
requests. No `-IncludeWrite` and no agent-token create scope are needed — a
POST here does not imply a write scope.

**The 200 body confirms the GUID validation.** The response is a bare UUID
string, which is exactly what `New-CwInstallToken` and the install script both
check for. Those two gates are correct as written.

**The call is get-or-create, not create.** "If a token already exists for that
mapping, the existing value is returned." Re-running an install against the
same company/site pairing is therefore safe and idempotent, and does not
accumulate tokens.

`tests/Test-CwHelpers.ps1` now pins `companyID`/`siteID` and fails on
`clientID`, verified by mutation.

### Probe I — server install *(blocks: AllowServerInstall)*

Not an API question — a ConnectWise support question.

**Tell me:** the correct `SYSTEM=` MSI property value for a server install.
`software/Install-CWPlatform.ps1` has `$AllowServerInstall = $false` and
`$ServerSystemType = 'server'` (a guess). Do not enable it on production until
confirmed; a wrong mode registers but licenses and monitors incorrectly.

---

## 3b. Repointing the Agent Integration is a two-step change

Found in situ 2026-08-24, on the first run that ever reached
`GetTenantInstallToken`.

Changing the Software entry's **Advanced > Agent Integration** to a new
integration id does **not** re-link the deployments that use it. The install
script fails with ImmyBot's own message:

```
An integration is not linked to this script. If this script was run during a
maintenance session, re-save the deployment associated with this script's
action to ensure the integration is linked.
```

The earlier symptom in the same session is the detection stage logging:

```
Unable to determine provider link id for ConnectWise Platform.
Skipping dynamic version check.
```

Both are the same missing link. The fix is ImmyBot's own instruction: open the
**deployment** for the software and re-save it. Then confirm, in order:

1. Software > Advanced > Agent Integration points at the intended integration
2. The deployment has been re-saved since that change
3. The tenant is mapped under Integration > Clients

This matters beyond the beta: integration 245 was deleted and replaced by 313,
so **every** deployment carrying the old link needs re-saving, not just the one
used for testing.

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
pwsh -File tests/Test-ConstrainedLanguage.ps1   #  8 assertions — language-mode compliance
pwsh -File tests/Test-CwHelpers.ps1             # 47 assertions — module logic
pwsh -File tests/Test-IntegrationStructure.ps1  # 17 assertions — script/module contract
```

The first covers client-ref parsing, `Link` header pagination, batching, site-id
resolution, scope selection and the token cache. The second enforces the contract
beta.1 broke: every capability block must import the module, the script may only
call exported functions, and `[scriptblock]::Create` must not reappear.

Both run on Windows PowerShell 5.1 as well as pwsh 7.

CI (`.github/workflows/validate.yml`) runs the parse check and these tests as
hard gates, plus PSScriptAnalyzer as advisory. It previously triggered on
`main`, which does not exist in this repo — **CI had never run.**
