# TenantConfig.ps1
# Loads the tenant table every other script in the toolkit uses.
#
# Config file, first match wins:
#   1. $env:MS_TENANT_TOOLKIT_CONFIG
#   2. <toolkit root>/config/tenants.json
#
# Copy config/tenants.example.json to config/tenants.json and fill in your tenants.
# tenants.json is git-ignored; never commit it.
#
# Exposes:
#   $TenantConfig        case-insensitive hashtable: NAME -> @{ TenantId; SubId; Account; BrowserProfile }
#   $TenantToolkitConfig the parsed file (includes the SignInRouter block)
#   $TenantConfigPath    the file that was loaded
#   Assert-TenantName    throws on an unknown tenant name and returns the canonical key

$script:ToolkitRoot = Split-Path -Parent $PSScriptRoot

$TenantConfigPath = if ($env:MS_TENANT_TOOLKIT_CONFIG) {
    $env:MS_TENANT_TOOLKIT_CONFIG
} else {
    Join-Path $script:ToolkitRoot "config/tenants.json"
}

if (-not (Test-Path $TenantConfigPath)) {
    throw "Tenant config not found at '$TenantConfigPath'. Copy config/tenants.example.json to config/tenants.json and fill it in, or set MS_TENANT_TOOLKIT_CONFIG."
}

$TenantToolkitConfig = Get-Content $TenantConfigPath -Raw -Encoding utf8 | ConvertFrom-Json

# @{} is case-insensitive, so "contoso" and "CONTOSO" resolve to the same tenant.
$TenantConfig = @{}
foreach ($p in $TenantToolkitConfig.Tenants.PSObject.Properties) {
    $t = $p.Value
    if ($t.TenantId -notmatch '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
        throw "Tenant '$($p.Name)' in $TenantConfigPath needs TenantId as a GUID (not a domain)."
    }
    $TenantConfig[$p.Name] = @{
        TenantId       = $t.TenantId.ToLower()
        SubId          = $t.SubscriptionId
        Account        = $t.Account
        BrowserProfile = $t.BrowserProfile
    }
}

function Assert-TenantName([string]$Name) {
    $key = $TenantConfig.Keys | Where-Object { $_ -eq $Name } | Select-Object -First 1
    if (-not $key) {
        throw "Unknown tenant '$Name'. Known tenants: $(($TenantConfig.Keys | Sort-Object) -join ', ') (from $TenantConfigPath)."
    }
    return $key
}
