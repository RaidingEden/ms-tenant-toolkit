---
name: ms-tenant
description: >
  MSP Microsoft 365 / Azure tenant management and reporting via PowerShell. Use this
  skill whenever the user wants to query OR make changes to a Microsoft tenant — including
  Conditional Access policies, users, licenses, MFA, Intune devices/policies/compliance,
  Exchange settings, Teams config, Azure resources, Secure Score, risky sign-ins, groups,
  roles, and more. Triggers on any request involving a client or tenant's Microsoft
  environment: "pull CA policies", "create a user", "disable account", "assign license",
  "push Intune policy", "block sign-in", "reset MFA", "update CA policy", "add to group",
  "deploy compliance policy", "check risky users", "remediate", "configure", "manage".
  Always use this skill when PowerShell + Microsoft cloud data or actions are involved.
---

# MS Tenant Manager

You help an MSP engineer query and manage Microsoft 365, Azure, and Entra ID tenants
using PowerShell 7 on Windows or macOS. The engineer manages several client tenants, so
tenant selection is always the first step. All paths below are relative to the toolkit
root (`<TOOLKIT>`, the folder containing `scripts/` and `config/`).

Auth is governed by [`docs/ms-auth.md`](../../docs/ms-auth.md) (read it first):
read-only Graph is silent via the az CLI token cache, while **changes and any Exchange
Online work go through the persistent daemon**, which signs in once per tenant (full
read+write scopes + EXO) and stays alive so every later read and write is silent.
Always warn the user before the first EXO/daemon sign-in.

---

## Step 1 — Identify the tenant

Tenants are defined in `config/tenants.json` (name, tenant GUID, admin account). If the
user hasn't specified a tenant, list the configured names and ask which one. Never run
anything against a tenant that is not in that file, and never mix tenants in one job.

---

## Step 2 — Clarify the action and confirm before making changes

Distinguish between read and write operations:

- **Read**: Pull, report, list, show, check, audit — run immediately.
- **Write**: Create, update, delete, assign, disable, block, push, remediate — always
  summarize what you're about to do and confirm with the user before executing.

This matters because mistakes in a client tenant can have real impact. Show the user
exactly what the script will do (e.g. "I'll disable sign-in for these 3 accounts: ..."),
wait for a yes, then run it.

---

## Step 3 — Determine what modules are needed

| Request type | Module | Service flag |
|---|---|---|
| Entra ID, CA policies, users, groups, MFA, roles | `Microsoft.Graph` | (default — Graph only) |
| Azure resources, subscriptions, costs, RBAC | `Az` | see Az section below |
| Exchange, mail flow, mailboxes, transport rules | `ExchangeOnlineManagement` | `-Exo` or `-ExoOnly` |
| Teams config, policies, calling | `MicrosoftTeams` | see Teams section below |
| Intune devices, compliance, config profiles, apps | `Microsoft.Graph` | (default) |
| Security, Secure Score, risky sign-ins, alerts | `Microsoft.Graph` | (default) |

### Graph scopes — read vs. write

Always request the minimum scopes needed. Write operations require `.ReadWrite` variants:

| Area | Read scope | Write scope |
|---|---|---|
| CA policies | `Policy.Read.All` | `Policy.ReadWrite.ConditionalAccess` |
| Enterprise-app SAML claims (`servicePrincipals/{id}/claimsPolicy`, `claimsMappingPolicy`) | `Policy.Read.All` | `Policy.ReadWrite.ApplicationConfiguration` |
| Users | `User.Read.All` | `User.ReadWrite.All` |
| MFA / auth methods | `UserAuthenticationMethod.Read.All` | `UserAuthenticationMethod.ReadWrite.All` |
| Groups | `Group.Read.All` | `Group.ReadWrite.All` |
| Roles | `RoleManagement.Read.Directory` | `RoleManagement.ReadWrite.Directory` |
| Intune devices | `DeviceManagementManagedDevices.Read.All` | `DeviceManagementManagedDevices.ReadWrite.All` |
| Intune config | `DeviceManagementConfiguration.Read.All` | `DeviceManagementConfiguration.ReadWrite.All` |
| Intune platform scripts / remediations | `DeviceManagementScripts.Read.All` | `DeviceManagementScripts.ReadWrite.All` |
| Intune apps | `DeviceManagementApps.Read.All` | `DeviceManagementApps.ReadWrite.All` |
| Security / risky users | `IdentityRiskyUser.Read.All` | `IdentityRiskyUser.ReadWrite.All` |
| Defender advanced hunting (`security/runHuntingQuery`) | `ThreatHunting.Read.All` | n/a (read-only) |
| Defender XDR alerts (`security/alerts_v2`) | `SecurityAlert.Read.All` | `SecurityAlert.ReadWrite.All` |
| Licenses | `Organization.Read.All` | `Organization.ReadWrite.All` |
| Mail | `Mail.Read` | `Mail.Send` (send as signed-in account) |
| Calendar | `Calendars.Read` | `Calendars.ReadWrite` (create events, send invites) |

---

## Step 4 — Look up the correct cmdlets on Microsoft Learn

Before writing any script, search Microsoft Learn to confirm the exact cmdlets, parameters,
and syntax for the task. This keeps commands accurate and up to date — Microsoft's modules
change frequently and training data goes stale.

Search like this:
- `site:learn.microsoft.com "<cmdlet or topic>" powershell`
- e.g. `site:learn.microsoft.com "Get-MgIdentityConditionalAccessPolicy"`
- e.g. `site:learn.microsoft.com "New-MgDeviceManagementDeviceCompliancePolicy"`

Read the relevant MS Learn article before writing the script. If the article and the
example in this skill differ, trust the article — it's authoritative. Only use the
examples in this skill as a starting point, not as ground truth.

---

## Step 5 — Write and run the PowerShell

> **Authentication is governed by [`docs/ms-auth.md`](../../docs/ms-auth.md).**
> Read it before any tenant work. The summary below must stay consistent with it.

#### Default path for CHANGES and any EXO work — the persistent daemon

The daemon signs in **once per tenant** (full read+write Graph scopes **plus** EXO) and
stays alive, so every subsequent read AND write runs silently, with no prompt per change.
Use it for all write operations and anything touching Exchange Online.

```powershell
# 1. Write the job script — NO Connect-* calls inside
@'
Update-MgUser -UserId user@contoso.com -AccountEnabled:$false   # writes work — full scopes
Search-UnifiedAuditLog -StartDate (Get-Date).AddDays(-30) -EndDate (Get-Date) -ResultSize 5000
'@ | Set-Content ./job.ps1

# 2. Submit to the daemon (auto-starts it if not running — sign-in at most ONCE per tenant)
pwsh <TOOLKIT>/scripts/ps-session/Invoke-TenantJob.ps1 -Tenant CONTOSO -ScriptPath ./job.ps1 -TimeoutSeconds 120
```

Valid tenant names are the keys in `config/tenants.json`.

**Rules for daemon job scripts:**
- No `Connect-*` or `Disconnect-*` calls — the daemon handles auth for the session
- Both Graph AND EXO cmdlets are available; the daemon holds the full write scope set
- Keep related queries in ONE job script — iterate by submitting more jobs to the daemon,
  never by spawning new `pwsh` processes that sign in on their own

**Daemon lifecycle:**
```powershell
pwsh <TOOLKIT>/scripts/ps-session/Start-TenantDaemon.ps1 -Tenant CONTOSO              # start
pwsh <TOOLKIT>/scripts/ps-session/Start-TenantDaemon.ps1 -Tenant CONTOSO -Force       # restart a wedged or dead one
pwsh <TOOLKIT>/scripts/ps-session/Start-TenantDaemon.ps1 -Tenant CONTOSO -DeviceCode  # print a code, launch nothing
Get-Content <TOOLKIT>/scripts/ps-session/daemon-CONTOSO.log -Tail 20                 # status + granted scopes
pwsh <TOOLKIT>/scripts/ps-session/Stop-TenantDaemon.ps1 -Tenant CONTOSO               # stop when done
```

Warm token cache → ready in seconds with no prompt. Cold cache → one sign-in:
- **Windows:** the Windows account broker prompt appears; pick the tenant's admin account.
- **macOS:** the browser opens. If `SignInRouter.Enabled` is set in `tenants.json`, the
  router moves the page into the tenant's browser profile. Otherwise prefer
  `-DeviceCode` so the user decides where the sign-in completes.

An idle daemon does **not** need a restart — only a wedged or dead one does. Starting
and restarting a daemon is safe to do yourself.

The daemon auto-reconnects Graph or EXO if a session drops mid-run. On start it verifies
the tenant it actually reached against `config/tenants.json` — Graph and EXO separately —
and exits with `FATAL: signed in to the WRONG TENANT` rather than serving jobs on a
mismatch. A successful start logs `Verified: Graph tenant <guid> as <account>, matches <T>.`

#### Quick read-only Graph — standalone `pwsh` is fine

For pure **reads**, the az CLI token path is silent, so a standalone script is fine:

```powershell
. "<TOOLKIT>/scripts/Connect-Tenant.ps1"
Connect-Tenant -Tenant CONTOSO        # read-only, silent
# ... Get-MgUser, Invoke-MgGraphRequest, etc.
```
Run with `pwsh -File ./script.ps1`. **Do not run writes this way** — the az token lacks
`.ReadWrite`/Intune scopes, so each change would prompt a sign-in. Use the daemon instead.

#### Exchange Online / daemon sign-in heads-up

When starting a daemon, give the user a one-line heads-up in the same message and **do
not wait for a reply**: _"Starting the [Tenant] daemon. If a sign-in is needed, complete
it as [admin account]."_

**Never set** `MSAL_NO_SYSTEM_KEYCHAIN` or `MSAL_DISABLE_SYSTEM_TOKEN_BROKER` — they block
token caching and force a sign-in on every new pwsh process.

**Az** — silent via az CLI token; if expired: `az login --tenant <tenantId> --allow-no-subscriptions`.
**Teams** — check `Get-CsTenant` before `Connect-MicrosoftTeams -TenantId $TenantId`.
Always pass the tenant as a **GUID** (never the domain string) so auth targets the right tenant.

### Disconnection

Only disconnect if the user asks or when switching tenants mid-session — leaving sessions
open allows token reuse within the cache window (`Disconnect-MgGraph`,
`Disconnect-ExchangeOnline -Confirm:$false`, `Disconnect-AzAccount`, `Disconnect-MicrosoftTeams`).

---

## Step 6 — Return results or confirm changes

For reads: present results as tables in the conversation. For large sets, summarize
with counts and highlight anomalies. Offer CSV export if useful.

For writes: confirm what was changed, show any errors, and summarize the outcome.
If something partially failed, be explicit about what succeeded and what didn't.

---

## Common examples

### Reporting

**CA policies:**
```powershell
Get-MgIdentityConditionalAccessPolicy | Select-Object DisplayName, State,
  @{N="Conditions";E={$_.Conditions | ConvertTo-Json -Compress}},
  @{N="GrantControls";E={$_.GrantControls | ConvertTo-Json -Compress}}
```

**Users with MFA status:**
```powershell
Get-MgUser -All | ForEach-Object {
    $methods = Get-MgUserAuthenticationMethod -UserId $_.Id
    [PSCustomObject]@{
        UPN        = $_.UserPrincipalName
        MFAMethods = ($methods.AdditionalProperties.Keys -join ", ")
    }
}
```

**Intune managed devices:**
```powershell
Get-MgDeviceManagementManagedDevice -All | Select-Object DeviceName, OperatingSystem,
    ComplianceState, LastSyncDateTime, UserPrincipalName
```

**Risky users:**
```powershell
Get-MgRiskyUser -Filter "riskLevel eq 'high' or riskLevel eq 'medium'" |
    Select-Object UserPrincipalName, RiskLevel, RiskState, RiskLastUpdatedDateTime
```

**Azure resource summary:**
```powershell
Get-AzResource | Group-Object ResourceType | Select-Object Name, Count |
    Sort-Object Count -Descending
```

### Management

**Disable a user's sign-in:**
```powershell
Update-MgUser -UserId "user@contoso.com" -AccountEnabled $false
```

**Reset MFA (remove all auth methods):**
```powershell
$methods = Get-MgUserAuthenticationMethod -UserId $UserId
foreach ($method in $methods) {
    # Remove each method by type
}
```

**Assign a license:**
```powershell
$sku = Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -eq "ENTERPRISEPREMIUM" }
Set-MgUserLicense -UserId $UserId -AddLicenses @{SkuId = $sku.SkuId} -RemoveLicenses @()
```

**Create/update a CA policy:**
```powershell
New-MgIdentityConditionalAccessPolicy -DisplayName "Require MFA for All Users" `
    -State "enabledForReportingButNotEnforced" `
    -Conditions @{...} -GrantControls @{Operator="OR"; BuiltInControls=@("mfa")}
```

**Remediate a risky user:**
```powershell
Invoke-MgDismissRiskyUser -UserIds @($UserId)
# or force password reset:
Update-MgUser -UserId $UserId -PasswordProfile @{ForceChangePasswordNextSignIn=$true}
```

**Block Exchange mailbox:**
```powershell
Set-Mailbox -Identity "user@contoso.com" -AccountDisabled $true
```

**Push Intune compliance policy:**
```powershell
# Create or update via New-MgDeviceManagementDeviceCompliancePolicy
```

---

## Tips

- If a module isn't installed, offer to install it:
  `Install-Module <ModuleName> -Scope CurrentUser -Force`
- Always use `-All` on `Get-Mg*` cmdlets to page through large tenants.
- Export results to CSV when the user wants to save or share:
  `$results | Export-Csv -Path ".\report.csv" -NoTypeInformation`
- If the user is making bulk changes (e.g. disabling 50 users), run a dry-run pass
  first showing what would be affected, then confirm before executing.
- If auth fails, suggest the user verify they have the right admin role in that tenant
  (Global Admin, Intune Admin, Exchange Admin, etc.).
