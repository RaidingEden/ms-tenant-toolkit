#!/usr/bin/env python3
"""signin-router.py (macOS only, optional): move a daemon's Microsoft sign-in into its
client's browser profile.

Start-TenantDaemon.ps1 launches it beside one tenant daemon when SignInRouter.Enabled is
true in tenants.json, and it exits when the daemon does. Works with Chromium-based
browsers that support AppleScript tab access (Google Chrome, Microsoft Edge, Brave, ...).
Windows does not need it: Graph and EXO sign in through the Windows account broker there.

Why this exists
───────────────
On macOS, MSAL launches the sign-in with a hard-coded `/usr/bin/open <url>`, so the page
lands in whichever browser profile was used last. There is no profile flag to pass and no
PATH shim that can intercept it. What we *can* do is notice the page and move it:

  1. Every ~0.75s, ask the OS whether the daemon process has a localhost TCP listener.
     MSAL opens one only while an interactive sign-in is in progress, so the rest of the
     time this costs a single 20ms `lsof`.
  2. While a listener exists, poll the browser's tabs for a login.microsoftonline.com URL
     whose `redirect_uri` points at THAT listener's port. The port proves which daemon
     owns the page, so two tenants starting at once cannot be confused.
  3. Close that tab and reopen the identical URL in the tenant's profile, in a new
     frontmost window. The URL carries MSAL's state and PKCE challenge, and the redirect
     goes back to localhost, so it completes from any profile.

daemon.ps1 is still the backstop: it compares the tenant it actually connected to with
the expected one and refuses to serve jobs on a mismatch.

Usage: signin-router.py --config tenants.json --tenant <NAME> --pid <daemon pid>
"""

import argparse
import json
import os
import subprocess
import sys
import time
from urllib.parse import parse_qs, urlparse

# Set from the SignInRouter block of tenants.json in main().
APP = None
APP_NAME = None
LOCAL_STATE = None

IDLE_POLL = 0.75   # seconds between listener checks when no sign-in is in progress
ACTIVE_POLL = 0.2  # seconds between tab scans while a sign-in is in progress


def log(tenant, msg):
    print("%s  [router] %s: %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), tenant, msg), flush=True)


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def profile_dir(label):
    try:
        cache = json.load(open(LOCAL_STATE)).get("profile", {}).get("info_cache", {})
    except (OSError, ValueError):
        return None
    for d, info in cache.items():
        if info.get("name", "").strip().lower() == label.lower():
            return d
    return None


def listener_ports(pid):
    """Localhost TCP ports the daemon is listening on (MSAL's redirect listener)."""
    out = subprocess.run(
        ["lsof", "-a", "-nP", "-p", str(pid), "-iTCP", "-sTCP:LISTEN", "-Fn"],
        capture_output=True, text=True).stdout
    ports = set()
    for line in out.splitlines():
        if line.startswith("n") and ":" in line:
            try:
                ports.add(int(line.rsplit(":", 1)[1]))
            except ValueError:
                pass
    return ports


def osa(script):
    return subprocess.run(["osascript", "-e", script], capture_output=True, text=True).stdout


def tabs_matching(needle):
    """(tab id, url) for every browser tab whose URL contains `needle`."""
    # The `is running` guard matters: a bare `tell application` would launch the browser.
    # `tab` inside the tell block means the browser's tab class, hence `sep`.
    script = '''
if application "%s" is running then
  set sep to ASCII character 9
  tell application "%s"
    set out to ""
    repeat with w in windows
      repeat with t in tabs of w
        try
          set u to URL of t
          if u contains "%s" then set out to out & ((id of t) as text) & sep & u & linefeed
        end try
      end repeat
    end repeat
    return out
  end tell
end if''' % (APP_NAME, APP_NAME, needle)
    found = []
    for line in osa(script).splitlines():
        tid, _, url = line.partition("\t")
        if tid.strip().isdigit() and url:
            found.append((tid.strip(), url))
    return found


def close_tab(tab_id):
    # By id, not URL: the login page often navigates on (e.g. to a passkey bridge) within
    # milliseconds, and a URL match would then miss the tab and leave it open.
    osa('''
tell application "%s"
  repeat with w in windows
    try
      close (every tab of w whose id is %s)
    end try
  end repeat
end tell''' % (APP_NAME, tab_id))


def redirect_port(url):
    q = parse_qs(urlparse(url).query)
    redirect = (q.get("redirect_uri") or [""])[0]
    r = urlparse(redirect)
    if r.hostname in ("localhost", "127.0.0.1") and r.port:
        return r.port, (q.get("state") or [url])[0]
    return None, None


def main():
    global APP, APP_NAME, LOCAL_STATE
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--tenant", required=True)
    ap.add_argument("--pid", required=True, type=int)
    a = ap.parse_args()

    cfg = json.load(open(a.config, encoding="utf-8"))
    router = cfg.get("SignInRouter") or {}
    APP = router.get("AppPath", "/Applications/Google Chrome.app")
    APP_NAME = router.get("AppName", "Google Chrome")
    LOCAL_STATE = os.path.expanduser(router.get(
        "LocalState", "~/Library/Application Support/Google/Chrome/Local State"))

    tenants = {k.upper(): v for k, v in (cfg.get("Tenants") or {}).items()}
    tenant = tenants.get(a.tenant.upper())
    if not tenant or not tenant.get("BrowserProfile"):
        log(a.tenant, "no BrowserProfile set for this tenant in %s; nothing to route." % a.config)
        return 2

    label = tenant["BrowserProfile"]
    pdir = profile_dir(label)
    if not pdir:
        log(a.tenant, "no %s profile labelled '%s'; sign-ins will open in the last-used "
                      "profile. Check BrowserProfile in tenants.json." % (APP_NAME, label))
        return 2
    log(a.tenant, "watching daemon PID %d; sign-ins go to %s profile '%s' (%s)"
        % (a.pid, APP_NAME, label, pdir))

    handled = set()     # MSAL `state` values already moved — includes the tab we open
    done_ports = set()  # redirect ports we routed; their "Authentication complete" tab is closed
    while alive(a.pid):
        ports = listener_ports(a.pid)
        finished = done_ports - ports
        if finished:
            # Sign-in completed: MSAL leaves a localhost "Authentication complete" tab behind.
            for tid, url in tabs_matching("http://localhost:"):
                if urlparse(url).port in finished:
                    close_tab(tid)
            done_ports -= finished
        if not ports:
            time.sleep(IDLE_POLL)
            continue
        for tid, url in tabs_matching("login.microsoftonline.com"):
            port, state = redirect_port(url)
            if port not in ports or state in handled:
                continue
            handled.add(state)
            done_ports.add(port)
            close_tab(tid)
            subprocess.run(["open", "-n", "-a", APP, "--args",
                            "--profile-directory=%s" % pdir, "--new-window", url])
            log(a.tenant, "sign-in opened in %s profile '%s'" % (APP_NAME, label))
        time.sleep(ACTIVE_POLL)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
