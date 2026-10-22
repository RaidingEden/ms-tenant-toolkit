# DaemonCommon.ps1
# Process helpers shared by Start-TenantDaemon.ps1, Stop-TenantDaemon.ps1 and
# Invoke-TenantJob.ps1. Cross-platform (Windows, macOS, Linux) on PowerShell 7.

. (Join-Path (Split-Path -Parent $PSScriptRoot) "TenantConfig.ps1")

$DaemonBase = $PSScriptRoot

function Get-DaemonPaths([string]$Tenant) {
    [PSCustomObject]@{
        DaemonScript  = Join-Path $DaemonBase "daemon.ps1"
        PidFile       = Join-Path $DaemonBase "daemon-$Tenant.pid"
        LogFile       = Join-Path $DaemonBase "daemon-$Tenant.log"       # daemon's own log, appended across runs
        OutFile       = Join-Path $DaemonBase "daemon-$Tenant.out.log"   # stdout of the current run only
        ErrFile       = Join-Path $DaemonBase "daemon-$Tenant.err.log"   # stderr of the current run only
        RouterPidFile = Join-Path $DaemonBase "daemon-$Tenant.router.pid"
        RouterLog     = Join-Path $DaemonBase "daemon-$Tenant.router.log"
        JobDir        = Join-Path $DaemonBase "jobs/$Tenant"
        ResultDir     = Join-Path $DaemonBase "results/$Tenant"
    }
}

function Read-PidFile([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    $digits = (Get-Content $Path -Raw -ErrorAction SilentlyContinue) -replace '\D', ''
    if ($digits) { [int]$digits } else { $null }
}

function Test-ProcessAlive([int]$ProcessId) {
    [bool](Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

# Every live process whose command line matches $Pattern, as (Id, CommandLine).
function Get-ProcessByCommandLine([string]$Pattern) {
    if ($IsWindows) {
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match $Pattern } |
            ForEach-Object { [PSCustomObject]@{ Id = [int]$_.ProcessId; CommandLine = $_.CommandLine } }
    } else {
        & ps -axo 'pid=,command=' 2>$null | ForEach-Object {
            # Capture before the second -match: it overwrites $Matches.
            if ($_ -match '^\s*(\d+)\s+(.*)$') {
                $id = [int]$Matches[1]; $cmd = $Matches[2]
                if ($id -gt 0 -and $cmd -match $Pattern) {
                    [PSCustomObject]@{ Id = $id; CommandLine = $cmd }
                }
            }
        }
    }
}

# Daemon processes for one tenant, whether or not a PID file names them. Only processes
# whose executable is pwsh count, so a shell or editor whose command line merely mentions
# daemon.ps1 is never touched. PID 0 is never returned: on Unix, signalling 0 hits the whole group.
function Get-DaemonProcessIds([string]$Tenant) {
    $t = [regex]::Escape($Tenant)
    # Anchored on a path separator, quote or space before "daemon.ps1" so that
    # Start-TenantDaemon.ps1 / Stop-TenantDaemon.ps1 command lines never match.
    @(Get-ProcessByCommandLine "(^|[\\/\s`"'])daemon\.ps1[`"']?\s+-Tenant\s+$t(\s|$)" |
        Where-Object { $_.Id -gt 0 -and $_.Id -ne $PID -and $_.CommandLine -match '^"?([^"\s]*[\\/])?pwsh(\.exe)?"?\s' } |
        ForEach-Object Id)
}

# Start a long-lived background process whose stdout/stderr go straight to files, and
# return its Process object. The PID is the process's own.
#
# Unix: Start-Process -RedirectStandardOutput hands the child a PIPE that the launching
# pwsh drains into the file, so once the launcher exits the child dies on its next write.
# Instead /bin/sh points the descriptors at the files and execs nohup, which execs the
# program, so nothing depends on the launcher staying alive. ArgumentList passes every
# argument verbatim, so paths with spaces are safe.
#
# Windows: Start-Process writes redirected output to the files directly. Minimized, not
# hidden: the Windows account broker needs a window to parent its sign-in prompt.
function Start-DetachedProcess([string]$FilePath, [string[]]$Arguments, [string]$OutFile, [string]$ErrFile) {
    if ($IsWindows) {
        return Start-Process -FilePath $FilePath -ArgumentList $Arguments -PassThru `
            -RedirectStandardOutput $OutFile -RedirectStandardError $ErrFile -WindowStyle Minimized
    }
    $psi = [System.Diagnostics.ProcessStartInfo]::new("/bin/sh")
    $psi.UseShellExecute = $false
    $shArgs = @('-c', 'out=$1; err=$2; shift 2; exec /usr/bin/nohup "$@" >"$out" 2>"$err" </dev/null',
                'sh', $OutFile, $ErrFile, $FilePath) + $Arguments
    foreach ($a in $shArgs) { $psi.ArgumentList.Add($a) }
    [System.Diagnostics.Process]::Start($psi)
}

# Wait up to $Seconds for a PID to disappear. Returns $true if it is gone.
function Wait-ProcessGone([int]$ProcessId, [int]$Seconds) {
    for ($i = 0; $i -lt $Seconds; $i++) {
        if (-not (Test-ProcessAlive $ProcessId)) { return $true }
        Start-Sleep -Seconds 1
    }
    -not (Test-ProcessAlive $ProcessId)
}

# Stop one PID, escalating. Returns $true if it is gone afterwards.
# Unix: SIGTERM first, then SIGKILL. Windows has no graceful signal for a console
# process, so it goes straight to a forced stop.
function Stop-DaemonProcess([int]$ProcessId, [string]$Label, [int]$TimeoutSeconds = 10) {
    if ($ProcessId -le 0) { throw "Refusing to stop PID $ProcessId." }
    $half = [Math]::Max(2, [int]($TimeoutSeconds / 2))

    if (-not $IsWindows) {
        Write-Host "[stop-daemon] Stopping $Label (PID $ProcessId): SIGTERM ..."
        & kill -TERM $ProcessId 2>$null
        if (Wait-ProcessGone $ProcessId $half) { Write-Host "[stop-daemon] $Label stopped."; return $true }
        # Expected for a daemon wedged inside a hung cmdlet: it never reaches a point
        # where it can act on the signal.
        Write-Host "[stop-daemon] $Label did not exit after ${half}s, escalating to a forced kill."
    } else {
        Write-Host "[stop-daemon] Stopping $Label (PID $ProcessId) ..."
    }

    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    if (Wait-ProcessGone $ProcessId $half) { Write-Host "[stop-daemon] $Label killed."; return $true }

    Write-Host "[stop-daemon] ERROR: $Label (PID $ProcessId) is STILL ALIVE after a forced kill." -ForegroundColor Red
    Write-Host "[stop-daemon] Do not start another daemon for this tenant: two would poll the same job queue." -ForegroundColor Red
    return $false
}
