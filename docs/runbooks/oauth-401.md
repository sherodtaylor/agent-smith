# Runbook: Anthropic 401 Unauthorized

## Reference scripts

```bash
.claude/references/restart-agent.sh --help
.claude/references/restart-ironproxy.sh
```

Use when an agent's tmux pane shows `401 Unauthorized` from `*.anthropic.com`,
or `kubectl logs` reports auth errors after a successful pod startup.

## Architecture (current)

Each agent holds its own real Claude OAuth session in
`/root/.claude/.credentials.json` on its NFS-backed home PVC. Credentials are
written once by `claude auth login --claudeai` (via `claude-reauth.py`) and
refreshed automatically by the Claude Code CLI on each token expiry. iron-proxy
is configured with `require: false` for Anthropic — real tokens pass through
unchanged.

A 401 means the stored credentials are invalid, expired beyond refresh, or the
CLI's refresh cycle failed.

## Automatic recovery

`claude-loop.sh` calls `claude-reauth.py` at startup and after any short-lived
crash (<60s). `claude-reauth.py` will:

1. Try headless Playwright with the persistent Chrome profile
   (`~/.chrome-profile`).
2. If SSO cookies are still valid — re-auth completes with no human input.
3. If SSO cookies expired — expose a ttyd browser terminal and send a Matrix DM.

Most 401s self-heal within one restart cycle. Check Matrix for a DM from the
bot before taking manual action.

## Manual recovery (SSO cookies expired or Playwright fails)

### 1. Confirm the agent is unauthenticated

```bash
kubectl exec -n agents <agent>-0 -c agent -- claude auth status
```

Expected when broken: `"loggedIn": false` or a non-zero exit.

### 2. Trigger reauth manually

```bash
kubectl exec -n agents <agent>-0 -c agent -- python3 /opt/agent-smith/scripts/claude-reauth.py
```

Watch logs. If headless SSO succeeds you'll see `[reauth] headless SSO
succeeded`. If not, open the tunnel URL from the Matrix DM in your browser and
complete the Google SSO.

### 3. Verify credentials were written

```bash
kubectl exec -n agents <agent>-0 -c agent -- \
  jq -r '.claudeAiOauth | {loggedIn: (.accessToken != "access-token-stub"), expiresAt}' \
  /root/.claude/.credentials.json
```

`loggedIn` should be `true`; `expiresAt` should be in the future.

### 4. Bounce the agent

```bash
.claude/references/restart-agent.sh --agent <agent>
```

`claude-loop.sh` will call `_ensure_auth` on startup — if credentials are now
valid, Claude starts normally.

### 5. Verify end-to-end

```bash
# No new 401s in the last 100 log lines
kubectl logs -n agents <agent>-0 --tail=100 | grep -c "401 Unauthorized"
```

Then send a Matrix message to the agent:

```
@<agent> ping
```

You're looking for the 👀 reaction and a reply within 60s.

## If 401 persists after reauth

Check iron-proxy — a stale upstream token there affects GitHub egress, not
Claude auth (those pass through), but can cause confusing mixed auth failures:

```bash
.claude/references/restart-ironproxy.sh
```

## Why tokens persist across restarts

Credentials are written to `/root/.claude/.credentials.json` on the agent's
home PVC (NFS, survives pod restarts). `setup.sh` in the init container skips
overwriting credentials when the PVC already has real (non-stub) tokens.
`claude-loop.sh` carries real tokens forward on each inner restart. The only
time credentials are lost is a PVC wipe, a manual `claude auth logout`, or a
remote token revocation.
