# Contributing

## The golden rule

**The repo and the live ImmyBot instance must stay in sync.** This is the only
operational discipline that matters. Everything else is convention.

The integration script and the five software-package scripts each exist in two
places: this repo, and the ImmyBot UI. Drift between them is how things break.
Drift usually starts with a "quick fix" pasted into ImmyBot that never made it
back into git, and is discovered weeks later when something else changes and
the repo turns out to be stale.

## Workflow for any change

### 1. Decide where the change starts

- **Starting in ImmyBot** (e.g. debugging in the UI, pasting in a tweak to see
  if it fixes something) — once it works, paste the change back into the repo
  file *immediately*, run the pre-commit check, and commit. Don't leave the
  fix only in ImmyBot.
- **Starting in the repo** (deliberate refactor, code review) — edit, commit,
  then paste the updated file(s) into ImmyBot and re-initialise the integration
  or re-save the software entry.

### 2. Pre-commit check

Before every commit, confirm the file you're committing matches what's live in
ImmyBot. The quickest way:

1. Open the file in your editor.
2. Open the corresponding script in the ImmyBot UI.
3. Diff them mentally, or paste both into a diff tool. They should be identical
   except for line-ending differences (Windows CRLF vs Unix LF).

If they differ, decide which version is correct, update the other, and only
then commit.

### 3. Commit messages

Be specific. The history is your changelog. Useful patterns:

```
integration: add ProviderClientId fallback in GetTenantInstallToken
software/install: gate on workstation only (ProductType == 1)
docs: refresh troubleshooting section for scope-mismatch failures
```

Less useful:

```
fixes
update
asio stuff
```

If a commit fixes a specific failure mode, mention the symptom in the message
body so future grep finds it:

```
software/install: throw if token isn't a GUID

Catches the case where Get-IntegrationAgentInstallToken returns an error
string or malformed value before we hand garbage to msiexec TOKEN=.
Symptom this prevents: silent install of an unregistered agent.
```

### 4. Tag releases

When the integration reaches a known-good state (e.g. after a successful
test deployment to a real client), tag it:

```
git tag -a v1.0.0 -m "First stable AU deployment — Platinum Technology"
git push --tags
```

Tags are how you roll back if a later change breaks something live. They're
also how you remember which version of the scripts was running on a given
date.

## What goes in this repo, what doesn't

### Goes in

- The six PowerShell scripts (`integration/` and `software/`)
- The HTML integration guide (`docs/`)
- README.md, LICENSE, .gitignore, this file
- Future: regional URL tables, server-install variants, additional
  capability implementations (e.g. webhook handlers, uninstall token)

### Doesn't go in

- **Credentials.** Ever. The integration takes them as runtime parameters
  in ImmyBot. No script should contain a Client ID, Client Secret, or any
  other credential. The `.gitignore` blocks the most likely accident paths,
  but the actual defence is don't put them in the scripts in the first place.
- **Working notes / scratch.** Use `notes/` or `*.local.md` — gitignored.
- **Test outputs, downloaded MSIs, audit log dumps.** Gitignored by default.
- **The saved ConnectWise / ImmyBot HTML docs from the original research zip.**
  They're large, they go stale, and they aren't ours to redistribute.
- **The OpenAPI spec YAML.** It's ConnectWise's spec. Useful for reference
  during development; not appropriate for a published repo.

## Adding new capability implementations

The integration is already structured one capability per block, separated by
clearly labelled `# =====` headers. To add a new capability:

1. Identify the ImmyBot interface name (e.g. `ISupportsTenantUninstallToken`).
2. Add a new block following the same pattern as existing capabilities:
   token request → API call → error capture → emit result.
3. Use the same OAuth scope string as the other blocks unless you have a
   specific reason to narrow it (see the doc's §7.2 for the reasoning).
4. Update the HTML guide's §6 (Capabilities) and §11 (Change history).
5. Update README.md if the capability changes how users set things up.

## Updating the installer MSI on blob storage

This is an operational task that doesn't live in git, but commit a note when
you do it:

1. Download the current generic MSI from
   `https://setup.auplatform.connectwise.com/windows/BareboneAgent/32/ITSagent/MSI/setup`
2. Upload it to the blob container as `ITSPlatform.msi`, replacing the existing
   file.
3. Commit a note to this repo: `chore: refresh hosted MSI from ConnectWise (YYYY-MM-DD)`.
4. The script doesn't change — only the file behind the URL does. The commit
   exists purely to record the refresh date.

## Regional variants

If a second region is added (EU, US), the cleanest pattern is to keep one
integration script and document the per-region API endpoint URL in the README
and the HTML guide. Do *not* fork the script. The only thing that changes
per-region is the URL passed into Init at configuration time.
