#!/usr/bin/env bash
set -euo pipefail

AGENT_NAME="${AGENT_NAME:?AGENT_NAME must be set}"
APP_DIR="/opt/agent-smith"
AGENT_DIR="${APP_DIR}/agents/${AGENT_NAME}"
CLAUDE_DIR="${HOME}/.claude"

echo "[setup] agent=${AGENT_NAME}"

if [ ! -d "$AGENT_DIR" ]; then
  echo "[setup] FATAL: no AgentConfig at ${AGENT_DIR}" >&2
  exit 1
fi

# Trust the iron-proxy MITM CA so git, gh, curl, and Node all accept its certs.
if [ -n "${IRON_PROXY_CA_CRT:-}" ]; then
  printf '%s' "${IRON_PROXY_CA_CRT}" > /usr/local/share/ca-certificates/iron-proxy.crt
  # Also write to home volume so the main container can find it via NODE_EXTRA_CA_CERTS
  printf '%s' "${IRON_PROXY_CA_CRT}" > "${HOME}/iron-proxy.crt"
  update-ca-certificates 2>/dev/null
  echo "[setup] installed iron-proxy CA"
fi

# Write OAuth credentials only if the PVC doesn't already have real (non-stub)
# tokens. Real credentials persist across pod restarts via the home PVC and are
# managed by claude-reauth.py + Claude Code's own refresh cycle. Overwriting them
# here would blow away a valid session on every pod restart.
_existing_token=""
if [ -f "${CLAUDE_DIR}/.credentials.json" ]; then
  _existing_token=$(jq -r '.claudeAiOauth.accessToken // ""' "${CLAUDE_DIR}/.credentials.json" 2>/dev/null || true)
fi

if [ -n "$_existing_token" ] && [ "$_existing_token" != "access-token-stub" ]; then
  echo "[setup] real credentials already on PVC — preserving (skipping env-var write)"
else
  cp "${APP_DIR}/agents/_shared/.credentials.json" "${CLAUDE_DIR}/.credentials.json"
  chmod 600 "${CLAUDE_DIR}/.credentials.json"
  echo "[setup] wrote stub credentials (claude-reauth will handle real login)"
fi

mkdir -p "${CLAUDE_DIR}/agents" "${CLAUDE_DIR}/channels/matrix"

# CLAUDE.md = shared base + agent persona.
# Mounted ConfigMaps are the source of truth in v0.2.0+:
#   /etc/agent-smith/shared/CLAUDE.md  (one shared CM, chart-mounted)
#   /etc/agent-smith/persona/CLAUDE.md (per-agent CM, chart-mounted)
# Legacy fallback: ${APP_DIR}/agents/<name>/CLAUDE.md (baked into image).
# The mount paths win when present; fallback kicks in only when an
# older chart version (v0.1.x) deploys without the volume mounts.
_SHARED_CLAUDE_MD="/etc/agent-smith/shared/CLAUDE.md"
_PERSONA_CLAUDE_MD="/etc/agent-smith/persona/CLAUDE.md"
if [ -f "${_SHARED_CLAUDE_MD}" ] && [ -f "${_PERSONA_CLAUDE_MD}" ]; then
  cat "${_SHARED_CLAUDE_MD}" "${_PERSONA_CLAUDE_MD}" > "${CLAUDE_DIR}/CLAUDE.md"
  echo "[setup] CLAUDE.md assembled from mounted ConfigMaps"
else
  cat "${APP_DIR}/agents/_shared/CLAUDE.md" "${AGENT_DIR}/CLAUDE.md" \
    > "${CLAUDE_DIR}/CLAUDE.md"
  echo "[setup] CLAUDE.md assembled from baked-in image files (legacy fallback)"
fi

# settings.json from the shared base (carries the channel plugin marketplace)
cp "${APP_DIR}/agents/_shared/settings.json" "${CLAUDE_DIR}/settings.json"

# MCP servers (user scope, applies regardless of cwd)
_PERSONA_MCP_JSON="/etc/agent-smith/persona/mcp.json"
if [ -f "${_PERSONA_MCP_JSON}" ]; then
  cp "${_PERSONA_MCP_JSON}" "${CLAUDE_DIR}/.mcp.json"
else
  cp "${AGENT_DIR}/mcp.json" "${CLAUDE_DIR}/.mcp.json"
fi

# Subagents
if [ -d "${AGENT_DIR}/subagents" ]; then
  cp "${AGENT_DIR}/subagents/"*.md "${CLAUDE_DIR}/agents/" 2>/dev/null || true
fi
echo "[setup] assembled ~/.claude for ${AGENT_NAME}"

# Mark first-run onboarding complete and pre-trust the agent's workspace repos,
# so `claude` started headless doesn't block on the theme picker or trust dialog.
_claude_json="${HOME}/.claude.json"
[ -f "$_claude_json" ] || echo '{}' > "$_claude_json"
jq '.hasCompletedOnboarding = true' "$_claude_json" > "${_claude_json}.tmp" && mv "${_claude_json}.tmp" "$_claude_json"
for repo in ${AGENT_REPOS:-sherodtaylor/homelab}; do
  _path="/workspace/$(basename "$repo")"
  jq --arg p "$_path" \
    '.projects[$p].hasTrustDialogAccepted = true | .projects[$p].hasTrustDialogBashAccepted = true | .projects[$p].hasCompletedProjectOnboarding = true' \
    "$_claude_json" > "${_claude_json}.tmp" && mv "${_claude_json}.tmp" "$_claude_json"
done
echo "[setup] marked onboarding complete + pre-trusted workspace repos"

# Reconcile plugins declaratively from agents/_shared/settings.json:
# extraKnownMarketplaces declares marketplace sources; enabledPlugins
# declares plugin versions (value-shape: { "version": "X.Y.Z" }, or
# plain `true` for "install-if-missing, no drift check"). The reconciler
# refreshes marketplaces, then uninstalls+installs plugins on drift.
# Best-effort: per-plugin or per-marketplace failures log
# [reconcile] WARN: ... and do not block boot.
bash "${APP_DIR}/scripts/reconcile-plugins.sh"

# Matrix channel config from env
cat > "${CLAUDE_DIR}/channels/matrix/.env" <<EOF
MATRIX_HOMESERVER_URL=${MATRIX_HOMESERVER_URL}
MATRIX_ACCESS_TOKEN=${MATRIX_ACCESS_TOKEN}
MATRIX_BOT_USER_ID=${MATRIX_BOT_USER_ID}
EOF

# Access allowlist — who may trigger this bot
ALLOWED="${MATRIX_ALLOWED_USERS:-@sherod:lab.sherodtaylor.dev}"
jq -Rn --arg allowed "$ALLOWED" \
  '{"allowedUsers": [$allowed | split(",")[] | ltrimstr(" ") | rtrimstr(" ") | select(length > 0)], "ackReaction": "👀"}' \
  > "${CLAUDE_DIR}/channels/matrix/access.json"
echo "[setup] wrote Matrix channel config"

# git / gh auth — GITHUB_TOKEN is already in the environment, so `gh` uses it
# automatically. `gh auth login` refuses to run while the env var is set, so we
# only wire `git` to the token for HTTPS clone/push.
#
# git HTTPS uses Basic Auth (base64-encoded credentials) which iron-proxy cannot
# swap (it matches plain-text stub values). GIT_GITHUB_TOKEN carries the real
# token specifically for .git-credentials so git clone/pull/push work. The main
# container keeps GITHUB_TOKEN=proxy-token-github so gh/API calls still go
# through iron-proxy's swap. The CA cert is wired into git config so iron-proxy's
# MITM certs are trusted in the main container (which skips update-ca-certificates).
_GIT_TOKEN="${GIT_GITHUB_TOKEN:-${GITHUB_TOKEN}}"
git config --global user.name  "${AGENT_NAME}"
git config --global user.email "${AGENT_NAME}@lab.sherodtaylor.dev"
git config --global http.sslCAInfo "${HOME}/iron-proxy.crt"
if [ -n "${_GIT_TOKEN:-}" ]; then
  git config --global credential.helper store
  printf 'https://x-access-token:%s@github.com\n' "${_GIT_TOKEN}" > "${HOME}/.git-credentials"
  chmod 600 "${HOME}/.git-credentials"
  echo "[setup] git credentials configured (GIT_GITHUB_TOKEN for clone/push, GITHUB_TOKEN for gh API)"
fi

# Clone working repos
mkdir -p /workspace
for repo in ${AGENT_REPOS:-sherodtaylor/homelab}; do
  name="$(basename "$repo")"
  if [ ! -d "/workspace/${name}/.git" ]; then
    git clone "https://github.com/${repo}.git" "/workspace/${name}"
    echo "[setup] cloned ${repo}"
  else
    git -C "/workspace/${name}" pull --ff-only || true
    echo "[setup] updated ${repo}"
  fi
done

# Optional user-supplied environment-init hook (e.g. dotfiles installer,
# per-user tooling, extra credentials). Runs after CA/git/.claude/repos are
# in place. Best-effort: a failure logs a warning and does NOT block the pod.
if [ -n "${SETUP_COMMAND:-}" ]; then
  _SETUP_TIMEOUT="${SETUP_TIMEOUT_SECONDS:-600}"
  echo "[setup] env-init: running user hook (${_SETUP_TIMEOUT}s timeout)"
  # `bash -o pipefail -c` ensures a failed `curl ... | bash` propagates the
  # curl exit code through the pipeline — without this, a 404/DNS/iron-proxy
  # denial silently yields exit 0 (bash reads EOF on an empty stream) and the
  # hook lies "ok" while the pod boots with nothing installed.
  #
  # Default timeout is 600s — enough for a full dotfiles install including
  # apt packages, toolchain downloads (nvm, rustup, etc.). Override via
  # SETUP_TIMEOUT_SECONDS env var if you need more or less time.
  if ( cd "${HOME}" && timeout "$_SETUP_TIMEOUT" bash -o pipefail -c "${SETUP_COMMAND}" ); then
    echo "[setup] env-init: hook ok"
  else
    rc=$?
    echo "[setup] WARN: env-init hook exited ${rc} (continuing)" >&2
  fi
else
  echo "[setup] env-init: no setup.command configured, skipping"
fi

echo "[setup] complete"
