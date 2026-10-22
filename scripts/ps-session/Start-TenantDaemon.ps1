<#
.SYNOPSIS
    Start the persistent PowerShell daemon for one tenant. Windows, macOS and Linux.

.DESCRIPTION
    The daemon signs in once (full read+write Graph scopes plus Exchange Online) and then
    runs job scripts submitted by Invoke-TenantJob.ps1 in that same session, so later
    reads and writes are silent.

    Running this for a daemon that is already up (without -Force) attaches the macOS
    sign-in router if it is enabled and missing, then exits.

    Readiness is judged from this run's own stdout file (daemon-<T>.out.log is
    overwritten on every start), so a "Ready." left behind by a daemon that has since
    died can never be mistaken for a live one.

    Sign-in behavior by platform:
      Windows : Graph and EXO use the Windows account broker (WAM). The daemon starts in
                a minimized console window so the broker has a window to attach its
                prompt to. Pick the tenant's admin account in the prompt.
      macOS   : MSAL opens the default browser, in whichever profile was used last. With
                SignInRouter.Enabled in tenants.json, signin-router.py moves that page into
                the tenant's browser profile. Otherwise use -DeviceCode when it matters.
    Either way daemon.ps1 is the backstop: it checks the tenant it actually connected to
    and refuses to serve jobs on a mismatch.

.EXAMPLE
    ./Start-TenantDaemon.ps1 -Tenant CONTOSO
    ./Start-TenantDaemon.ps1 -Tenant CONTOSO -Force        # restart a wedged or dead daemon
    ./Start-TenantDaemon.ps1 -Tenant CONTOSO -DeviceCode   # print a code, launch nothing
#>
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Tenant,
    [switch]$Force,          # stop an already-running daemon first (use when it has gone stale)
    [switch]$DeviceCode,     # sign in with a printed code instead of a browser / broker window
    [int]$WaitSeconds = 180  # how long to wait for the daemon to sign in
)

. (Join-Path $PSScriptRoot "DaemonCommon.ps1")
$Tenant = Assert-TenantName $Tenant
$p = Get-DaemonPaths $Tenant
$MaxLogBytes = 5MB

function Test-DaemonRunning {
    $existing = Read-PidFile $p.PidFile
    $existing -and (Test-ProcessAlive $existing)
}

# Start the macOS sign-in router for daemon PID $DaemonPid unless one is already watching it.
function Start-SignInRouter([int]$DaemonPid) {
    $router = $TenantToolkitConfig.SignInRouter
    if (-not $IsMacOS -or -not $router -or -not $router.Enabled) { return }

    $rpid = Read-PidFile $p.RouterPidFile
    if ($rpid -and (Test-ProcessAlive $rpid)) {
        $cmd = (Get-ProcessByCommandLine "signin-router\.py" | Where-Object Id -eq $rpid).CommandLine
        if ($cmd -match "--pid $DaemonPid(\s|$)") { return }
        Stop-Process -Id $rpid -ErrorAction SilentlyContinue
    }
    $proc = Start-DetachedProcess "/usr/bin/python3" `
        @((Join-Path $DaemonBase "signin-router.py"), "--config", $TenantConfigPath,
          "--tenant", $Tenant, "--pid", "$DaemonPid") `
        $p.RouterLog "$($p.RouterLog).err"
    $proc.Id | Set-Content $p.RouterPidFile -Encoding utf8
}

if (Test-DaemonRunning) {
    if ($Force) {
        Write-Host "[start-daemon] $Tenant already running (PID $(Read-PidFile $p.PidFile)), stopping it first."
        # A wedged daemon, the usual reason for -Force, may ignore a polite stop. Starting a
        # second daemon against the same job queue is worse than not starting one at all:
        # both poll it, both hold a live client session, and the PID file can only name one.
        & (Join-Path $DaemonBase "Stop-TenantDaemon.ps1") -Tenant $Tenant
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[start-daemon] ABORTED: the old $Tenant daemon is still alive, so a second one is not safe to start." -ForegroundColor Red
            exit 1
        }
    } else {
        Start-SignInRouter (Read-PidFile $p.PidFile)
        Write-Host "[start-daemon] $Tenant already running (PID $(Read-PidFile $p.PidFile)). Use -Force to restart."
        exit 0
    }
}

# An orphan is a daemon process no PID file names: left by a crashed start, a hand-run
# daemon.ps1, or a daemon that removed its own PID file on a FATAL path but did not exit.
$orphans = Get-DaemonProcessIds $Tenant
if ($orphans) {
    Write-Host "[start-daemon] Orphan $Tenant daemon process(es) found: $($orphans -join ' ')"
    & (Join-Path $DaemonBase "Stop-TenantDaemon.ps1") -Tenant $Tenant
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[start-daemon] ABORTED: an orphan $Tenant daemon could not be stopped." -ForegroundColor Red
        exit 1
    }
}

# A stale PID file with a dead process would otherwise linger and confuse callers.
Remove-Item $p.PidFile -ErrorAction SilentlyContinue

# Keep the daemon's own log from growing without bound.
if ((Test-Path $p.LogFile) -and (Get-Item $p.LogFile).Length -gt $MaxLogBytes) {
    Move-Item $p.LogFile "$($p.LogFile).1" -Force
    Write-Host "[start-daemon] Rotated oversized log to $(Split-Path -Leaf $p.LogFile).1"
}

# Same pwsh that is running this script, so Windows and Unix both resolve it.
$pwsh = (Get-Process -Id $PID).Path
$daemonArgs = @("-NoLogo", "-File", $p.DaemonScript, "-Tenant", $Tenant)
if ($DeviceCode) { $daemonArgs += "-DeviceCode" }

if ($DeviceCode) {
    Write-Host "[start-daemon] Starting $Tenant daemon (device code)."
} else {
    Write-Host "[start-daemon] Starting $Tenant daemon. Cached tokens: no prompt. Otherwise a sign-in appears for $($TenantConfig[$Tenant].Account)."
}
# Detached so the daemon outlives this launcher (see Start-DetachedProcess).
$proc = Start-DetachedProcess $pwsh $daemonArgs $p.OutFile $p.ErrFile
$daemonPid = $proc.Id
$daemonPid | Set-Content $p.PidFile -Encoding utf8
Start-SignInRouter $daemonPid
Write-Host "[start-daemon] PID $daemonPid, waiting up to ${WaitSeconds}s for it to connect ..."

function Get-RunOutput {
    $text = ""
    foreach ($f in @($p.OutFile, $p.ErrFile)) {
        if (Test-Path $f) { $text += (Get-Content $f -Raw -ErrorAction SilentlyContinue) + "`n" }
    }
    $text
}

# Only ever remove the PID file if it still names THIS daemon. Deleting it blindly on a
# failure path would orphan whichever daemon it actually names.
function Clear-OwnPidFile {
    if ((Read-PidFile $p.PidFile) -eq $daemonPid) { Remove-Item $p.PidFile -ErrorAction SilentlyContinue }
}

$shownCodes = ""
$shownRouted = 0
for ($waited = 0; $waited -lt $WaitSeconds; $waited++) {
    $out = Get-RunOutput

    # Say so the moment the router has put a sign-in in front of the user.
    if (Test-Path $p.RouterLog) {
        $routed = @(Select-String -Path $p.RouterLog -Pattern "sign-in opened" -ErrorAction SilentlyContinue).Count
        if ($routed -gt $shownRouted) {
            Write-Host "[start-daemon] Sign-in is open in the $Tenant browser profile. Complete it there."
            $shownRouted = $routed
        }
    }

    # Device-code prompts go to the daemon's stdout; surface each one once.
    $codes = (($out -split "`r?`n") | Where-Object { $_ -match "devicelogin" } | Sort-Object -Unique) -join "`n"
    if ($codes -and $codes -ne $shownCodes) {
        Write-Host ""
        Write-Host "══════════════ $Tenant SIGN-IN CODE ══════════════" -ForegroundColor Yellow
        $codes -split "`n" | ForEach-Object { Write-Host "  $_" }
        Write-Host "  Open that URL in the $Tenant browser profile and enter the code."
        Write-Host "══════════════════════════════════════════════════" -ForegroundColor Yellow
        Write-Host ""
        $shownCodes = $codes
    }

    $lines = $out -split "`r?`n"
    if ($lines -match "Ready\.") {
        Write-Host "[start-daemon] $Tenant daemon ready." -ForegroundColor Green
        $lines -match "Connected:" | Select-Object -First 1 | ForEach-Object { Write-Host $_ }
        # daemon.ps1 compares the connected tenant id against the expected one before it
        # will serve anything. Show that evidence rather than just claiming success.
        $verified = $lines -match "Verified:"
        if ($verified) { $verified | ForEach-Object { Write-Host $_ } }
        else { Write-Host "[start-daemon] (no tenant verification line, check $($p.LogFile))" }
        exit 0
    }
    if ($lines -match "FATAL:") {
        Write-Host "[start-daemon] ERROR: $Tenant daemon did not come up:" -ForegroundColor Red
        $lines -match "FATAL:" | ForEach-Object { Write-Host $_ }
        Clear-OwnPidFile
        exit 1
    }
    if (-not (Test-ProcessAlive $daemonPid)) {
        Write-Host "[start-daemon] ERROR: the daemon process exited. Last output:" -ForegroundColor Red
        $lines | Select-Object -Last 20 | ForEach-Object { Write-Host $_ }
        Clear-OwnPidFile
        exit 1
    }
    Start-Sleep -Seconds 1
}

Write-Host "[start-daemon] ERROR: $Tenant daemon did not become ready in ${WaitSeconds}s. Check $($p.LogFile)" -ForegroundColor Red
exit 1
