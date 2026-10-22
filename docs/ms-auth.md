# PowerShell / Microsoft Graph / Exchange Online: Auth Rules

This is the single source of truth for tenant auth in this toolkit. The `ms-tenant` skill
defers to it.

**Standing rule:** every script that runs against a tenant reuses cached credentials or
the daemon. Never trigger a fresh interactive sign-in per run. Writes and any Exchange
Online work go through the daemon; read-only Graph may use `Connect-Tenant` standalone.
Never call bare `Connect-MgGraph` / `Connect-ExchangeOnline`.

## Requirements

| Component | Windows | macOS |
|-----------|---------|-------|
| PowerShell 7.4+ | `winget install Microsoft.PowerShell` | `brew install powershell` |
| Microsoft.Graph.Authentication (+ the Graph submodules you use) | `Install-Module Microsoft.Graph -Scope CurrentUser` | same |
| ExchangeOnlineManagement 3.x | `Install-Module ExchangeOnlineManagement -Scope CurrentUser` | same |
| Azure CLI (read-only fast path) | `winget install Microsoft.AzureCLI` | `brew install azure-cli` |
| Python 3 (only for the optional macOS sign-in router) | n/a | ships with Xcode CLT |

## Tenant config

Tenants live in `config/tenants.json` (copy `config/tenants.example.json`). Each entry has
the tenant **GUID**, the Azure subscription (optional), the admin account used for Graph
and EXO, and the browser profile label used by the macOS router. The file is git-ignored.
Set `MS_TENANT_TOOLKIT_CONFIG` to keep it somewhere else.

## Script-authoring checklist (every time)

1. **Reading only?** Standalone `pwsh -File` with `Connect-Tenant -Tenant <T>` (silent az
   token), or the daemon. Both are fine.
2. **Making a change, or touching Exchange Online?** The daemon
   (`Invoke-TenantJob.ps1 -Tenant <T> -ScriptPath job.ps1`). The job script contains NO
   `Connect-*` / `Disconnect-*` calls.
3. **Never** call bare `Connect-MgGraph` / `Connect-ExchangeOnline`, and never set the MSAL
   suppression variables. Device code only through `Start-TenantDaemon.ps1 -DeviceCode` /
   `Connect-Tenant -DeviceCode`.
4. Always identify the tenant by **GUID**; warn the user before any cold EXO/daemon sign-in.
5. **Starting or restarting a daemon:** run `Start-TenantDaemon.ps1 -Tenant <T>` (add
   `-Force` only for a wedged or dead daemon) with a one-line heads-up to the user.

## Sign-in behavior by platform

**Windows.** Microsoft.Graph and ExchangeOnlineManagement sign in through the Windows
account broker (WAM). The prompt is an account picker, not a browser tab, so browser
profiles never come into it. The daemon is started in a minimized console window because
WAM needs a parent window for its prompt. Tokens are cached per user with DPAPI.

**macOS.** MSAL opens the sign-in with a hard-coded `/usr/bin/open <url>`, so the page
lands in whichever browser profile was used last. Two options:

- `-DeviceCode`: nothing is launched; a URL and a code are printed and you open them in
  the right profile yourself.
- The optional **sign-in router** (`scripts/ps-session/signin-router.py`). Enable it with
  `SignInRouter.Enabled: true` in `tenants.json` and set the browser (any Chromium browser
  with AppleScript tab access) and each tenant's `BrowserProfile` label. It runs beside
  each daemon for the daemon's whole life:
  1. Every ~0.75s it checks (one `lsof`) whether the daemon has a localhost listener.
     MSAL opens one only while an interactive sign-in is in progress.
  2. While it does, it scans the browser's tabs for a `login.microsoftonline.com` URL
     whose `redirect_uri` is **that listener's port**. The port proves which daemon owns
     the page, so two tenants signing in at once cannot be confused.
  3. It closes that tab and reopens the identical URL in the tenant's profile. The URL
     carries MSAL's state + PKCE, and the redirect returns to localhost, so it completes
     from any profile.
  4. When the sign-in completes it closes MSAL's leftover "Authentication complete" tab.

  Tokens are cached in the macOS Keychain.

**The backstop is in the daemon, not the routing.** `daemon.ps1` compares the tenant id it
actually connected to, Graph and EXO separately, against `tenants.json`. On a mismatch it
logs `FATAL: signed in to the WRONG TENANT`, removes its PID file and exits without
serving a single job. On success it logs `Verified: Graph tenant <guid> as <account>, matches <T>.`

## DEFAULT for all tenant work: the persistent daemon

Use the daemon for **any** tenant work that makes changes, and for anything touching
Exchange Online (including `Search-UnifiedAuditLog`). It signs in **once per tenant** with
a full read+write Graph scope set **plus** EXO, then stays alive, so every later read and
write runs silently through the same session.

```powershell
@'
Update-MgUser -UserId user@contoso.com -AccountEnabled:$false
Search-UnifiedAuditLog -StartDate (Get-Date).AddDays(-7) -EndDate (Get-Date) -ResultSize 5000
'@ | Set-Content ./job.ps1

pwsh ./scripts/ps-session/Invoke-TenantJob.ps1 -Tenant CONTOSO -ScriptPath ./job.ps1 -TimeoutSeconds 120
```

**Rules for job scripts:**
- No `Connect-*` or `Disconnect-*` calls; the daemon handles auth.
- Graph cmdlets and EXO cmdlets are both available.
- The daemon holds the full write-capable scope set, so changes never trigger a fresh
  consent prompt mid-session.
- The daemon auto-reconnects if the Graph or EXO session drops.

**Lifecycle:**
```powershell
pwsh ./scripts/ps-session/Start-TenantDaemon.ps1 -Tenant CONTOSO          # start (or attach the router)
pwsh ./scripts/ps-session/Start-TenantDaemon.ps1 -Tenant CONTOSO -Force   # restart a wedged/dead one
pwsh ./scripts/ps-session/Stop-TenantDaemon.ps1  -Tenant CONTOSO          # stop
Get-Content ./scripts/ps-session/daemon-CONTOSO.log -Tail 20             # status + granted scopes
```

How the launcher stays honest:
- Readiness is judged from `daemon-<T>.out.log`, which is overwritten on every start, so
  a `Ready.` left behind by a daemon that has since died can never satisfy it.
- `daemon-<T>.log` (the daemon's own log) is rotated past 5 MB.
- `Stop-TenantDaemon.ps1` escalates (SIGTERM then kill on macOS/Linux, forced stop on
  Windows), sweeps for orphan daemon processes no PID file names, and exits 3 if anything
  survives. `-Force` refuses to start a second daemon in that case.
- `daemon.ps1` refuses to start if another live daemon owns the same job queue.

**When to use direct `pwsh -File` instead:** read-only Graph queries and one-off reads
where a daemon is overkill. Do NOT run writes standalone: the az token lacks
`.ReadWrite`/Intune scopes, so each change would prompt a sign-in.

## Microsoft Graph: Connect-Tenant.ps1 (never bare Connect-MgGraph)

```powershell
. ./scripts/Connect-Tenant.ps1
Connect-Tenant -Tenant CONTOSO                 # read-only: az CLI token, always silent
Connect-Tenant -Tenant CONTOSO -Interactive    # read+write: full scopes, cached per user
```

- **Default (read-only):** uses the `az` CLI token cache. Silent, ~0.5-1s. The az token
  only carries the Azure CLI app's scopes, so it is fine for reads but usually LACKS the
  `.ReadWrite` / Intune scopes needed for changes.
- **`-Interactive` (read+write):** `Connect-MgGraph -Scopes $DefaultGraphScopes
  -ContextScope CurrentUser`. Sign-in at most once, silent afterwards while the refresh
  token is valid. This is the mode the daemon uses.

Both modes reuse an existing session; `-Interactive` only reuses one that already carries
every required scope.

**If az tokens expire:** `az login --tenant <tenantId> --allow-no-subscriptions`

## Exchange Online

```powershell
. ./scripts/Connect-Tenant.ps1
Connect-Tenant -Tenant CONTOSO -Exo      # Graph + Exchange Online
Connect-Tenant -Tenant CONTOSO -ExoOnly  # Exchange Online only
```

Uses `Connect-ExchangeOnline -UserPrincipalName <account> -Organization <guid>`. Cached
token: silent. Cold cache: one sign-in. Batch EXO commands in a single pwsh process.

The az CLI token does NOT work for EXO: the Azure CLI app has no Exchange management
plane permissions.

## Az / Azure

```powershell
$azContext = Get-AzContext
if (-not $azContext -or $azContext.Tenant.Id -ne $TenantId) {
    Connect-AzAccount -Tenant $TenantId
}
```

## Teams

```powershell
try { Get-CsTenant -ErrorAction Stop | Out-Null }
catch { Connect-MicrosoftTeams -TenantId $TenantId }
```

The MicrosoftTeams module needs its own sign-in per tenant; it is not held by the daemon.

## General rules for all Connect-* calls

- Always pass an explicit `-Tenant` / `-TenantId` / `-Organization`.
- Use the **GUID**, not the domain: `Get-MgContext` stores TenantId as a GUID, so domain
  comparisons always fail and force a reconnect.
- Never use `-ContextScope Process` for Graph (tokens lost on pwsh exit).
- No device code except the `-DeviceCode` fallback; no certificate auth or client secrets
  unless explicitly asked.
- Do NOT set `MSAL_NO_SYSTEM_KEYCHAIN` or `MSAL_DISABLE_SYSTEM_TOKEN_BROKER`.
