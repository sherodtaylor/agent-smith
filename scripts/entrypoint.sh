#!/usr/bin/env bash
set -euo pipefail

AGENT_NAME="${AGENT_NAME:?AGENT_NAME must be set}"
PRIMARY_REPO="${PRIMARY_REPO:-homelab}"
WORKDIR="/workspace/${PRIMARY_REPO}"
PROMPTS_FILE="/opt/agent-smith/agents/${AGENT_NAME}/keepalive-prompts.txt"

echo "[entrypoint] agent=${AGENT_NAME} workdir=${WORKDIR}"

# Stagger devbot/infrabot pod restarts to prevent synchronized restart cadence
STARTUP_JITTER=$(( RANDOM % 45 ))
echo "[entrypoint] startup jitter: sleeping ${STARTUP_JITTER}s"
sleep "$STARTUP_JITTER"

# Poll a tmux pane and drive past the interactive first-run prompts that have no
# headless config bypass (Bypass Permissions warning; development-channels consent
# for --dangerously-load-development-channels).
#
# Quiet-exit only kicks in after the bypass prompt is accepted — before that we
# just wait for claude to finish starting up, which can take 20-30s on a cold
# pull and would previously cause the loop to bail before any prompt appeared.
dispatch() {
  local target="$1"
  local quiet=0
  local pane
  local theme_done=0
  local bypass_done=0
  local devch_done=0
  local resume_done=0
  # Each prompt is accepted at most once — claude's rendered prompt text stays
  # on the pane after acceptance, so a non-idempotent matcher would re-fire and
  # send Down+Enter into the next state (which can pick the wrong option).
  for _ in $(seq 1 60); do
    pane="$(tmux capture-pane -p -t "$target" 2>/dev/null || true)"
    if [ "$theme_done" = 0 ] && printf '%s' "$pane" | grep -q "Choose the text style"; then
      sleep 2
      tmux send-keys -t "$target" Enter
      echo "[entrypoint] $target: auto-accepted theme picker (default)"
      theme_done=1
      quiet=0; sleep 4
    elif [ "$bypass_done" = 0 ] && printf '%s' "$pane" | grep -qE "Bypass.*Permissions"; then
      sleep 2
      tmux send-keys -t "$target" Down
      sleep 0.5
      tmux send-keys -t "$target" Enter
      echo "[entrypoint] $target: auto-accepted Bypass Permissions warning"
      bypass_done=1
      quiet=0; sleep 4
    elif [ "$devch_done" = 0 ] && printf '%s' "$pane" | grep -q "I am using this for local development"; then
      sleep 2
      tmux send-keys -t "$target" Enter
      echo "[entrypoint] $target: auto-accepted development channels prompt"
      devch_done=1
      quiet=0; sleep 4
    elif [ "$resume_done" = 0 ] && printf '%s' "$pane" | grep -q "Resuming the full session"; then
      sleep 2
      tmux send-keys -t "$target" Enter
      echo "[entrypoint] $target: auto-accepted session resume (summary)"
      resume_done=1
      quiet=0; sleep 4
    else
      quiet=$((quiet + 1))
      # Don't exit on quiet until bypass has been handled — before that, claude
      # is still starting up and hasn't shown any prompts yet.
      if [ "$bypass_done" = 1 ] && [ "$quiet" -ge 5 ]; then break; fi
      sleep 2
    fi
  done
}

if ! tmux has-session -t main 2>/dev/null; then
  # Pane 0 (top): the one claude — channels + remote-control.
  # claude-loop.sh restores stub credentials before every start and
  # applies exponential backoff+jitter on crash to prevent tight loops.
  #
  # Name the window "claude" so pane targets use main:claude.0 / main:claude.1
  # instead of numeric indices. This survives dotfiles that set base-index 1,
  # which would shift window 0 to window 1 and break index-based targets.
  tmux new-session -d -s main -n claude -x 220 -y 50 -c "${WORKDIR}"
  # Route pane output to the container's stdout through strip-ansi so
  # VictoriaLogs sees clean text instead of colour/cursor escape codes.
  # The TUI rendering itself (what a human sees on `tmux attach`) is
  # untouched — only the stdout copy is sanitised.
  tmux pipe-pane -t main:claude.0 -o '/opt/agent-smith/scripts/strip-ansi.sh >> /proc/1/fd/1'
  tmux send-keys -t main:claude.0 "bash /opt/agent-smith/scripts/claude-loop.sh" Enter
  dispatch main:claude.0

  # Pane 1 (bottom): plain shell, for ad-hoc inspection / commands while attached.
  tmux split-window -v -t main:claude -c "${WORKDIR}"
  tmux pipe-pane -t main:claude.1 -o '/opt/agent-smith/scripts/strip-ansi.sh >> /proc/1/fd/1'
fi

echo "[entrypoint] tmux 'main': pane 0 = claude (channels + remote-control), pane 1 = shell"
echo "[entrypoint] attach: kubectl exec -it -n agents ${AGENT_NAME}-0 -- tmux attach -t main"

# Keep the container alive; exit if the tmux session dies.
# Every 10s: scan pane 0 for interactive prompts that appear on post-crash restarts.
# Every 1-3hr: inject an organic keep-alive prompt into pane 0 to prevent flat-activity signatures.
NEXT_PROMPT=$(( $(date +%s) + 3600 + RANDOM % 7200 ))

while tmux has-session -t main 2>/dev/null; do
  sleep 10

  capture="$(tmux capture-pane -p -t main:claude.0 2>/dev/null || true)"
  if printf '%s' "$capture" | grep -q "Choose the text style"; then
    tmux send-keys -t main:claude.0 Enter
  fi
  if printf '%s' "$capture" | grep -qE "Bypass.*Permissions"; then
    tmux send-keys -t main:claude.0 Down
    sleep 0.5
    tmux send-keys -t main:claude.0 Enter
  fi
  if printf '%s' "$capture" | grep -q "I am using this for local development"; then
    tmux send-keys -t main:claude.0 Enter
  fi
  if printf '%s' "$capture" | grep -q "Resuming the full session"; then
    tmux send-keys -t main:claude.0 Enter
  fi

  NOW=$(date +%s)
  if [ "$NOW" -ge "$NEXT_PROMPT" ] && [ -f "$PROMPTS_FILE" ]; then
    SNAP1="$(tmux capture-pane -p -t main:claude.0 2>/dev/null || true)"
    sleep 30
    SNAP2="$(tmux capture-pane -p -t main:claude.0 2>/dev/null || true)"
    if [ "$SNAP1" = "$SNAP2" ]; then
      PROMPT="$(shuf -n 1 "$PROMPTS_FILE")"
      tmux send-keys -t main:claude.0 "$PROMPT" Enter
      echo "[entrypoint] keepalive: injected prompt"
    fi
    NEXT_PROMPT=$(( $(date +%s) + 3600 + RANDOM % 7200 ))
  fi
done
echo "[entrypoint] tmux session ended — exiting"
exit 1
