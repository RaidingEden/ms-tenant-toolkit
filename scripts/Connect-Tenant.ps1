# Connect-Tenant.ps1
# Connects to a tenant's Microsoft Graph and/or Exchange Online. Works on Windows, macOS
# and Linux with PowerShell 7.
#
# Tenants come from config/tenants.json (see TenantConfig.ps1). Always connects by
# tenant GUID, never by domain.
#
# Graph has TWO modes:
#   Default (read-only, silent): uses the az CLI token cache, so no browser, ~0.5-1s.
#     The az token only carries the Azure CLI app's consented scopes, so it is fine
#     for reads but usually LACKS the .ReadWrite / Intune scopes needed for changes.
#   -Interactive (read + write): Connect-MgGraph -Scopes $DefaultGraphScopes with
#     -ContextScope CurrentUser. Grants the full write-capable scope set and persists
#     the token in the user's MSAL cache (macOS Keychain / Windows DPAPI). Prompts at
#     most once, silent afterwards while the refresh token is valid. This is the mode
#     the persistent daemon uses so every read AND write runs silently all session.
#     On Windows, sign-in goes through the Windows account broker (WAM) by default.
#
# Exchange Online: Connect-ExchangeOnline -UserPrincipalName, using the same MSAL cache.
#   - First connection may open one sign-in; later calls (even in new pwsh processes)
#     are silent while the token is cached.
#   - Batch EXO commands in a single pwsh process to reuse the session.
#
# Usage:
#   . ./scripts/Connect-Tenant.ps1
#   Connect-Tenant -Tenant CONTOSO                    # Graph read-only (az token, silent)
#   Connect-Tenant -Tenant CONTOSO -Interactive       # Graph read+write (full scopes)
#   Connect-Tenant -Tenant CONTOSO -Exo               # Graph + Exchange Online
#   Connect-Tenant -Tenant CONTOSO -Interactive -Exo  # Graph read+write + EXO (daemon default)
#   Connect-Tenant -Tenant CONTOSO -ExoOnly           # Exchange Online only

. (Join-Path $PSScriptRoot "TenantConfig.ps1")

# Full read+write Graph scope set for management work. Mirrors the scope table in
# skills/ms-tenant/SKILL.md; keep the two in sync when adding capabilities.
$DefaultGraphScopes = @(
    "User.ReadWrite.All"
    "Group.ReadWrite.All"
    "Directory.ReadWrite.All"
    "Policy.Read.All"
    "Policy.ReadWrite.ConditionalAccess"
    "Policy.ReadWrite.ApplicationConfiguration"   # enterprise-app SAML claims (claimsPolicy)
    "RoleManagement.ReadWrite.Directory"
    "UserAuthenticationMethod.ReadWrite.All"
    "DeviceManagementManagedDevices.ReadWrite.All"
    "DeviceManagementConfiguration.ReadWrite.All"
    "DeviceManagementScripts.ReadWrite.All"       # Intune platform scripts + remediations (create/assign/status)
    "DeviceManagementApps.ReadWrite.All"          # Intune apps (Win32/LOB/store): read + assignments
    "IdentityRiskyUser.ReadWrite.All"
    "Organization.ReadWrite.All"
    "CloudPC.ReadWrite.All"
    "Mail.Send"                                   # send mail as the signed-in account
    "Calendars.ReadWrite"                         # create/update events and send meeting invites
    "ThreatHunting.Read.All"                      # Defender advanced hunting (security/runHuntingQuery), read-only
    "SecurityAlert.Read.All"                      # Defender XDR alerts (security/alerts_v2), read-only
)

function Connect-Tenant {
    param(
        [Parameter(Mandatory)]
        [ArgumentCompleter({ param($c, $p, $word) $TenantConfig.Keys | Where-Object { $_ -like "$word*" } })]
        [string]$Tenant,
        [string[]]$Scopes = $DefaultGraphScopes,  # used in -Interactive mode
        [switch]$Interactive,      # Graph read+write via Connect-MgGraph -Scopes (full scope set)
        [switch]$Exo,              # connect Graph + Exchange Online
        [switch]$ExoOnly,          # connect Exchange Online only
        # Device-code sign-in. Prints a URL and a code instead of launching a browser,
        # so YOU choose which browser profile completes it. On macOS the interactive path
        # opens the default browser, which routes to whichever profile window was last
        # active: the one failure mode that puts a client's session in another client's
        # profile. Use this when the token cache is cold, over SSH, or any time the
        # profile has to be certain rather than likely.
        [switch]$DeviceCode
    )

    $Tenant = Assert-TenantName $Tenant
    $cfg = $TenantConfig[$Tenant]

    # --- Graph ---
    if (-not $ExoOnly) {
        $ctx = Get-MgContext
        $sameTenant = $ctx -and $ctx.TenantId -eq $cfg.TenantId
        # In -Interactive mode, only reuse a session that already carries every required scope,
        # otherwise a read-only (az token) session would silently miss write scopes.
        $scopesOk = (-not $Interactive) -or ($ctx -and -not ($Scopes | Where-Object { $_ -notin $ctx.Scopes }))

        if ($sameTenant -and $scopesOk) {
            Write-Host "Reusing existing Graph session for $($ctx.Account)" -ForegroundColor DarkGray
        }
        elseif ($Interactive) {
            # Full read+write scopes; persists the token to the user's MSAL cache (CurrentUser).
            # Sign-in at most once, silent afterwards while the refresh token is valid.
            if ($DeviceCode) {
                Write-Host "DEVICE CODE SIGN-IN for $Tenant Graph: open the URL below in the $Tenant browser profile." -ForegroundColor Yellow
                Connect-MgGraph -Scopes $Scopes -TenantId $cfg.TenantId `
                    -ContextScope CurrentUser -NoWelcome -UseDeviceCode
            } else {
                Connect-MgGraph -Scopes $Scopes -TenantId $cfg.TenantId `
                    -ContextScope CurrentUser -NoWelcome
            }
            $granted = (Get-MgContext).Scopes -join ", "
            Write-Host "Connected to $Tenant (interactive) as $((Get-MgContext).Account)" -ForegroundColor Green
            Write-Host "Granted scopes: $granted" -ForegroundColor DarkGray
        }
        else {
            # Read-only fast path: az CLI token, always silent, no browser.
            if ($cfg.SubId) { az account set --subscription $cfg.SubId 2>&1 | Out-Null }
            $tokenJson = az account get-access-token --tenant $cfg.TenantId --resource https://graph.microsoft.com 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0 -or $tokenJson -match '^ERROR') {
                Write-Error "az CLI token fetch failed for $Tenant (Graph). Re-run: az login --tenant $($cfg.TenantId) --allow-no-subscriptions"
                return
            }
            $token = ($tokenJson | ConvertFrom-Json).accessToken
            Connect-MgGraph -AccessToken (ConvertTo-SecureString $token -AsPlainText -Force) -NoWelcome
            Write-Host "Connected to $Tenant (read-only) as $((Get-MgContext).Account)" -ForegroundColor Green
        }
    }

    # --- Exchange Online (MSAL cache: silent if token cached, one sign-in if cold) ---
    if ($Exo -or $ExoOnly) {
        $exoConn = Get-ConnectionInformation -ErrorAction SilentlyContinue |
            Where-Object { $_.State -eq 'Connected' -and $_.TenantID -eq $cfg.TenantId }
        if ($exoConn) {
            Write-Host "Reusing existing Exchange Online session for $($exoConn.UserPrincipalName)" -ForegroundColor DarkGray
        } else {
            if ($DeviceCode) {
                Write-Host "DEVICE CODE SIGN-IN for $Tenant Exchange Online: open the URL below in the $Tenant browser profile." -ForegroundColor Yellow
                Connect-ExchangeOnline `
                    -UserPrincipalName $cfg.Account `
                    -Organization $cfg.TenantId `
                    -Device `
                    -ShowBanner:$false
            } else {
                Connect-ExchangeOnline `
                    -UserPrincipalName $cfg.Account `
                    -Organization $cfg.TenantId `
                    -ShowBanner:$false
            }
            Write-Host "Connected to $Tenant Exchange Online as $($cfg.Account)" -ForegroundColor Green
        }
    }
}
