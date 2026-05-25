#!/usr/bin/env bash
set -euo pipefail

AGENT_NAME="${AGENT_NAME:?AGENT_NAME must be set}"
PRIMARY_REPO="${PRIMARY_REPO:-homelab}"
WORKDIR="/workspace/${PRIMARY_REPO}"

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
fi

echo "[entrypoint] tmux 'main': pane 0 = channels, pane 1 = remote-control claude, pane 2 = keepalive"
echo "[entrypoint] attach: kubectl exec -it -n agents ${AGENT_NAME}-0 -- tmux attach -t main"

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
