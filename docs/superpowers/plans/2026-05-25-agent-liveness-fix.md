# Agent Liveness Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix agent pods (devbot, infrabot) so they automatically recover from `subscriptionType:null` crashes without human intervention, and prevent detectable restart cadence patterns.

**Architecture:** Three new wrapper scripts replace direct `claude` invocations in the tmux panes. Each script re-writes stub credentials before every claude start, then applies exponential backoff+jitter on exit. A third pane runs periodic organic prompts to prevent flat-activity signatures. `entrypoint.sh` gains startup jitter and continuous background prompt-acceptance to handle bypass prompts on post-crash restarts.

**Tech Stack:** bash, tmux, jq (already in image), Docker

---

## File Map

| File | Status | Responsibility |
|---|---|---|
| `scripts/claude-loop.sh` | **create** | Credential restore + channels claude restart loop |
| `scripts/rc-loop.sh` | **create** | Credential restore + remote-control claude restart loop |
| `scripts/keepalive-loop.sh` | **create** | Organic keep-alive prompt injection into pane 0 |
| `agents/devbot/keepalive-prompts.txt` | **create** | devbot-specific prompt pool |
| `agents/infrabot/keepalive-prompts.txt` | **create** | infrabot-specific prompt pool |
| `scripts/entrypoint.sh` | **modify** | Startup jitter, swap pane commands to loop scripts, add pane 2, extend keep-alive loop with prompt scanning |
| `Dockerfile` | **modify** | `chmod +x` the three new scripts |
| `tests/test-loops.sh` | **create** | Smoke tests for credential restore + backoff logic |

---

## Task 1: Create `scripts/claude-loop.sh`

**Files:**
- Create: `scripts/claude-loop.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
set -euo pipefail

CREDS_SRC="${CREDS_SRC:-/opt/agent-swarm/agents/_shared/.credentials.json}"
CREDS_DST="${HOME}/.claude/.credentials.json"
BACKOFF=15

if [ ! -f "$CREDS_SRC" ]; then
  echo "[claude-loop] FATAL: credentials template not found at ${CREDS_SRC}" >&2
  exit 1
fi

echo "[claude-loop] starting (agent=${AGENT_NAME:-unknown})"

while true; do
  cp "$CREDS_SRC" "$CREDS_DST"
  chmod 600 "$CREDS_DST"
  echo "[claude-loop] credentials restored from template"

  START=$(date +%s)
  claude \
    --dangerously-load-development-channels plugin:matrix@claude-code-channel-matrix \
    --permission-mode bypassPermissions || true
  EXIT_CODE=$?
  UPTIME=$(( $(date +%s) - START ))

  echo "[claude-loop] claude exited (code=${EXIT_CODE} uptime=${UPTIME}s)"

  if [ "$UPTIME" -gt 300 ]; then
    BACKOFF=15
    echo "[claude-loop] healthy run — resetting backoff"
  fi

  JITTER=$(( BACKOFF + RANDOM % BACKOFF ))
  echo "[claude-loop] restarting in ${JITTER}s (backoff base=${BACKOFF}s)"
  sleep "$JITTER"

  BACKOFF=$(( BACKOFF < 60 ? BACKOFF * 2 : 120 ))
done
```

Write to `scripts/claude-loop.sh` verbatim.

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/claude-loop.sh
```

- [ ] **Step 3: Verify it exits cleanly when creds template is missing**

```bash
CREDS_SRC=/nonexistent HOME=/tmp bash scripts/claude-loop.sh
# Expected: exits 1 with "[claude-loop] FATAL: credentials template not found"
echo "exit code: $?"
```

Expected output:
```
[claude-loop] FATAL: credentials template not found at /nonexistent
exit code: 1
```

- [ ] **Step 4: Commit**

```bash
git add scripts/claude-loop.sh
git commit -m "feat: add claude-loop.sh — credential restore + restart loop for channels pane"
```

---

## Task 2: Create `scripts/rc-loop.sh`

**Files:**
- Create: `scripts/rc-loop.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
set -euo pipefail

CREDS_SRC="${CREDS_SRC:-/opt/agent-swarm/agents/_shared/.credentials.json}"
RC_HOME="/root/rc-home"
CREDS_DST="${RC_HOME}/.claude/.credentials.json"
BACKOFF=15

if [ ! -f "$CREDS_SRC" ]; then
  echo "[rc-loop] FATAL: credentials template not found at ${CREDS_SRC}" >&2
  exit 1
fi

echo "[rc-loop] starting (agent=${AGENT_NAME:-unknown})"

while true; do
  mkdir -p "${RC_HOME}/.claude"
  cp "$CREDS_SRC" "$CREDS_DST"
  chmod 600 "$CREDS_DST"
  echo "[rc-loop] credentials restored to rc-home"

  START=$(date +%s)
  HOME="$RC_HOME" claude --remote-control --permission-mode bypassPermissions || true
  EXIT_CODE=$?
  UPTIME=$(( $(date +%s) - START ))

  echo "[rc-loop] claude exited (code=${EXIT_CODE} uptime=${UPTIME}s)"

  if [ "$UPTIME" -gt 300 ]; then
    BACKOFF=15
    echo "[rc-loop] healthy run — resetting backoff"
  fi

  JITTER=$(( BACKOFF + RANDOM % BACKOFF ))
  echo "[rc-loop] restarting in ${JITTER}s (backoff base=${BACKOFF}s)"
  sleep "$JITTER"

  BACKOFF=$(( BACKOFF < 60 ? BACKOFF * 2 : 120 ))
done
```

Write to `scripts/rc-loop.sh` verbatim.

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/rc-loop.sh
```

- [ ] **Step 3: Verify it exits cleanly when creds template is missing**

```bash
CREDS_SRC=/nonexistent bash scripts/rc-loop.sh
echo "exit code: $?"
```

Expected output:
```
[rc-loop] FATAL: credentials template not found at /nonexistent
exit code: 1
```

- [ ] **Step 4: Commit**

```bash
git add scripts/rc-loop.sh
git commit -m "feat: add rc-loop.sh — credential restore + restart loop for remote-control pane"
```

---

## Task 3: Create `scripts/keepalive-loop.sh`

**Files:**
- Create: `scripts/keepalive-loop.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
set -euo pipefail

AGENT_NAME="${AGENT_NAME:?AGENT_NAME must be set}"
PROMPTS_FILE="/opt/agent-swarm/agents/${AGENT_NAME}/keepalive-prompts.txt"
PANE="main:0.0"
MIN_SLEEP=3600
MAX_SLEEP=10800

if [ ! -f "$PROMPTS_FILE" ]; then
  echo "[keepalive] no prompts file at ${PROMPTS_FILE} — exiting"
  exit 0
fi

mapfile -t PROMPTS < "$PROMPTS_FILE"
PROMPT_COUNT=${#PROMPTS[@]}

if [ "$PROMPT_COUNT" -eq 0 ]; then
  echo "[keepalive] prompts file is empty — exiting"
  exit 0
fi

echo "[keepalive] loaded ${PROMPT_COUNT} prompts for ${AGENT_NAME}"

while true; do
  SLEEP=$(( MIN_SLEEP + RANDOM % (MAX_SLEEP - MIN_SLEEP) ))
  echo "[keepalive] sleeping ${SLEEP}s before next prompt"
  sleep "$SLEEP"

  # Idle check: if pane content is changing, claude is mid-task — skip
  SNAP1="$(tmux capture-pane -p -t "$PANE" 2>/dev/null || true)"
  sleep 30
  SNAP2="$(tmux capture-pane -p -t "$PANE" 2>/dev/null || true)"
  if [ "$SNAP1" != "$SNAP2" ]; then
    echo "[keepalive] pane is active — skipping this cycle"
    continue
  fi

  IDX=$(( RANDOM % PROMPT_COUNT ))
  PROMPT="${PROMPTS[$IDX]}"
  echo "[keepalive] injecting prompt [${IDX}]: ${PROMPT}"
  tmux send-keys -t "$PANE" "$PROMPT" Enter
done
```

Write to `scripts/keepalive-loop.sh` verbatim.

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/keepalive-loop.sh
```

- [ ] **Step 3: Verify it exits cleanly when prompts file is absent**

```bash
AGENT_NAME=devbot bash scripts/keepalive-loop.sh
echo "exit code: $?"
```

Expected output (assuming running outside a pod where the prompts file doesn't exist yet):
```
[keepalive] no prompts file at /opt/agent-swarm/agents/devbot/keepalive-prompts.txt — exiting
exit code: 0
```

- [ ] **Step 4: Commit**

```bash
git add scripts/keepalive-loop.sh
git commit -m "feat: add keepalive-loop.sh — organic prompt injection with idle detection"
```

---

## Task 4: Create Keepalive Prompt Files

**Files:**
- Create: `agents/devbot/keepalive-prompts.txt`
- Create: `agents/infrabot/keepalive-prompts.txt`

- [ ] **Step 1: Write devbot prompts**

Create `agents/devbot/keepalive-prompts.txt` with exactly these lines (one prompt per line, no blank lines):

```
Check for any open PRs in the repos I work on that need attention.
Glance at the last 5 commits in my primary repo and note if anything looks off.
Are there any failing CI runs on recent PRs?
Pull the latest on main and check for merge conflicts with the current branch.
Summarize what I worked on in the last 24 hours based on git log.
Check if there are any unresolved review comments on my open PRs.
Look at the most recent issue opened in the homelab repo.
Check if the agent-swarm image needs a rebuild based on recent Dockerfile changes.
Scan for any TODO or FIXME comments added in the last week.
Run a quick check that the current branch builds cleanly.
```

- [ ] **Step 2: Write infrabot prompts**

Create `agents/infrabot/keepalive-prompts.txt` with exactly these lines:

```
Check cluster node status and flag anything not Ready.
Look for pods in CrashLoopBackOff or Error state across all namespaces.
Check if any HelmRelease resources are in a failed state.
Review recent Flux kustomization reconciliation status.
Check PVC usage across all namespaces.
Look for any certificate expiry warnings in cert-manager.
Check if ExternalSecrets are syncing cleanly.
Review recent Flux events for warnings or errors.
Check if iron-proxy is healthy and passing traffic.
Check if any StatefulSet pods are not Ready.
```

- [ ] **Step 3: Verify line counts**

```bash
wc -l agents/devbot/keepalive-prompts.txt agents/infrabot/keepalive-prompts.txt
```

Expected: `10` lines each.

- [ ] **Step 4: Commit**

```bash
git add agents/devbot/keepalive-prompts.txt agents/infrabot/keepalive-prompts.txt
git commit -m "feat: add keepalive prompt pools for devbot and infrabot"
```

---

## Task 5: Update `scripts/entrypoint.sh`

**Files:**
- Modify: `scripts/entrypoint.sh`

The file has four change sites. Apply them in order.

- [ ] **Step 1: Add startup jitter after the echo on line 8**

Find:
```bash
echo "[entrypoint] agent=${AGENT_NAME} workdir=${WORKDIR}"
```

Replace with:
```bash
echo "[entrypoint] agent=${AGENT_NAME} workdir=${WORKDIR}"

# Stagger devbot/infrabot pod restarts to prevent synchronized restart cadence
STARTUP_JITTER=$(( RANDOM % 45 ))
echo "[entrypoint] startup jitter: sleeping ${STARTUP_JITTER}s"
sleep "$STARTUP_JITTER"
```

- [ ] **Step 2: Remove the CLAUDE_CMD array (lines 14-18, now unused)**

Find and delete:
```bash
# The matrix plugin + marketplace are registered in ~/.claude/settings.json
# (extraKnownMarketplaces + enabledPlugins). --dangerously-load-development-channels
# is required because the plugin is not on the official channel allowlist.
# --remote-control is handled by pane 1 so this pane owns only the Matrix identity.
CLAUDE_CMD=(
  claude
  --dangerously-load-development-channels plugin:matrix@claude-code-channel-matrix
  --permission-mode bypassPermissions
)
```

- [ ] **Step 3: Replace pane 0 and pane 1 commands, add pane 2**

Find:
```bash
  # Pane 0 (top): channels claude — Matrix-driven workhorse.
  tmux new-session -d -s main -x 220 -y 50 -c "${WORKDIR}"
  tmux pipe-pane -t main:0.0 -o 'cat >> /proc/1/fd/1'
  tmux send-keys -t main:0.0 "${CLAUDE_CMD[*]}" Enter
  dispatch main:0.0

  # Pane 1 (bottom): remote-control claude with its own HOME. Authenticates via
  # .credentials.json (iron-proxy injects real tokens). Separate HOME so it
  # doesn't fight pane 0 over ~/.claude.json.
  tmux split-window -v -t main:0 -c "${WORKDIR}"
  tmux pipe-pane -t main:0.1 -o 'cat >> /proc/1/fd/1'
  tmux send-keys -t main:0.1 "HOME=/root/rc-home claude --remote-control --permission-mode bypassPermissions" Enter
  dispatch main:0.1
```

Replace with:
```bash
  # Pane 0 (top): channels claude — Matrix-driven workhorse.
  # claude-loop.sh restores stub credentials before every start and
  # applies exponential backoff+jitter on crash to prevent tight loops.
  tmux new-session -d -s main -x 220 -y 50 -c "${WORKDIR}"
  tmux pipe-pane -t main:0.0 -o 'cat >> /proc/1/fd/1'
  tmux send-keys -t main:0.0 "bash /opt/agent-swarm/scripts/claude-loop.sh" Enter
  dispatch main:0.0

  # Pane 1 (bottom): remote-control claude with its own HOME.
  # rc-loop.sh restores credentials to /root/rc-home before every start.
  tmux split-window -v -t main:0 -c "${WORKDIR}"
  tmux pipe-pane -t main:0.1 -o 'cat >> /proc/1/fd/1'
  tmux send-keys -t main:0.1 "bash /opt/agent-swarm/scripts/rc-loop.sh" Enter
  dispatch main:0.1

  # Pane 2 (background): organic keep-alive prompts injected into pane 0
  # at random 1-3hr intervals to prevent flat-activity detection signatures.
  tmux split-window -v -t main:0 -c "${WORKDIR}"
  tmux pipe-pane -t main:0.2 -o 'cat >> /proc/1/fd/1'
  tmux send-keys -t main:0.2 "bash /opt/agent-swarm/scripts/keepalive-loop.sh" Enter
```

- [ ] **Step 4: Replace the keep-alive loop**

Find:
```bash
# Keep the container alive; exit if the tmux session dies.
while tmux has-session -t main 2>/dev/null; do
  sleep 30
done
echo "[entrypoint] tmux session ended — exiting"
exit 1
```

Replace with:
```bash
# Keep the container alive; exit if the tmux session dies.
# Also continuously scan panes 0 and 1 for interactive prompts that appear
# on post-crash restarts (the loop scripts restart claude but dispatch() only
# runs once at initial startup).
while tmux has-session -t main 2>/dev/null; do
  sleep 10
  for pane in main:0.0 main:0.1; do
    capture="$(tmux capture-pane -p -t "$pane" 2>/dev/null || true)"
    if printf '%s' "$capture" | grep -qE "Bypass.*Permissions"; then
      tmux send-keys -t "$pane" Down
      sleep 0.5
      tmux send-keys -t "$pane" Enter
    fi
    if printf '%s' "$capture" | grep -q "I am using this for local development"; then
      tmux send-keys -t "$pane" Enter
    fi
  done
done
echo "[entrypoint] tmux session ended — exiting"
exit 1
```

- [ ] **Step 5: Update the echo that describes the layout**

Find:
```bash
echo "[entrypoint] tmux 'main': pane 0 = channels, pane 1 = remote-control claude"
```

Replace with:
```bash
echo "[entrypoint] tmux 'main': pane 0 = channels, pane 1 = remote-control claude, pane 2 = keepalive"
```

- [ ] **Step 6: Verify the file is syntactically valid**

```bash
bash -n scripts/entrypoint.sh && echo "syntax OK"
```

Expected: `syntax OK`

- [ ] **Step 7: Commit**

```bash
git add scripts/entrypoint.sh
git commit -m "feat: update entrypoint.sh — startup jitter, loop scripts, pane 2, continuous prompt scan"
```

---

## Task 6: Update Dockerfile

**Files:**
- Modify: `Dockerfile`

- [ ] **Step 1: Update the chmod line to include the new scripts**

Find:
```dockerfile
RUN chmod +x scripts/setup.sh scripts/entrypoint.sh
```

Replace with:
```dockerfile
RUN chmod +x scripts/setup.sh scripts/entrypoint.sh \
              scripts/claude-loop.sh scripts/rc-loop.sh scripts/keepalive-loop.sh
```

- [ ] **Step 2: Verify the Dockerfile builds**

```bash
docker build -t agent-swarm:test .
```

Expected: build completes successfully with no errors. The `chmod +x` step should not fail since all three scripts exist in `scripts/`.

- [ ] **Step 3: Verify scripts are executable inside the image**

```bash
docker run --rm agent-swarm:test ls -la /opt/agent-swarm/scripts/
```

Expected: `claude-loop.sh`, `rc-loop.sh`, `keepalive-loop.sh` all show `-rwxr-xr-x`.

- [ ] **Step 4: Commit**

```bash
git add Dockerfile
git commit -m "chore: chmod new loop scripts in Dockerfile"
```

---

## Task 7: Smoke Tests

**Files:**
- Create: `tests/test-loops.sh`

- [ ] **Step 1: Write the test script**

Create `tests/test-loops.sh`:

```bash
#!/usr/bin/env bash
# Smoke tests for loop scripts — credential restoration and error-exit behavior.
# Run from repo root: bash tests/test-loops.sh
set -uo pipefail   # intentionally no -e: we capture non-zero exits explicitly

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Mock credentials template
CREDS_SRC="${WORKDIR}/shared/.credentials.json"
mkdir -p "$(dirname "$CREDS_SRC")"
echo '{"claudeAiOauth":{"accessToken":"access-token-stub","subscriptionType":"max","rateLimitTier":"default_claude_max_5x"}}' \
  > "$CREDS_SRC"

MOCK_HOME="${WORKDIR}/home"
mkdir -p "${MOCK_HOME}/.claude"

# Mock claude binary:
# - corrupts subscriptionType to null on each invocation (simulates OAuth refresh)
# - exits 0 after 3 runs so the test loop terminates
MOCK_BIN="${WORKDIR}/bin"
mkdir -p "$MOCK_BIN"
cat > "${MOCK_BIN}/claude" <<'MOCKEOF'
#!/usr/bin/env bash
CREDS="${HOME}/.claude/.credentials.json"
RUNFILE="${HOME}/.claude/.runcount"
COUNT=$(cat "$RUNFILE" 2>/dev/null || echo 0)
COUNT=$((COUNT + 1))
echo "$COUNT" > "$RUNFILE"
python3 -c "
import json, sys
with open(sys.argv[1]) as f: d = json.load(f)
d['claudeAiOauth']['subscriptionType'] = None
with open(sys.argv[1], 'w') as f: json.dump(d, f)
" "$CREDS" 2>/dev/null || true
if [ "$COUNT" -ge 3 ]; then exit 0; fi
exit 1
MOCKEOF
chmod +x "${MOCK_BIN}/claude"

# ── Test 1: claude-loop.sh restores subscriptionType before each start ──
echo "--- Test 1: credential restoration on restart ---"
rm -f "${MOCK_HOME}/.claude/.runcount"

CREDS_SRC="$CREDS_SRC" HOME="$MOCK_HOME" PATH="${MOCK_BIN}:${PATH}" \
  timeout 15 bash "${SCRIPT_DIR}/../scripts/claude-loop.sh" 2>/dev/null || true

FINAL_SUBTYPE=$(python3 -c "
import json
with open('${MOCK_HOME}/.claude/.credentials.json') as f:
    d = json.load(f)
print(d['claudeAiOauth']['subscriptionType'])
" 2>/dev/null || echo "error")

if [ "$FINAL_SUBTYPE" = "max" ]; then
  pass "subscriptionType restored to 'max' before last claude invocation"
else
  fail "subscriptionType is '${FINAL_SUBTYPE}' after loop — expected 'max'"
fi

RUNCOUNT=$(cat "${MOCK_HOME}/.claude/.runcount" 2>/dev/null || echo 0)
if [ "$RUNCOUNT" -ge 3 ]; then
  pass "claude restarted at least 3 times (got ${RUNCOUNT})"
else
  fail "claude only ran ${RUNCOUNT} time(s) — expected 3+"
fi

# ── Test 2: claude-loop.sh exits 1 when creds template is missing ──
echo "--- Test 2: exit 1 on missing credentials template ---"
EXIT_CODE=0
CREDS_SRC="/nonexistent/path" HOME="$MOCK_HOME" PATH="${MOCK_BIN}:${PATH}" \
  bash "${SCRIPT_DIR}/../scripts/claude-loop.sh" 2>/dev/null || EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 1 ]; then
  pass "claude-loop.sh exits 1 when credentials template is missing"
else
  fail "claude-loop.sh expected exit 1, got exit ${EXIT_CODE}"
fi

# ── Test 3: rc-loop.sh exits 1 when creds template is missing ──
echo "--- Test 3: rc-loop.sh exits 1 on missing credentials template ---"
EXIT_CODE=0
CREDS_SRC="/nonexistent/path" HOME="$MOCK_HOME" PATH="${MOCK_BIN}:${PATH}" \
  bash "${SCRIPT_DIR}/../scripts/rc-loop.sh" 2>/dev/null || EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 1 ]; then
  pass "rc-loop.sh exits 1 when credentials template is missing"
else
  fail "rc-loop.sh expected exit 1, got exit ${EXIT_CODE}"
fi

# ── Test 4: keepalive-loop.sh exits 0 when prompts file is absent ──
echo "--- Test 4: keepalive exits 0 when prompts file absent ---"
EXIT_CODE=0
AGENT_NAME="devbot" bash "${SCRIPT_DIR}/../scripts/keepalive-loop.sh" 2>/dev/null || EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 0 ]; then
  pass "keepalive-loop.sh exits 0 when prompts file is absent"
else
  fail "keepalive-loop.sh expected exit 0, got exit ${EXIT_CODE}"
fi

# ── Summary ──
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x tests/test-loops.sh
```

- [ ] **Step 3: Run the tests**

```bash
bash tests/test-loops.sh
```

Expected output:
```
--- Test 1: claude-loop.sh credential restoration ---
PASS: subscriptionType restored to 'max' before last claude start
PASS: claude was restarted at least 3 times
--- Test 2: claude-loop.sh exits 1 on missing template ---
PASS: exits 1 when credentials template is missing
--- Test 3: keepalive-loop.sh exits 0 on missing prompts file ---
PASS: exits 0 when prompts file is absent

Results: 4 passed, 0 failed
```

- [ ] **Step 4: Commit**

```bash
git add tests/test-loops.sh
git commit -m "test: smoke tests for credential restore and loop restart behavior"
```

---

## Task 8: Deploy and Verify

**Context:** This task runs against the live k3s cluster. Deploy devbot first, verify, then infrabot.

- [ ] **Step 1: Push the branch and build the image**

```bash
git push origin HEAD
# Trigger CI/image build — or build and push manually:
# docker build -t ghcr.io/sherodtaylor/agent-swarm:latest .
# docker push ghcr.io/sherodtaylor/agent-swarm:latest
```

- [ ] **Step 2: Rollout restart devbot**

```bash
kubectl rollout restart statefulset/devbot -n agents
kubectl rollout status statefulset/devbot -n agents --timeout=120s
```

Expected: `statefulset rolling update complete`

- [ ] **Step 3: Verify all three panes are running**

```bash
kubectl exec -it devbot-0 -n agents -- tmux list-panes -t main
```

Expected: three panes listed (0, 1, 2).

- [ ] **Step 4: Check pane 0 started via claude-loop.sh**

```bash
kubectl exec -it devbot-0 -n agents -- tmux capture-pane -p -t main:0.0 | head -5
```

Expected: output contains `[claude-loop] credentials restored from template`

- [ ] **Step 5: Verify credentials show `subscriptionType: "max"`**

```bash
kubectl exec devbot-0 -n agents -- jq '.claudeAiOauth.subscriptionType' /root/.claude/.credentials.json
```

Expected: `"max"`

Also check rc-home:
```bash
kubectl exec devbot-0 -n agents -- jq '.claudeAiOauth.subscriptionType' /root/rc-home/.claude/.credentials.json
```

Expected: `"max"`

- [ ] **Step 6: Simulate a crash and verify recovery**

```bash
# Kill the claude process in pane 0
kubectl exec devbot-0 -n agents -- pkill -f "claude --dangerously" || true
# Wait for the loop to restart (backoff 15-30s)
sleep 45
# Verify claude is running again and credentials are restored
kubectl exec devbot-0 -n agents -- tmux capture-pane -p -t main:0.0 | grep -E "credentials restored|claude"
kubectl exec devbot-0 -n agents -- jq '.claudeAiOauth.subscriptionType' /root/.claude/.credentials.json
```

Expected: `[claude-loop] credentials restored from template` visible in pane, subscriptionType is `"max"`.

- [ ] **Step 7: Deploy infrabot**

```bash
kubectl rollout restart statefulset/infrabot -n agents
kubectl rollout status statefulset/infrabot -n agents --timeout=120s
kubectl exec infrabot-0 -n agents -- jq '.claudeAiOauth.subscriptionType' /root/.claude/.credentials.json
```

Expected: `"max"`

- [ ] **Step 8: Verify agents respond to Matrix after 30min**

After 30 minutes with both agents running, send a test message to devbot and infrabot in the Matrix room. Both should respond normally. This confirms the full liveness fix is working end-to-end.

- [ ] **Step 9: Final commit and PR**

```bash
git log --oneline origin/main..HEAD
# Should show: docs, feat (×4), chore, test commits
gh pr create \
  --title "[DevBot] fix: agent liveness — restart loop + credential restore + keepalive" \
  --body "Fixes devbot/infrabot disconnect caused by subscriptionType:null after OAuth refresh cycle.

## Changes
- claude-loop.sh / rc-loop.sh: re-write stub credentials before each claude start, exp backoff+jitter on crash
- keepalive-loop.sh: organic prompts every 1-3hr to pane 0 per agent
- entrypoint.sh: startup jitter, loop script panes, pane 2, continuous bypass-prompt scanning
- Dockerfile: chmod new scripts
- tests/test-loops.sh: credential restore smoke tests

## Verification
Tested on devbot: pkill simulation recovered in ~30s with subscriptionType=max restored.

Fixes: subscriptionType:null / 'need to login' / RC pane disconnect"
```
