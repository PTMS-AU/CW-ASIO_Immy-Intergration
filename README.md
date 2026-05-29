# ConnectWise RMM (ASIO) — ImmyBot Integration

An ImmyBot Dynamic Integration and software package that lets ImmyBot deploy and
manage the ConnectWise RMM (ASIO Partner Platform) agent on Windows endpoints.

Built and tested against the **AU** region
(`openapi.service.auplatform.connectwise.com`). Works regionally — only the API
endpoint URL changes for EU/US.

## What this gives you

- **List ConnectWise companies as ImmyBot clients** and map them to tenants.
- **List ConnectWise endpoints as agents** with live online status (via the ASIO
  heartbeat endpoint).
- **Inventory identification** — match an ImmyBot computer to its ASIO endpoint
  automatically by reading `privateendpointid` from the registry.
- **Deploy the ASIO agent** to managed machines, with per-tenant install tokens
  fetched at install time and passed to the MSI as `TOKEN=<guid>`.
- **Webhook receiver stub** ready for extension.

## Repo layout

```
integration/   The ImmyBot Dynamic Integration script (paste into Integrations)
software/      The five software-package scripts (paste into the Software entry)
docs/          The full integration guide (open in a browser, or upload to Rewst)
```

| Folder | File | Paste into |
| --- | --- | --- |
| `integration/` | `ConnectWiseRMM-Integration.ps1` | Integrations → New Dynamic Integration |
| `software/` | `Detect-Asio.ps1` | Software → Custom Detection Script |
| `software/` | `Get-AsioAgentDownloadLink.ps1` | Software → Dynamic Versions |
| `software/` | `Install-Asio.ps1` | Software → Install Script |
| `software/` | `Uninstall-Asio.ps1` | Software → Uninstall Script |
| `software/` | `Test-Asio.ps1` | Software → Test Script |

## Getting started

The full guide is at [`docs/ConnectWise-ASIO-Integration-Guide.html`](docs/ConnectWise-ASIO-Integration-Guide.html).
Quick version:

1. **Generate an ASIO API key** in ConnectWise: Integrations → Asio Integrations → Integrate → Generate.
   Grant all available scopes (the integration uses six read scopes; over-granting
   on the key is harmless). Copy the secret immediately — it's only shown once.
2. **Add the integration in ImmyBot**: Integrations → New Dynamic Integration. Paste
   `integration/ConnectWiseRMM-Integration.ps1`. Configure with the API endpoint
   URL, Client ID, and Client Secret. Initialise — it should go Healthy.
3. **Map tenants to companies**: Integration → Clients tab. Each ImmyBot tenant
   needs to be mapped to a ConnectWise company for installs to work.
4. **Create the software entry**: paste each `software/*.ps1` script into its slot
   per the table above. Under Advanced, set Agent Integration to the integration
   you created in step 2. Set Uninstall's Detection String to `SaazOnDemand|ITSPlatform`.
5. **Deploy** to a test machine. Confirm it installs, registers (the test script
   verifies both), and shows up as an agent in the integration.

## Important operational notes

- **The installer MSI is hosted on Azure Blob Storage**, not ConnectWise's CDN.
  ConnectWise serves the generic barebone MSI via a redirect chain that ImmyBot's
  downloader can't follow. The blob mirror is a direct download. **This means
  the file needs refreshing periodically** — see the doc's §8 for the process.
  Recommend quarterly.
- **Detection returns a fixed `1.0.0`**, not the real installed agent version.
  ASIO self-updates, so the real version drifts away from any MSI bootstrapper
  version. The pack treats the agent as a binary installed/healthy check, not
  a versioned product. See the doc's §10.1 for the reasoning.
- **OAuth tokens request the full read scope set on every call.** Not least
  privilege. The reasoning is in the doc's §7.2 — earlier per-capability scoping
  caused a class of "token scoped for X, endpoint gated by Y" bugs that all
  resolved cleanly when we standardised on one broad scope string.
- **Workstations only.** The install script gates on `Win32_OperatingSystem.ProductType == 1`.
  Server install needs a different `SYSTEM=` property value that hasn't been
  validated. To add server support, see the doc's §10.5.

## Maintaining this repo

Before committing changes, make sure the live ImmyBot integration matches the
files in this repo. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the workflow.

## Troubleshooting

See [`docs/ConnectWise-ASIO-Integration-Guide.html`](docs/ConnectWise-ASIO-Integration-Guide.html) §9.
The doc captures the specific failure modes we hit during development and what
they meant — most likely whatever you're hitting is in there.
