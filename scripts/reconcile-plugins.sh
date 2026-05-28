#!/usr/bin/env bash
# reconcile-plugins.sh — refresh marketplaces and reinstall every enabled
# Claude plugin on each invocation.
#
# Background: Claude Code's settings schema for `enabledPlugins` only
# accepts `true`/`false` — there is no supported semver pin for
# GitHub-source plugins. To make pod bounces pick up upstream plugin
# fixes, we instead uninstall + reinstall every enabled plugin on every
# startup, so the marketplace serves whatever it has at HEAD.
#
# Usage: APP_DIR=/opt/agent-smith CLAUDE_DIR=$HOME/.claude bash reconcile-plugins.sh
#
# Fail-open: set -uo pipefail (no -e). Individual failures are logged as
# warnings; the script always exits 0 so it never blocks agent startup.

set -uo pipefail

# ── Environment ────────────────────────────────────────────────────────────
APP_DIR="${APP_DIR:-/opt/agent-smith}"
CLAUDE_DIR="${CLAUDE_DIR:-${HOME}/.claude}"

SETTINGS="${APP_DIR}/agents/_shared/settings.json"
INSTALLED="${CLAUDE_DIR}/plugins/installed_plugins.json"

# ── Helpers ────────────────────────────────────────────────────────────────
log() {
  echo "[reconcile] $*"
}

warn() {
  echo "[reconcile] WARN: $*" >&2
}

# ── Start ──────────────────────────────────────────────────────────────────
log "starting (APP_DIR=${APP_DIR} CLAUDE_DIR=${CLAUDE_DIR})"

if [ ! -f "${SETTINGS}" ]; then
  warn "settings not found: ${SETTINGS}"
  log "complete"
  exit 0
fi

# ── Phase 1: marketplaces (registration + refresh) ────────────────────────
marketplace_names=$(jq -r '.extraKnownMarketplaces // {} | keys[]' "${SETTINGS}" 2>/dev/null || true)
for marketplace_name in ${marketplace_names}; do
  source_repo=$(jq -r ".extraKnownMarketplaces.\"${marketplace_name}\".source.repo // empty" "${SETTINGS}" 2>/dev/null || true)
  if [ -z "${source_repo}" ]; then
    warn "${marketplace_name}: no source.repo in settings.json — skipping"
    continue
  fi

  # Idempotent: `claude plugin marketplace add` no-ops if already registered.
  if ! claude plugin marketplace add "${source_repo}" 2>&1; then
    warn "${marketplace_name}: marketplace add failed (continuing)"
  fi

  if ! claude plugin marketplace update "${marketplace_name}" 2>&1; then
    warn "${marketplace_name}: marketplace update failed (continuing)"
  fi
done

# ── Phase 2: always-reinstall every enabled plugin ────────────────────────
# For each entry in enabledPlugins whose value is not explicitly false,
# uninstall (if present) and reinstall from the marketplace. This guarantees
# every pod bounce picks up upstream plugin fixes without any version-pin
# dance in settings.json (which Claude Code does not support anyway).
reconcile_plugin() {
  local plugin_id="$1"

  local installed
  installed=$(jq -r ".plugins.\"${plugin_id}\"[0].version // \"\"" "${INSTALLED}" 2>/dev/null || true)

  if [ -n "${installed}" ]; then
    log "${plugin_id}: uninstalling cached ${installed} for fresh reinstall"
    claude plugin uninstall "${plugin_id}" 2>&1 || warn "${plugin_id}: uninstall failed; continuing"
  fi

  log "${plugin_id}: installing latest from marketplace"
  claude plugin install "${plugin_id}" 2>&1 || warn "${plugin_id}: install failed; continuing"
}

# Iterate enabledPlugins; include anything whose value isn't explicit false.
# For an empty map, jq emits nothing and the loop runs zero times.
plugin_ids=$(jq -r '.enabledPlugins // {} | to_entries | map(select(.value != false)) | .[].key' "${SETTINGS}" 2>/dev/null || true)
for plugin_id in ${plugin_ids}; do
  reconcile_plugin "${plugin_id}"
done

log "complete"
exit 0
