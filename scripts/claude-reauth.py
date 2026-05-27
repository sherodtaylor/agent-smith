#!/usr/bin/env python3
"""
claude-reauth: automates `claude auth login --claudeai` via Playwright.

Flow:
  1. Spawn `claude auth login --claudeai` subprocess, capture auth URL from stdout.
  2. Try headless Playwright with persistent Chrome profile (~/.chrome-profile).
     - SSO cookies still valid → redirect captured → code fed to subprocess stdin → done.
  3. If SSO needs human (cookies cold/expired):
     - Start ttyd on port 7681 serving `claude auth login --claudeai` directly.
     - Send Matrix DM with the tunnel URL and the auth URL.
     - Poll ~/.claude/.credentials.json until valid (non-stub) tokens appear.
     - Kill ttyd, exit 0.

Environment (inherited from agent container):
  AGENT_NAME              bot name (devbot / infrabot)
  MATRIX_HOMESERVER_URL   Matrix homeserver base URL
  MATRIX_ACCESS_TOKEN     bot's Matrix access token
  MATRIX_ALLOWED_USERS    comma-separated allowlist — first entry gets the DM
  REAUTH_TUNNEL_HOST      external hostname for the tunnel (e.g. devbot-shell.lab.example.dev)
  HOME                    /root (credentials.json lives at $HOME/.claude/.credentials.json)
"""

import json
import os
import re
import subprocess
import sys
import time
import urllib.request
import urllib.error

# ── config ───────────────────────────────────────────────────────────────────
AGENT_NAME     = os.environ.get("AGENT_NAME", "agent")
HOMESERVER     = os.environ.get("MATRIX_HOMESERVER_URL", "").rstrip("/")
BOT_TOKEN      = os.environ.get("MATRIX_ACCESS_TOKEN", "")
NOTIFY_USER    = os.environ.get("MATRIX_ALLOWED_USERS", "").split(",")[0].strip()
TUNNEL_HOST    = os.environ.get("REAUTH_TUNNEL_HOST", "")
HOME_DIR       = os.environ.get("HOME", "/root")
CHROME_PROFILE = os.path.join(HOME_DIR, ".chrome-profile")
CREDS_PATH     = os.path.join(HOME_DIR, ".claude", ".credentials.json")
TTYD_PORT      = 7681
CALLBACK_PFX   = "https://platform.claude.com/oauth/code/callback"
URL_RE         = re.compile(r"https://claude\.com/cai/oauth/authorize\S+")
HUMAN_TIMEOUT  = 600  # 10 minutes


# ── matrix helpers ───────────────────────────────────────────────────────────
def _matrix_request(method, path, body=None):
    if not HOMESERVER or not BOT_TOKEN:
        return None
    url = f"{HOMESERVER}{path}"
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(
        url, data=data, method=method,
        headers={"Authorization": f"Bearer {BOT_TOKEN}",
                 "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        print(f"[reauth] Matrix {method} {path} → {e.code}", file=sys.stderr)
        return None
    except Exception as e:
        print(f"[reauth] Matrix error: {e}", file=sys.stderr)
        return None


def _ensure_dm_room():
    if not NOTIFY_USER:
        return None
    resp = _matrix_request("POST", "/_matrix/client/v3/createRoom", {
        "is_direct": True,
        "invite": [NOTIFY_USER],
        "preset": "trusted_private_chat",
    })
    return resp.get("room_id") if resp else None


def matrix_dm(msg, room_id=None):
    if not room_id:
        room_id = _ensure_dm_room()
    if not room_id:
        print(f"[reauth] Matrix DM skipped (no room): {msg}", file=sys.stderr)
        return
    txn = str(int(time.time() * 1000))
    _matrix_request(
        "PUT",
        f"/_matrix/client/v3/rooms/{urllib.parse.quote(room_id)}"
        f"/send/m.room.message/{txn}",
        {"msgtype": "m.text", "body": msg},
    )


# ── credential helpers ───────────────────────────────────────────────────────
def creds_are_real():
    try:
        with open(CREDS_PATH) as f:
            d = json.load(f)
        tok = d.get("claudeAiOauth", {}).get("accessToken", "")
        return bool(tok) and "stub" not in tok
    except Exception:
        return False


# ── headless playwright attempt ───────────────────────────────────────────────
def try_headless(auth_url, proc):
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        print("[reauth] playwright not installed — skipping headless attempt", file=sys.stderr)
        return None

    code = None
    with sync_playwright() as pw:
        browser = pw.chromium.launch_persistent_context(
            CHROME_PROFILE,
            headless=True,
            args=["--no-sandbox", "--disable-gpu"],
            ignore_https_errors=True,
        )
        page = browser.pages[0] if browser.pages else browser.new_page()
        try:
            page.goto(auth_url, timeout=20_000)
            # Give SSO auto-redirect up to 15s
            deadline = time.time() + 15
            while time.time() < deadline:
                if page.url.startswith(CALLBACK_PFX):
                    m = re.search(r"[?&]code=([^&\s]+)", page.url)
                    if m:
                        code = m.group(1)
                        break
                time.sleep(0.5)
        except Exception as e:
            print(f"[reauth] headless playwright error: {e}", file=sys.stderr)
        finally:
            browser.close()

    if code:
        print("[reauth] headless SSO succeeded")
        proc.stdin.write(code + "\n")
        proc.stdin.flush()
        proc.stdin.close()
        proc.wait(timeout=30)
        return proc.returncode == 0
    return None  # needs human


# ── ttyd tunnel + Matrix fallback ─────────────────────────────────────────────
def human_fallback(auth_url, proc):
    # Kill the headless subprocess — ttyd will run its own `claude auth login`
    try:
        proc.terminate()
        proc.wait(timeout=5)
    except Exception:
        pass

    print(f"[reauth] starting ttyd on :{TTYD_PORT}")
    ttyd = subprocess.Popen(
        ["ttyd", "-p", str(TTYD_PORT), "-t", "fontSize=16",
         "claude", "auth", "login", "--claudeai"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )

    tunnel_url = f"https://{TUNNEL_HOST}" if TUNNEL_HOST else f"http://localhost:{TTYD_PORT}"
    msg = (
        f"[{AGENT_NAME}] Claude auth needed — SSO cookies expired.\n"
        f"Open: {tunnel_url}\n"
        f"Complete the login in the browser terminal, then the bot restarts automatically."
    )
    print(f"[reauth] {msg}")

    import urllib.parse
    room_id = _ensure_dm_room()
    matrix_dm(msg, room_id=room_id)

    # Poll for valid credentials (written by the ttyd session's `claude auth login`)
    print(f"[reauth] waiting up to {HUMAN_TIMEOUT}s for credentials...")
    deadline = time.time() + HUMAN_TIMEOUT
    while time.time() < deadline:
        if creds_are_real():
            print("[reauth] valid credentials detected — auth complete")
            break
        time.sleep(3)
    else:
        print("[reauth] TIMEOUT waiting for human auth", file=sys.stderr)
        ttyd.terminate()
        return False

    ttyd.terminate()
    try:
        ttyd.wait(timeout=5)
    except Exception:
        pass

    matrix_dm(f"[{AGENT_NAME}] Auth complete. Claude is back online.", room_id=room_id)
    return True


# ── main ──────────────────────────────────────────────────────────────────────
def main():
    import urllib.parse  # needed by human_fallback

    print(f"[reauth] starting (agent={AGENT_NAME})")

    # Spawn `claude auth login --claudeai`, capture URL from stdout
    proc = subprocess.Popen(
        ["claude", "auth", "login", "--claudeai"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )

    auth_url = None
    for line in proc.stdout:
        line = line.rstrip()
        print(f"[claude-auth] {line}")
        m = URL_RE.search(line)
        if m:
            auth_url = m.group(0)
            break

    if not auth_url:
        print("[reauth] FATAL: no auth URL in claude output", file=sys.stderr)
        proc.terminate()
        sys.exit(1)

    print(f"[reauth] auth URL captured ({len(auth_url)} chars)")

    # 1. Try headless
    result = try_headless(auth_url, proc)
    if result is True:
        sys.exit(0)
    if result is False:
        sys.exit(1)

    # 2. Headless failed — need human via ttyd tunnel
    ok = human_fallback(auth_url, proc)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
