# ms-tenant-toolkit

PowerShell toolkit and Claude skill for managing several Microsoft 365 / Entra / Intune
tenants from one machine, with strict per-tenant isolation. Runs on **Windows and macOS**
with PowerShell 7.

## What's in it

| Path | Purpose |
|------|---------|
| `skills/ms-tenant/SKILL.md` | Claude skill: tenant selection, read vs write confirmation, scopes, examples |
| `docs/ms-auth.md` | Auth rules (single source of truth for the skill) |
| `config/tenants.example.json` | Template for your tenant table |
| `scripts/TenantConfig.ps1` | Loads the tenant table |
| `scripts/Connect-Tenant.ps1` | Connect Graph (read-only az token or read+write) and Exchange Online by tenant GUID |
| `scripts/ps-session/daemon.ps1` | Long-lived per-tenant session that runs job scripts; refuses to serve if signed in to the wrong tenant |
| `scripts/ps-session/Start-TenantDaemon.ps1` | Start / restart a daemon, wait for verified readiness |
| `scripts/ps-session/Stop-TenantDaemon.ps1` | Stop a daemon and prove it's gone (incl. orphans) |
| `scripts/ps-session/Invoke-TenantJob.ps1` | Submit a job script to a tenant's daemon and print the output |
| `scripts/ps-session/signin-router.py` | Optional, macOS only: move MSAL sign-ins into the tenant's browser profile |

## Setup

1. Install PowerShell 7, `Microsoft.Graph`, `ExchangeOnlineManagement` and the Azure CLI
   (commands in `docs/ms-auth.md`).
2. Copy the config and fill in your tenants (GUIDs, not domains):
   ```powershell
   Copy-Item config/tenants.example.json config/tenants.json
   ```
3. For the read-only fast path, sign the Azure CLI in to each tenant once:
   ```powershell
   az login --tenant <tenant-guid> --allow-no-subscriptions
   ```
4. Start a daemon and run a job:
   ```powershell
   pwsh ./scripts/ps-session/Start-TenantDaemon.ps1 -Tenant CONTOSO
   'Get-MgOrganization | Select-Object DisplayName, Id' | Set-Content ./job.ps1
   pwsh ./scripts/ps-session/Invoke-TenantJob.ps1 -Tenant CONTOSO -ScriptPath ./job.ps1
   ```
5. To use the skill with Claude Code, copy or symlink `skills/ms-tenant` into your
   skills folder and replace `<TOOLKIT>` in `SKILL.md` with the path to this repo.

## Isolation model

- One daemon per tenant, each with its own job queue and its own Microsoft session.
- Every connection is pinned to the tenant GUID from `tenants.json`.
- `daemon.ps1` verifies the tenant it actually reached (Graph and EXO separately) and
  exits instead of serving jobs on a mismatch.
- `config/tenants.json` and all runtime state (logs, PID files, job results) are git-ignored.
