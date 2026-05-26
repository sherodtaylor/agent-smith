#!/usr/bin/env bash
set -euo pipefail

AGENT_NAME="${AGENT_NAME:?AGENT_NAME must be set}"
PRIMARY_REPO="${PRIMARY_REPO:-homelab}"
CREDS_SRC="${CREDS_SRC:-/opt/agent-smith/agents/_shared/.credentials.json}"
CREDS_DST="${HOME}/.claude/.credentials.json"
SESSION_DIR="${HOME}/.claude/projects/-workspace-${PRIMARY_REPO}"
BACKOFF=15

if [ ! -f "$CREDS_SRC" ]; then
  echo "[claude-loop] FATAL: credentials template not found at ${CREDS_SRC}" >&2
  exit 1
fi

echo "[claude-loop] starting (agent=${AGENT_NAME})"

while true; do
  # Preserve real tokens written by Claude Code after an OAuth refresh cycle.
  # iron-proxy is configured with require:false — real tokens pass through
  # without swapping. Carry accessToken, refreshToken, and expiresAt forward so
  # Claude continues to self-refresh rather than falling back to stub values.
  _existing=""
  _refresh=""
  _expires=""
  if [ -f "$CREDS_DST" ]; then
    _existing=$(jq -r '.claudeAiOauth.accessToken  // ""' "$CREDS_DST" 2>/dev/null || true)
    _refresh=$(jq  -r '.claudeAiOauth.refreshToken // ""' "$CREDS_DST" 2>/dev/null || true)
    _expires=$(jq  -r '.claudeAiOauth.expiresAt    // ""' "$CREDS_DST" 2>/dev/null || true)
  fi
  if [ -n "$_existing" ] && [ "$_existing" != "access-token-stub" ]; then
    jq --arg access "$_existing" \
       --arg refresh "${_refresh:-refresh-token-stub}" \
       --argjson expires "${_expires:-9999999999999}" \
       '.claudeAiOauth.accessToken = $access | .claudeAiOauth.refreshToken = $refresh | .claudeAiOauth.expiresAt = $expires' \
       "$CREDS_SRC" > "$CREDS_DST"
    echo "[claude-loop] credentials refreshed (real tokens preserved from prior refresh)"
  else
    cp "$CREDS_SRC" "$CREDS_DST"
    echo "[claude-loop] credentials restored from template"
  fi
  chmod 600 "$CREDS_DST"

  RESUME_FLAGS=()
  if [ -d "$SESSION_DIR" ] && [ -n "$(ls -A "$SESSION_DIR" 2>/dev/null)" ]; then
    RESUME_FLAGS=(--continue)
    echo "[claude-loop] resuming prior session from ${SESSION_DIR}"
  fi

  START=$(date +%s)
  EXIT_CODE=0
  claude \
    "${RESUME_FLAGS[@]}" \
    --dangerously-load-development-channels plugin:matrix@claude-code-channel-matrix \
    --remote-control "${AGENT_NAME}" \
    --permission-mode bypassPermissions || EXIT_CODE=$?
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
