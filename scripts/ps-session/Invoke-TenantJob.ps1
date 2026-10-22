<#
.SYNOPSIS
    Submit a job script to a tenant's persistent daemon and print its output.
    Starts the daemon first if it is not running. Windows, macOS and Linux.

.DESCRIPTION
    The job script must NOT contain Connect-* or Disconnect-* calls; the daemon already
    holds the Graph (read+write) and Exchange Online sessions.

    Exit codes: 0 job finished (check its output for errors), 1 timeout or daemon failure.

.EXAMPLE
    ./Invoke-TenantJob.ps1 -Tenant CONTOSO -ScriptPath ./job.ps1
    ./Invoke-TenantJob.ps1 CONTOSO ./job.ps1 300
#>
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Tenant,
    [Parameter(Mandatory, Position = 1)]
    [string]$ScriptPath,
    [Parameter(Position = 2)]
    [int]$TimeoutSeconds = 120
)

. (Join-Path $PSScriptRoot "DaemonCommon.ps1")
$Tenant = Assert-TenantName $Tenant
$p = Get-DaemonPaths $Tenant

if (-not (Test-Path $ScriptPath)) { Write-Host "[run] Job script not found: $ScriptPath" -ForegroundColor Red; exit 1 }
New-Item -ItemType Directory -Force -Path $p.JobDir, $p.ResultDir | Out-Null

# ── Ensure daemon is running ──────────────────────────────────────────────────
$daemonPid = Read-PidFile $p.PidFile
if ($daemonPid -and (Test-ProcessAlive $daemonPid)) {
    Write-Host "[run] Daemon already running for $Tenant (PID $daemonPid)"
} else {
    Write-Host "[run] Daemon not running for $Tenant, cold-starting it (may prompt a sign-in once) ..."
    # Start-TenantDaemon judges readiness only against its own fresh output, so a "Ready."
    # from a daemon that already died can never satisfy it.
    & (Join-Path $DaemonBase "Start-TenantDaemon.ps1") -Tenant $Tenant
    if ($LASTEXITCODE -ne 0) { exit 1 }
}

# ── Submit job ────────────────────────────────────────────────────────────────
$jobId      = "job-$([DateTime]::UtcNow.Ticks)-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
$jobFile    = Join-Path $p.JobDir "$jobId.ps1"
$resultFile = Join-Path $p.ResultDir "$jobId.done"

# Stage then rename, so the daemon's poll loop can never pick up a half-written job.
$staging = Join-Path $p.JobDir ".$jobId.tmp"
Copy-Item $ScriptPath $staging
Move-Item $staging $jobFile
Write-Host "[run] Job $jobId submitted, waiting (timeout ${TimeoutSeconds}s) ..."

# ── Wait for result ───────────────────────────────────────────────────────────
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while (-not (Test-Path $resultFile)) {
    if ((Get-Date) -gt $deadline) {
        Write-Host "[run] TIMEOUT after ${TimeoutSeconds}s, job $jobId still running" -ForegroundColor Red
        exit 1
    }
    Start-Sleep -Milliseconds 500
}

Get-Content $resultFile -Raw -Encoding utf8
Remove-Item $resultFile -ErrorAction SilentlyContinue
exit 0
