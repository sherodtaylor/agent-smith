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
  EXIT_CODE=0
  HOME="$RC_HOME" claude --remote-control --permission-mode bypassPermissions || EXIT_CODE=$?
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
