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

# ── Case: empty enabledPlugins produces zero plugin operations ──
echo "[case] empty enabledPlugins"
setup_test
# Write a settings.json with marketplaces but no enabledPlugins entries.
cat > "${APP_DIR}/agents/_shared/settings.json" <<'EOF'
{
  "extraKnownMarketplaces": {
    "claude-code-channel-matrix": {
      "source": { "source": "github", "repo": "sherodtaylor/claude-code-channel-matrix" }
    }
  },
  "enabledPlugins": {}
}
EOF
write_installed ""
run_reconciler >/dev/null
plugin_calls=$(grep -E 'plugin install|plugin uninstall' "${CALLS_LOG}" | wc -l | tr -d ' ' || true)
assert_eq "${plugin_calls}" "0" "empty enabledPlugins: no plugin install/uninstall calls"
teardown_test

# ── Case: plugin missing from installed_plugins.json → install ──
echo "[case] plugin missing"
setup_test
write_settings_with_plugin "0.7.0"
write_installed ""
run_reconciler >/dev/null
install_calls=$(grep -E 'plugin install matrix@claude-code-channel-matrix' "${CALLS_LOG}" | wc -l | tr -d ' ' || true)
uninstall_calls=$(grep -E 'plugin uninstall matrix@claude-code-channel-matrix' "${CALLS_LOG}" | wc -l | tr -d ' ' || true)
assert_eq "${install_calls}" "1" "plugin missing: one install call"
assert_eq "${uninstall_calls}" "0" "plugin missing: zero uninstall calls"
teardown_test

# ── Case: plugin already installed → always reinstall (uninstall + install) ──
# Claude Code's enabledPlugins schema doesn't support semver pinning, so on
# every reconcile we wipe the cached install and reinstall fresh.
echo "[case] plugin already installed (always reinstall)"
setup_test
write_settings_with_plugin "0.7.0"
write_installed "0.7.0"
run_reconciler >/dev/null
install_calls=$(grep -E 'plugin install matrix@claude-code-channel-matrix' "${CALLS_LOG}" | wc -l | tr -d ' ' || true)
uninstall_calls=$(grep -E 'plugin uninstall matrix@claude-code-channel-matrix' "${CALLS_LOG}" | wc -l | tr -d ' ' || true)
assert_eq "${install_calls}" "1" "already installed: one install call (always reinstall)"
assert_eq "${uninstall_calls}" "1" "already installed: one uninstall call (always reinstall)"

# Order: uninstall MUST precede install
uninstall_line=$(grep -nE 'plugin uninstall' "${CALLS_LOG}" | head -1 | cut -d: -f1)
install_line=$(grep -nE 'plugin install' "${CALLS_LOG}" | head -1 | cut -d: -f1)
assert_eq "$([ "${uninstall_line:-99}" -lt "${install_line:-0}" ] && echo before || echo not-before)" "before" "already installed: uninstall precedes install"
teardown_test

# ── Case: bare-true enabledPlugins value (no version-pin object) → always reinstall ──
# Mirrors the production _shared/settings.json shape: `"plugin@source": true`.
echo "[case] bare-true value triggers reinstall"
setup_test
cat > "${APP_DIR}/agents/_shared/settings.json" <<'EOF'
{
  "extraKnownMarketplaces": {
    "claude-code-channel-matrix": {
      "source": { "source": "github", "repo": "sherodtaylor/claude-code-channel-matrix" }
    }
  },
  "enabledPlugins": {
    "matrix@claude-code-channel-matrix": true
  }
}
EOF
write_installed "0.7.0"
run_reconciler >/dev/null
install_calls=$(grep -E 'plugin install matrix@claude-code-channel-matrix' "${CALLS_LOG}" | wc -l | tr -d ' ' || true)
uninstall_calls=$(grep -E 'plugin uninstall matrix@claude-code-channel-matrix' "${CALLS_LOG}" | wc -l | tr -d ' ' || true)
assert_eq "${install_calls}" "1" "bare-true value: one install call"
assert_eq "${uninstall_calls}" "1" "bare-true value: one uninstall call"
teardown_test

# ── Case: explicit false enabledPlugins value → no plugin calls ──
echo "[case] explicit false skips plugin"
setup_test
cat > "${APP_DIR}/agents/_shared/settings.json" <<'EOF'
{
  "extraKnownMarketplaces": {
    "claude-code-channel-matrix": {
      "source": { "source": "github", "repo": "sherodtaylor/claude-code-channel-matrix" }
    }
  },
  "enabledPlugins": {
    "matrix@claude-code-channel-matrix": false
  }
}
EOF
write_installed "0.7.0"
run_reconciler >/dev/null
plugin_calls=$(grep -E 'plugin install matrix@|plugin uninstall matrix@' "${CALLS_LOG}" | wc -l | tr -d ' ' || true)
assert_eq "${plugin_calls}" "0" "explicit false: zero plugin install/uninstall calls"
teardown_test

# ── Case: installed != declared → uninstall + install ──
echo "[case] plugin wrong version"
setup_test
write_settings_with_plugin "0.7.0"
write_installed "0.6.0"
run_reconciler >/dev/null
install_calls=$(grep -E 'plugin install matrix@claude-code-channel-matrix' "${CALLS_LOG}" | wc -l | tr -d ' ' || true)
uninstall_calls=$(grep -E 'plugin uninstall matrix@claude-code-channel-matrix' "${CALLS_LOG}" | wc -l | tr -d ' ' || true)
assert_eq "${install_calls}" "1" "wrong version: one install call"
assert_eq "${uninstall_calls}" "1" "wrong version: one uninstall call"

# Order: uninstall MUST precede install
uninstall_line=$(grep -nE 'plugin uninstall' "${CALLS_LOG}" | head -1 | cut -d: -f1)
install_line=$(grep -nE 'plugin install' "${CALLS_LOG}" | head -1 | cut -d: -f1)
assert_eq "$([ "${uninstall_line:-99}" -lt "${install_line:-0}" ] && echo before || echo not-before)" "before" "wrong version: uninstall precedes install"
teardown_test

# ── Case: marketplace registration + update fired before plugin ops ──
echo "[case] marketplace registration"
setup_test
write_settings_with_plugin "0.7.0"
write_installed ""
run_reconciler >/dev/null
mkt_add_calls=$(grep -E 'plugin marketplace add sherodtaylor/claude-code-channel-matrix' "${CALLS_LOG}" | wc -l | tr -d ' ' || true)
mkt_update_calls=$(grep -E 'plugin marketplace update claude-code-channel-matrix' "${CALLS_LOG}" | wc -l | tr -d ' ' || true)
assert_eq "${mkt_add_calls}" "1" "marketplace: one add call"
assert_eq "${mkt_update_calls}" "1" "marketplace: one update call"

# Both marketplace calls MUST precede the plugin install
mkt_last_line=$(grep -nE 'plugin marketplace' "${CALLS_LOG}" | tail -1 | cut -d: -f1)
install_line=$(grep -nE 'plugin install' "${CALLS_LOG}" | head -1 | cut -d: -f1)
assert_eq "$([ "${mkt_last_line:-99}" -lt "${install_line:-0}" ] && echo before || echo not-before)" "before" "marketplace ops precede plugin install"
teardown_test

# ── Case: install command fails → WARN logged, reconciler exits 0 ──
echo "[case] install failure"
setup_test
write_settings_with_plugin "0.7.0"
write_installed ""

# Override the shim to fail on `plugin install`
cat > "${TEST_DIR}/bin/claude" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "${CALLS_LOG}"
case "\$*" in
  "plugin install "*) exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "${TEST_DIR}/bin/claude"

output=$(run_reconciler 2>&1 || true)
rc=$?
assert_eq "${rc}" "0" "install failure: reconciler exits 0"
if echo "${output}" | grep -q '\[reconcile\] WARN:.*install failed'; then
  PASS=$((PASS + 1)); echo "  PASS: install failure: WARN logged"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: install failure: WARN not in output"
  echo "    output: ${output}"
fi
teardown_test

echo "[test-reconcile] summary: pass=${PASS} fail=${FAIL}"
exit $FAIL
