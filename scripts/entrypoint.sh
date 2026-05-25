#!/usr/bin/env bash
set -euo pipefail

AGENT_NAME="${AGENT_NAME:?AGENT_NAME must be set}"
PRIMARY_REPO="${PRIMARY_REPO:-homelab}"
WORKDIR="/workspace/${PRIMARY_REPO}"

echo "[entrypoint] agent=${AGENT_NAME} workdir=${WORKDIR}"

# The matrix plugin + marketplace are registered in ~/.claude/settings.json
# (extraKnownMarketplaces + enabledPlugins). --dangerously-load-development-channels
# is required because the plugin is not on the official channel allowlist.
# --remote-control on the same instance exposes this claude for remote drive-in
# under a session name matching the agent (e.g. "infrabot").
CLAUDE_CMD=(
  claude
  --dangerously-load-development-channels plugin:matrix@claude-code-channel-matrix
  --remote-control "${AGENT_NAME}"
  --permission-mode bypassPermissions
)

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
  # Pane 0 (top): the one and only claude — Matrix-driven workhorse with
  # remote-control enabled on the same session.
  tmux new-session -d -s main -x 220 -y 50 -c "${WORKDIR}"
  tmux pipe-pane -t main:0.0 -o 'cat >> /proc/1/fd/1'
  tmux send-keys -t main:0.0 "${CLAUDE_CMD[*]}" Enter
  dispatch main:0.0

  # Pane 1 (bottom): plain shell, for ad-hoc inspection / commands while
  # attached. No second claude — pane 0 already owns the remote-control session.
  tmux split-window -v -t main:0 -c "${WORKDIR}"
  tmux pipe-pane -t main:0.1 -o 'cat >> /proc/1/fd/1'
fi

echo "[entrypoint] tmux 'main': pane 0 = claude (channels + remote-control), pane 1 = shell"
echo "[entrypoint] attach: kubectl exec -it -n agents ${AGENT_NAME}-0 -- tmux attach -t main"

# Keep the container alive; exit if the tmux session dies.
while tmux has-session -t main 2>/dev/null; do
  sleep 30
done
echo "[entrypoint] tmux session ended — exiting"
exit 1
