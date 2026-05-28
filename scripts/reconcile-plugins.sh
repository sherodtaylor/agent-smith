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
# Safety: if a marketplace's `update` fails in Phase 1 we leave the
# cached install of any plugin from that marketplace alone in Phase 2.
# Otherwise an upstream / network blip during bounce would leave the
# pod with no plugin at all until the next bounce.
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

# Marketplaces whose `update` failed this run. Phase 2 will skip
# reinstalling any plugin sourced from one of these, so a transient
# upstream failure doesn't take down the cached install.
failed_marketplaces=""

# ── Phase 1: marketplaces (registration + refresh) ────────────────────────
marketplace_names=$(jq -r '.extraKnownMarketplaces // {} | keys[]' "${SETTINGS}" 2>/dev/null || true)
for marketplace_name in ${marketplace_names}; do
  source_repo=$(jq -r ".extraKnownMarketplaces.\"${marketplace_name}\".source.repo // empty" "${SETTINGS}" 2>/dev/null || true)
  if [ -z "${source_repo}" ]; then
    warn "${marketplace_name}: no source.repo in settings.json — skipping"
    failed_marketplaces="${failed_marketplaces} ${marketplace_name}"
    continue
  fi

  # Idempotent: `claude plugin marketplace add` no-ops if already registered.
  if ! claude plugin marketplace add "${source_repo}" 2>&1; then
    warn "${marketplace_name}: marketplace add failed (continuing)"
    failed_marketplaces="${failed_marketplaces} ${marketplace_name}"
    continue
  fi

  if ! claude plugin marketplace update "${marketplace_name}" 2>&1; then
    warn "${marketplace_name}: marketplace update failed — will preserve cached plugin installs from this marketplace"
    failed_marketplaces="${failed_marketplaces} ${marketplace_name}"
  fi
done

# ── Phase 2: always-reinstall every enabled plugin ────────────────────────
# For each entry in enabledPlugins whose value is `true` or an object,
# uninstall and reinstall from the marketplace. This guarantees every
# pod bounce picks up upstream plugin fixes without any version-pin
# dance in settings.json (which Claude Code does not support anyway).
#
# Plugins sourced from a marketplace whose Phase-1 update failed are
# left as-is so a network/upstream blip doesn't leave the pod with no
# plugin at all.
reconcile_plugin() {
  local plugin_id="$1"

  # Unconditional uninstall — `|| true` tolerates the case where the
  # plugin isn't cached (first run, fresh pod). Avoids reading the
  # sidecar installed_plugins.json that lives in CLAUDE_DIR and may
  # drift from our state.
  log "${plugin_id}: uninstalling any cached install"
  claude plugin uninstall "${plugin_id}" 2>&1 || true

  log "${plugin_id}: installing latest from marketplace"
  claude plugin install "${plugin_id}" 2>&1 || warn "${plugin_id}: install failed — pod will boot without ${plugin_id} until next bounce"
}

# plugin_id format: "<plugin-name>@<marketplace-name>".
plugin_marketplace() {
  echo "${1#*@}"
}

# Treat values that are explicitly true or an object as enabled. Anything
# else (false, null, strings, arrays) is ignored — a typo like `"tru"`
# should not silently install the plugin.
plugin_ids=$(jq -r '
  .enabledPlugins // {}
  | to_entries
  | map(select(.value == true or (.value | type) == "object"))
  | .[].key
' "${SETTINGS}" 2>/dev/null || true)

for plugin_id in ${plugin_ids}; do
  marketplace_name=$(plugin_marketplace "${plugin_id}")
  if [[ " ${failed_marketplaces} " == *" ${marketplace_name} "* ]]; then
    warn "${plugin_id}: marketplace ${marketplace_name} update failed — leaving cached install untouched"
    continue
  fi
  reconcile_plugin "${plugin_id}"
done

log "complete"
exit 0
