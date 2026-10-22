param(
    [Parameter(Mandatory)]
    [string]$Tenant,

    # Which services to connect. Default: Graph + EXO.
    [switch]$GraphOnly,
    [switch]$ExoOnly,

    # Sign in with a device code instead of a browser window. The code is written to
    # stdout, and Start-TenantDaemon.ps1 surfaces it. Use this when the sign-in must
    # land in a specific browser profile with certainty: nothing is launched, so
    # nothing can be routed to the wrong client's window.
    [switch]$DeviceCode
)

$ErrorActionPreference = "Continue"
$PSDefaultParameterValues["Out-File:Encoding"] = "utf8"

# Loads $TenantConfig and Connect-Tenant from the toolkit's scripts folder.
. (Join-Path (Split-Path -Parent $PSScriptRoot) "Connect-Tenant.ps1")
$Tenant = Assert-TenantName $Tenant

$baseDir   = $PSScriptRoot
$jobDir    = Join-Path $baseDir "jobs/$Tenant"
$resultDir = Join-Path $baseDir "results/$Tenant"
$pidFile   = Join-Path $baseDir "daemon-$Tenant.pid"
$logFile   = Join-Path $baseDir "daemon-$Tenant.log"

foreach ($d in @($jobDir, $resultDir)) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

function Log([string]$msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
    Add-Content -Path $logFile -Value $line -Encoding utf8
    Write-Host $line
}

# ── Refuse to be a second daemon on one job queue ─────────────────────────────
# Start-TenantDaemon.ps1 writes this PID file with the PID of the pwsh it just
# launched, which is this process, so a file naming *us* is expected. A file naming a
# DIFFERENT live process means another daemon is already polling $jobDir. Two daemons
# there race for every job and each holds its own Microsoft session for this client.
# Exiting is the safe side: the running one keeps working.
if (Test-Path $pidFile) {
    $existing = ((Get-Content $pidFile -Raw -ErrorAction SilentlyContinue) -replace '\D', '')
    if ($existing -and [int]$existing -ne $PID -and
        (Get-Process -Id ([int]$existing) -ErrorAction SilentlyContinue)) {
        Log "FATAL: another $Tenant daemon is already running (PID $existing). Refusing to start a second one."
        Log "FATAL: stop it first with Stop-TenantDaemon.ps1 -Tenant $Tenant, or use Start-TenantDaemon.ps1 -Tenant $Tenant -Force."
        exit 1
    }
}

$PID | Set-Content $pidFile -Encoding utf8

# ── Connect once ──────────────────────────────────────────────────────────────
Log "Daemon starting for tenant: $Tenant"

try {
    if ($DeviceCode) { Log "Sign-in mode: DEVICE CODE (no browser is launched)." }
    if ($ExoOnly) {
        Connect-Tenant -Tenant $Tenant -ExoOnly -DeviceCode:$DeviceCode
        Log "Connected: EXO only"
    } elseif ($GraphOnly) {
        Connect-Tenant -Tenant $Tenant -Interactive -DeviceCode:$DeviceCode       # Graph read+write (full scopes)
        Log "Connected: Graph read+write. Scopes: $((Get-MgContext).Scopes -join ', ')"
    } else {
        Connect-Tenant -Tenant $Tenant -Interactive -Exo -DeviceCode:$DeviceCode  # Graph read+write + EXO
        Log "Connected: Graph read+write + EXO. Scopes: $((Get-MgContext).Scopes -join ', ')"
    }
} catch {
    Log "FATAL: initial connection failed: $_"
    Remove-Item $pidFile -ErrorAction SilentlyContinue
    exit 1
}

# ── Refuse to serve a session signed in to the wrong tenant ───────────────────
# A cold sign-in can land in the wrong account or browser profile. If it does, the
# daemon would otherwise come up healthy and every job after it would run against the
# wrong tenant. $TenantConfig is the same table the connection was built from.
$expectedTid     = $TenantConfig[$Tenant].TenantId
$expectedAccount = $TenantConfig[$Tenant].Account

function Stop-WrongTenant([string]$what, [string]$got) {
    Log "FATAL: $Tenant daemon signed in to the WRONG TENANT: $what is '$got', expected '$expectedTid' ($expectedAccount)."
    Log "FATAL: refusing to serve jobs. The sign-in completed in the wrong account or browser profile."
    Log "FATAL: re-run Start-TenantDaemon.ps1 -Tenant $Tenant and complete the sign-in as $expectedAccount."
    Remove-Item $pidFile -ErrorAction SilentlyContinue
    exit 1
}

if (-not $ExoOnly) {
    $ctx = Get-MgContext
    if (-not $ctx) { Log "FATAL: no Graph context after connect."; Remove-Item $pidFile -ErrorAction SilentlyContinue; exit 1 }
    if ($ctx.TenantId -ne $expectedTid) { Stop-WrongTenant "Graph tenant" $ctx.TenantId }
    Log "Verified: Graph tenant $($ctx.TenantId) as $($ctx.Account), matches $Tenant."
}

if (-not $GraphOnly) {   # default and -ExoOnly both connect Exchange Online
    $exoConn = Get-ConnectionInformation -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exoConn -and $exoConn.TenantID -and $exoConn.TenantID -ne $expectedTid) {
        Stop-WrongTenant "Exchange Online tenant" $exoConn.TenantID
    }
    if ($exoConn) { Log "Verified: Exchange Online tenant $($exoConn.TenantID) as $($exoConn.UserPrincipalName), matches $Tenant." }
}

Log "Ready. Polling $jobDir every 500ms ..."

# ── Job loop ──────────────────────────────────────────────────────────────────
while ($true) {
    $pending = Get-ChildItem $jobDir -Filter "*.ps1" -ErrorAction SilentlyContinue |
               Sort-Object CreationTime

    foreach ($job in $pending) {
        $id       = $job.BaseName
        $running  = Join-Path $jobDir   "$id.running"
        $doneFile = Join-Path $resultDir "$id.done"

        # Atomic rename, prevents double-execution if future parallel runners exist
        try { Move-Item $job.FullName $running -ErrorAction Stop }
        catch { continue }

        Log "Job ${id}: start"
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        try {
            # Execute job in a clean child scope; capture ALL streams (*>&1)
            $sb     = [ScriptBlock]::Create((Get-Content $running -Raw -Encoding utf8))
            $output = (& $sb) *>&1 | Out-String
        } catch {
            $output = "DAEMON ERROR: $_`n$($_.ScriptStackTrace)"
        }

        # Write then rename, so a waiting Invoke-TenantJob never reads a half-written result.
        $output | Set-Content "$doneFile.tmp" -Encoding utf8
        Move-Item "$doneFile.tmp" $doneFile -Force
        Remove-Item $running -ErrorAction SilentlyContinue
        Log "Job ${id}: done in $($sw.Elapsed.TotalSeconds.ToString('F1'))s"
    }

    # ── Keepalive: Graph session (reconnect with full scopes if the context is lost) ──
    if (-not $ExoOnly) {
        if (-not (Get-MgContext)) {
            Log "Graph session lost, reconnecting (full scopes) ..."
            try {
                Connect-Tenant -Tenant $Tenant -Interactive
                Log "Graph reconnected. Scopes: $((Get-MgContext).Scopes -join ', ')"
            } catch {
                Log "Graph reconnect failed: $_"
            }
        }
    }

    # ── Keepalive: check EXO session, reconnect silently if dropped ────────────
    if (-not $GraphOnly) {
        $conn = Get-ConnectionInformation -ErrorAction SilentlyContinue
        if (-not $conn) {
            Log "EXO session lost, reconnecting ..."
            try {
                Connect-Tenant -Tenant $Tenant -ExoOnly
                Log "Reconnected"
            } catch {
                Log "Reconnect failed: $_"
            }
        }
    }

    Start-Sleep -Milliseconds 500
}
