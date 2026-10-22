<#
.SYNOPSIS
    Stop a tenant's PowerShell daemon and PROVE it is gone. Windows, macOS and Linux.

.DESCRIPTION
    Exit codes:
      0  the daemon is not running (stopped now, or was already dead)
      3  a daemon process is STILL ALIVE after a forced kill; do not start another

    A wedged daemon is the usual reason to stop one, and a pwsh stuck inside a hung
    cmdlet does not always act on SIGTERM. Reporting "stopped" without checking would
    let Start-TenantDaemon.ps1 -Force launch a second daemon against the same job queue
    while the first is still alive. So: stop, wait, escalate, wait again, and refuse to
    claim success. The PID file is removed only once the process is actually gone; if it
    survives, the file stays so the process remains addressable.

    It also sweeps for ORPHANS: daemon processes no PID file names.

.EXAMPLE
    ./Stop-TenantDaemon.ps1 -Tenant CONTOSO
#>
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Tenant,
    [int]$TimeoutSeconds = 10
)

. (Join-Path $PSScriptRoot "DaemonCommon.ps1")
$Tenant = Assert-TenantName $Tenant
$p = Get-DaemonPaths $Tenant

$rc = 0
$daemonPid = Read-PidFile $p.PidFile

if (Test-Path $p.PidFile) {
    if (-not $daemonPid) {
        Write-Host "[stop-daemon] PID file for $Tenant holds no PID, removing it."
        Remove-Item $p.PidFile -ErrorAction SilentlyContinue
    } elseif (-not (Test-ProcessAlive $daemonPid)) {
        Write-Host "[stop-daemon] $Tenant PID $daemonPid is not running, removing the stale PID file."
        Remove-Item $p.PidFile -ErrorAction SilentlyContinue
    } elseif (Stop-DaemonProcess $daemonPid "$Tenant daemon" $TimeoutSeconds) {
        Remove-Item $p.PidFile -ErrorAction SilentlyContinue
    } else {
        # Leave the PID file: it is the only thing that still names this process.
        $rc = 3
    }
} else {
    Write-Host "[stop-daemon] No PID file for $Tenant."
}

# ── Orphans ───────────────────────────────────────────────────────────────────
# A daemon process that no PID file names. Nothing else would ever find these, and
# each one holds a live Microsoft session for a client tenant.
foreach ($op in Get-DaemonProcessIds $Tenant) {
    if ($op -eq $daemonPid) { continue }
    Write-Host "[stop-daemon] Orphan $Tenant daemon found (PID $op), no PID file names it."
    if (-not (Stop-DaemonProcess $op "orphan $Tenant daemon" $TimeoutSeconds)) { $rc = 3 }
}

# ── Sign-in router (macOS only) ───────────────────────────────────────────────
# It exits by itself within a second of its daemon dying; this just makes it prompt.
if ($rc -eq 0) {
    $rpid = Read-PidFile $p.RouterPidFile
    if ($rpid) { Stop-Process -Id $rpid -ErrorAction SilentlyContinue }
    $t = [regex]::Escape($Tenant)
    Get-ProcessByCommandLine "signin-router\.py .*--tenant $t(\s|$)" |
        ForEach-Object { Stop-Process -Id $_.Id -ErrorAction SilentlyContinue }
    Remove-Item $p.RouterPidFile -ErrorAction SilentlyContinue
    Write-Host "[stop-daemon] No $Tenant daemon is running."
}
exit $rc
