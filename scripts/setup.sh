#!/usr/bin/env bash
set -euo pipefail

AGENT_NAME="${AGENT_NAME:?AGENT_NAME must be set}"
APP_DIR="/opt/agent-swarm"
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
  update-ca-certificates 2>/dev/null
  echo "[setup] installed iron-proxy CA"
fi

# Write a credentials file with placeholder tokens so Claude Code treats this as
# a real user session (required for --remote-control). Iron-proxy intercepts all
# *.anthropic.com requests and replaces proxy-token-claude with the real OAuth token.
python3 - <<'PY'
import json, os
p = os.path.expanduser("~/.claude/.credentials.json")
creds = {
    "claudeAiOauth": {
        "accessToken": "access-token-stub",
        "refreshToken": "refresh-token-stub",
        "expiresAt": 9999999999999,
        "scopes": ["user:file_upload", "user:inference", "user:mcp_servers", "user:profile", "user:sessions:claude_code"],
        "subscriptionType": "max",
        "rateLimitTier": "default_claude_max_5x"
    }
}
os.makedirs(os.path.dirname(p), exist_ok=True)
json.dump(creds, open(p, "w"))
os.chmod(p, 0o600)
PY
echo "[setup] wrote placeholder credentials (iron-proxy will inject real token)"

mkdir -p "${CLAUDE_DIR}/agents" "${CLAUDE_DIR}/channels/matrix"

# CLAUDE.md = shared base + agent persona
cat "${APP_DIR}/agents/_shared/CLAUDE.md" "${AGENT_DIR}/CLAUDE.md" \
  > "${CLAUDE_DIR}/CLAUDE.md"

# settings.json from the shared base (carries the channel plugin marketplace)
cp "${APP_DIR}/agents/_shared/settings.json" "${CLAUDE_DIR}/settings.json"

# MCP servers (user scope, applies regardless of cwd)
cp "${AGENT_DIR}/mcp.json" "${CLAUDE_DIR}/.mcp.json"

# Subagents
if [ -d "${AGENT_DIR}/subagents" ]; then
  cp "${AGENT_DIR}/subagents/"*.md "${CLAUDE_DIR}/agents/" 2>/dev/null || true
fi
echo "[setup] assembled ~/.claude for ${AGENT_NAME}"

# Mark first-run onboarding complete and pre-trust the agent's workspace repos,
# so `claude` started headless doesn't block on the theme picker or trust dialog.
python3 - <<'PY'
import json, os
p = os.path.expanduser("~/.claude.json")
try:
    d = json.load(open(p))
except Exception:
    d = {}
d["hasCompletedOnboarding"] = True
projects = d.setdefault("projects", {})
for repo in os.environ.get("AGENT_REPOS", "sherodtaylor/homelab").split():
    path = "/workspace/" + repo.split("/")[-1]
    proj = projects.setdefault(path, {})
    proj["hasTrustDialogAccepted"] = True
    proj["hasTrustDialogBashAccepted"] = True
    proj["hasCompletedProjectOnboarding"] = True
json.dump(d, open(p, "w"))
PY
echo "[setup] marked onboarding complete + pre-trusted workspace repos"

# Install the Matrix channel plugin from its marketplace. settings.json registers
# the marketplace, but the plugin must be explicitly installed to materialize it.
claude plugin marketplace add zekker6/claude-code-channel-matrix 2>&1 || true
claude plugin install matrix@claude-code-channel-matrix 2>&1 || true
echo "[setup] matrix channel plugin installed"

# Matrix channel config from env
cat > "${CLAUDE_DIR}/channels/matrix/.env" <<EOF
MATRIX_HOMESERVER_URL=${MATRIX_HOMESERVER_URL}
MATRIX_ACCESS_TOKEN=${MATRIX_ACCESS_TOKEN}
MATRIX_BOT_USER_ID=${MATRIX_BOT_USER_ID}
EOF

# Access allowlist — who may trigger this bot
ALLOWED="${MATRIX_ALLOWED_USERS:-@sherod:lab.sherodtaylor.dev}"
python3 - "$ALLOWED" > "${CLAUDE_DIR}/channels/matrix/access.json" <<'PY'
import json, sys
users = [u.strip() for u in sys.argv[1].split(",") if u.strip()]
print(json.dumps({"allowedUsers": users, "ackReaction": "👀"}, indent=2))
PY
echo "[setup] wrote Matrix channel config"

# git / gh auth — GITHUB_TOKEN is already in the environment, so `gh` uses it
# automatically. `gh auth login` refuses to run while the env var is set, so we
# only wire `git` to the token for HTTPS clone/push.
git config --global user.name  "${AGENT_NAME}"
git config --global user.email "${AGENT_NAME}@lab.sherodtaylor.dev"
if [ -n "${GITHUB_TOKEN:-}" ]; then
  git config --global credential.helper store
  printf 'https://x-access-token:%s@github.com\n' "${GITHUB_TOKEN}" > "${HOME}/.git-credentials"
  chmod 600 "${HOME}/.git-credentials"
  echo "[setup] git credentials configured (gh uses GITHUB_TOKEN from env)"
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

echo "[setup] complete"

# Mirror the assembled HOME to /root-rc for the dedicated remote-control claude.
RC_HOME="/root/rc-home"
mkdir -p "${RC_HOME}/.claude/agents"
cp -a "${HOME}/.claude/CLAUDE.md"  "${RC_HOME}/.claude/" 2>/dev/null || true
cp -a "${HOME}/.claude/.mcp.json"  "${RC_HOME}/.claude/" 2>/dev/null || true
if [ -d "${HOME}/.claude/agents" ]; then
  cp -a "${HOME}/.claude/agents/." "${RC_HOME}/.claude/agents/" 2>/dev/null || true
fi
# settings.json with channels-related keys stripped so the RC instance
# does NOT load the matrix channel plugin (the channels pane already owns
# the @<agent>:lab.sherodtaylor.dev Matrix identity).
python3 - <<PY
import json
src = json.load(open("${HOME}/.claude/settings.json"))
strip = {"channelsEnabled", "extraKnownMarketplaces", "enabledPlugins"}
dst = {k: v for k, v in src.items() if k not in strip}
json.dump(dst, open("${RC_HOME}/.claude/settings.json", "w"), indent=2)
PY
# Pre-seed RC's .claude.json with the onboarding + per-repo trust flags
# directly (don't rely on cp — claude may rewrite the file on first run with
# default content, dropping our flags).
python3 - <<PY
import json, os
p = "${RC_HOME}/.claude.json"
try:
    d = json.load(open(p))
except Exception:
    d = {}
d["hasCompletedOnboarding"] = True
projects = d.setdefault("projects", {})
for repo in os.environ.get("AGENT_REPOS", "sherodtaylor/homelab").split():
    path = "/workspace/" + repo.split("/")[-1]
    proj = projects.setdefault(path, {})
    proj["hasTrustDialogAccepted"] = True
    proj["hasTrustDialogBashAccepted"] = True
    proj["hasCompletedProjectOnboarding"] = True
json.dump(d, open(p, "w"))
PY
[ -f "${HOME}/.gitconfig" ]       && cp "${HOME}/.gitconfig"       "${RC_HOME}/.gitconfig"
[ -f "${HOME}/.git-credentials" ] && cp "${HOME}/.git-credentials" "${RC_HOME}/.git-credentials" && chmod 600 "${RC_HOME}/.git-credentials"
if [ -f "${CLAUDE_DIR}/.credentials.json" ]; then
  cp "${CLAUDE_DIR}/.credentials.json" "${RC_HOME}/.claude/.credentials.json"
  chmod 600 "${RC_HOME}/.claude/.credentials.json"
fi
echo "[setup] mirrored config to ${RC_HOME} for remote-control claude"
