#!/usr/bin/env bash
# Smoke tests for scripts/reconcile-plugins.sh. Mocks `claude` via a
# PATH-shimmed wrapper that records every invocation to a temp file,
# then asserts the reconciler emits the correct call sequence for
# each starting state.
#
# Run from repo root: bash tests/test-reconcile.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

# ── assert_eq <actual> <expected> <label> ──────────────────────────────────
assert_eq() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $label"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label"
    echo "    expected: $expected"
    echo "    actual:   $actual"
  fi
}

# ── setup_test ─────────────────────────────────────────────────────────────
# Creates a self-contained temp directory with:
#   - ${TEST_DIR}/bin/claude  — PATH-shimmed mock that records args to calls.log
#   - ${APP_DIR}/agents/_shared/  — fake app dir for settings.json
#   - ${CLAUDE_DIR}/plugins/      — fake claude dir for installed_plugins.json
#   - ${HOME}/.claude             — symlink → ${CLAUDE_DIR}
#
# Sets globals: TEST_DIR, APP_DIR, CLAUDE_DIR, CALLS_LOG, ORIG_PATH
setup_test() {
  TEST_DIR="$(mktemp -d)"
  APP_DIR="${TEST_DIR}/app"
  CLAUDE_DIR="${TEST_DIR}/claude"
  CALLS_LOG="${TEST_DIR}/calls.log"
  ORIG_PATH="$PATH"

  mkdir -p "${APP_DIR}/agents/_shared" "${CLAUDE_DIR}/plugins" "${TEST_DIR}/bin" "${TEST_DIR}/home"
  : > "${CALLS_LOG}"

  # Write the claude shim. By default it records all args and exits 0.
  # Per-test code can rewrite this file mid-test to simulate failures.
  cat > "${TEST_DIR}/bin/claude" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "${CALLS_LOG}"
exit 0
EOF
  chmod +x "${TEST_DIR}/bin/claude"

  export PATH="${TEST_DIR}/bin:${ORIG_PATH}"
  export HOME="${TEST_DIR}/home"
  ln -sf "${CLAUDE_DIR}" "${HOME}/.claude"
}

# ── teardown_test ──────────────────────────────────────────────────────────
teardown_test() {
  export PATH="${ORIG_PATH}"
  rm -rf "${TEST_DIR}"
  unset TEST_DIR APP_DIR CLAUDE_DIR CALLS_LOG ORIG_PATH
}

# ── write_settings_with_plugin <version> ──────────────────────────────────
# Writes ${APP_DIR}/agents/_shared/settings.json with:
#   - extraKnownMarketplaces.claude-code-channel-matrix pointing at
#     sherodtaylor/claude-code-channel-matrix
#   - enabledPlugins."matrix@claude-code-channel-matrix" = { "version": "<version>" }
#
# For the empty-enabledPlugins case, tests write a different settings.json
# inline — no separate helper needed.
write_settings_with_plugin() {
  local version="$1"
  cat > "${APP_DIR}/agents/_shared/settings.json" <<EOF
{
  "extraKnownMarketplaces": {
    "claude-code-channel-matrix": {
      "source": { "source": "github", "repo": "sherodtaylor/claude-code-channel-matrix" }
    }
  },
  "enabledPlugins": {
    "matrix@claude-code-channel-matrix": { "version": "${version}" }
  }
}
EOF
}

# ── write_installed <version> ─────────────────────────────────────────────
# Writes ${CLAUDE_DIR}/plugins/installed_plugins.json.
# If <version> is empty, writes an empty plugins map.
# Otherwise, writes a single entry for matrix@claude-code-channel-matrix
# at the given version.
write_installed() {
  local version="$1"
  if [ -z "$version" ]; then
    cat > "${CLAUDE_DIR}/plugins/installed_plugins.json" <<'EOF'
{ "version": 2, "plugins": {} }
EOF
  else
    cat > "${CLAUDE_DIR}/plugins/installed_plugins.json" <<EOF
{
  "version": 2,
  "plugins": {
    "matrix@claude-code-channel-matrix": [
      { "scope": "user", "installPath": "/fake", "version": "${version}" }
    ]
  }
}
EOF
  fi
}

# ── run_reconciler ─────────────────────────────────────────────────────────
# Exports APP_DIR and CLAUDE_DIR, then invokes the reconciler.
# The reconciler script need not exist yet — this helper defines the
# invocation shape for all subsequent test cases.
run_reconciler() {
  APP_DIR="${APP_DIR}" CLAUDE_DIR="${CLAUDE_DIR}" \
    bash "${REPO_ROOT}/scripts/reconcile-plugins.sh" 2>&1
}

# ── Harness ready ──────────────────────────────────────────────────────────
echo "[test-reconcile] harness loaded"
echo "[test-reconcile] summary: pass=${PASS} fail=${FAIL}"
exit $FAIL
