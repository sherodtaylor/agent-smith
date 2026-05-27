# Declarative Plugin Reconciler

**Date:** 2026-05-27
**Status:** Approved (design phase)
**Owner:** InfraBot
**Scope:** `sherodtaylor/agent-smith` (image-side `agents/_shared/` + `scripts/`)

## Goal

Make plugin installation and upgrade declarative so a manifest in
`agents/_shared/` is the source of truth for which plugins (and which
versions) every agent pod runs. Eliminate the recurring failure mode where
a new plugin release is published, the marketplace is updated, but pods
keep running an old version because `claude plugin install` silently
no-ops when something is already installed.

## Background

The matrix-channel fork release (sherodtaylor/claude-code-channel-matrix
v0.7.0) exposed the gap: `setup.sh` runs
`claude plugin install matrix@claude-code-channel-matrix` on every pod
boot, but the command is idempotent-no-upgrade. After the fork's new
tools (`reply_to_event_id`, `edit_message`, `MATRIX_TYPING`, expanded
instructions, `skills/threading`) shipped, pods continued serving the old
0.6.0 install. `installed_plugins.json` recorded the install date as
five days before the new version was published; nothing in `setup.sh`
ever updated it.

Investigation (systematic-debugging skill applied) traced the full layer
stack:

| Layer | Declarative? | Triggers install/upgrade? |
|---|---|---|
| Plugin repo `.claude-plugin/marketplace.json` | yes (source path; no version field) | no |
| `settings.json.extraKnownMarketplaces` | yes (marketplace source) | no |
| `settings.json.enabledPlugins` | yes (on/off toggle, true-only today) | no — only enable/disable an already-installed plugin |
| `~/.claude/plugins/installed_plugins.json` | no (state file written by CLI) | frozen until `claude plugin install/uninstall` runs |

`claude plugin install --help` confirms there is no `--version` flag.
The installed version is determined entirely by what the marketplace's
current `plugin.json` declares at install time. No native pin-by-version
mechanism exists.

## Decision

Introduce a thin reconciler that converges three pieces of state from
two declarative sources:

- **Sources:** `agents/_shared/settings.json` (marketplaces + enable
  toggles) + new `agents/_shared/plugin-manifest.json` (per-plugin
  declared version)
- **Convergence targets:** registered marketplaces, refreshed marketplace
  caches, installed plugins

The reconciler is a standalone `scripts/reconcile-plugins.sh`. `setup.sh`
calls it where the imperative `claude plugin install` lines used to be.

## Non-Goals

- **MCP server reconciliation.** `.mcp.json` already declares MCP
  servers; `setup.sh`'s existing `cp` of the file into `~/.claude/` is
  sufficient. HTTP MCPs have no version concept (they're cluster-managed
  services); the baked binary `mcp-nats` stays pinned at Dockerfile
  build time.
- **Removing marketplaces no longer in `settings.json`.** If an operator
  drops a marketplace from `extraKnownMarketplaces`, the local cache
  lingers. Harmless; can be swept later.
- **Per-agent plugin overrides.** One global plugin set for all agents
  in this image. Per-agent diffs can be a follow-up; the manifest
  schema leaves room.
- **Multi-tenant version sets.** No "infrabot uses v1, devbot uses v2"
  for the same plugin. If that need emerges, it lands as a separate
  per-agent override layer on top of this manifest.
- **Marketplace source pinning** (e.g., `extraKnownMarketplaces.source.ref`
  to lock the marketplace to a specific git commit). Useful future
  extension, compatible with this design, but out of scope here.
- **Upstream Claude Code feature ask.** A native
  `enabledPlugins: { "x@y": { "version": "0.7.0" } }` with auto-install
  semantics would let us delete this reconciler entirely. File as a
  separate issue; do not gate this work on it.

## Architecture

```
┌──────────────────────────────┐         ┌──────────────────────────────┐
│ agents/_shared/              │         │ agents/_shared/              │
│   settings.json              │         │   plugin-manifest.json       │
│   .extraKnownMarketplaces    │         │   .plugins{name: {version}}  │
│   .enabledPlugins            │         │                              │
└──────────────┬───────────────┘         └──────────────┬───────────────┘
               │                                        │
               └─────────────┬──────────────────────────┘
                             ▼
              ┌────────────────────────────────┐
              │ scripts/reconcile-plugins.sh   │
              │                                │
              │ 1. For each marketplace:       │
              │    add (if missing) + update   │
              │ 2. For each plugin:            │
              │    compare installed vs        │
              │    declared; uninstall+install │
              │    on drift                    │
              └────────────────┬───────────────┘
                               ▼
              ┌────────────────────────────────┐
              │ ~/.claude/plugins/             │
              │   marketplaces/<name>/         │
              │   cache/<plugin>/<version>/    │
              │   installed_plugins.json       │
              └────────────────────────────────┘
```

## Components

### Marketplace lifecycle (handled by reconciler)

For each entry in `settings.json.extraKnownMarketplaces`:

1. **Register** — `claude plugin marketplace add <source>`. Idempotent
   (silent no-op if already added). The marketplace source descriptor
   itself stays in `settings.json` to maintain one place to look for
   "where do plugins come from."
2. **Refresh** — `claude plugin marketplace update <name>`. Pulls the
   latest `marketplace.json` from the source on every reconciler pass.
   This is the missing step today; without it, the local cached
   marketplace never sees new plugin versions even if the upstream repo
   publishes them.
3. **Remove** — out of scope (see Non-Goals).

### Plugin lifecycle (handled by reconciler)

For each entry in `plugin-manifest.json.plugins`:

1. Read `~/.claude/plugins/installed_plugins.json`. Parse the installed
   version for `<name>@<marketplace>`.
2. If `installed_version == declared_version` → no-op.
3. Else (missing, wrong version, or any other mismatch):
   `claude plugin uninstall <name@marketplace> 2>&1 || true`
   `claude plugin install <name@marketplace>`
4. Re-read `installed_plugins.json`. If still mismatched after
   reinstall → log
   `[reconcile] WARN: <name>: declared <X>, marketplace served <Y>`
   and continue. Operator's signal that the manifest is ahead of the
   marketplace (e.g. version not yet published).

### Manifest schema

`agents/_shared/plugin-manifest.json`:

```json
{
  "plugins": {
    "matrix@claude-code-channel-matrix":  { "version": "0.7.0" },
    "superpowers@claude-plugins-official": { "version": "5.1.0" }
  }
}
```

- Map keyed by `<plugin-name>@<marketplace-name>` — same identifier
  `claude plugin install/uninstall` takes.
- Each value is an object (not just a version string) so future
  fields can land additively: `{ "version": "0.7.0", "userConfig":
  { "key": "value" } }` for `claude plugin install --config`,
  `{ "version": "0.7.0", "enabled": false }` to opt out without
  removing the manifest entry, etc.
- The marketplace SOURCE stays declared in `settings.json.extraKnownMarketplaces`.
  Not duplicated here. One place per concern.
- The `enabledPlugins: true` toggle in `settings.json` continues to
  control enable/disable independently of the manifest. The reconciler
  does not touch `enabledPlugins`.

### Reconciler script

**File:** `scripts/reconcile-plugins.sh` (executable bash, ~80 lines)

**Dependencies:** `jq`, `claude plugin` CLI (both already in the image).

**Inputs:**
- `${APP_DIR}/agents/_shared/settings.json` (read for `extraKnownMarketplaces`)
- `${APP_DIR}/agents/_shared/plugin-manifest.json` (read for plugins)
- `${HOME}/.claude/plugins/installed_plugins.json` (read for current state)

**Behavior summary:**

```bash
# Pseudocode
echo "[reconcile] starting"

# Phase 1: marketplaces
for marketplace_name in <keys from settings.json.extraKnownMarketplaces>; do
  source_repo=<source.repo from that entry>
  if not in registered_marketplaces; then
    claude plugin marketplace add "${source_repo}" || warn "register failed"
  fi
  claude plugin marketplace update "${marketplace_name}" || warn "update failed"
done

# Phase 2: plugins
for plugin_id in <keys from plugin-manifest.json.plugins>; do
  declared=<version from manifest>
  installed=<version from installed_plugins.json or "" if absent>
  if [ "${installed}" = "${declared}" ]; then
    echo "[reconcile] ${plugin_id}: in sync at ${declared}"
    continue
  fi
  echo "[reconcile] ${plugin_id}: installed=${installed:-<none>} → declared=${declared}, reinstalling"
  claude plugin uninstall "${plugin_id}" 2>&1 || true
  if ! claude plugin install "${plugin_id}"; then
    warn "${plugin_id}: install failed; pod will continue with no install"
    continue
  fi
  new_installed=<version from re-read installed_plugins.json>
  if [ "${new_installed}" != "${declared}" ]; then
    warn "${plugin_id}: declared ${declared}, marketplace served ${new_installed}"
  fi
done

echo "[reconcile] complete"
exit 0   # always, matches setup.sh's best-effort posture
```

**Logging convention:** `[reconcile]` prefix; severity in caps
(`WARN:`, `FATAL:`) to match `setup.sh`'s existing convention. All
output to stderr so VictoriaLogs ingestion picks it up.

**Failure mode:** Best-effort, fail-open. A single plugin or
marketplace failure does not block the loop or the pod boot. The
reconciler exits 0 regardless. This matches the existing `setup.sh`
warn-and-continue posture for the optional `env-init` hook.

### setup.sh integration

Replace lines 73-77 of `scripts/setup.sh`:

```bash
# Install the Matrix channel plugin from its marketplace. settings.json registers
# the marketplace, but the plugin must be explicitly installed to materialize it.
# TEMPORARY: pointed at sherodtaylor's fork while testing new tools
# (per-call threading, edit_message, MATRIX_TYPING). Revert to zekker6
# after upstream PRs land. Tracking: sherodtaylor/claude-code-channel-matrix#1
claude plugin marketplace add sherodtaylor/claude-code-channel-matrix 2>&1 || true
claude plugin install matrix@claude-code-channel-matrix 2>&1 || true
echo "[setup] matrix channel plugin installed"
```

With:

```bash
# Reconcile plugins declaratively from agents/_shared/plugin-manifest.json.
# Marketplaces are registered + refreshed; installed plugins are upgraded
# to match the manifest's declared versions. Best-effort; failures log
# [reconcile] WARN: ... and do not block boot.
bash "${APP_DIR}/scripts/reconcile-plugins.sh"
```

The `agents/_shared/settings.json` continues to declare
`extraKnownMarketplaces` and `enabledPlugins` (no change). The new
`agents/_shared/plugin-manifest.json` is shipped alongside.

### Tests

**File:** `tests/test-reconcile.sh` (bash, parallel to existing
`tests/test-loops.sh`)

Coverage:

| Case | Setup | Assertion |
|---|---|---|
| Plugin missing | `installed_plugins.json` has no entry for the plugin | reconciler calls `install`; no `uninstall` |
| Plugin at correct version | installed version matches manifest | reconciler logs "in sync"; no `uninstall`/`install` calls |
| Plugin at wrong version | installed version mismatches manifest | reconciler calls `uninstall` then `install` |
| Install failure | mocked `claude plugin install` returns non-zero | reconciler logs WARN, exits 0, moves to next plugin |
| Marketplace not registered | `marketplace add` is called before any plugin op | call order asserted |
| Empty manifest | `plugin-manifest.json` has `{"plugins": {}}` | reconciler exits 0 with no plugin ops |

Mocking strategy: PATH-shimmed `claude` wrapper that records args into a
file the test reads. No network, no real plugin installs. Smoke runs
offline.

## File Map

| File | Change |
|------|--------|
| `agents/_shared/plugin-manifest.json` | **New.** Manifest declaring plugins + versions. Initial content: `matrix@claude-code-channel-matrix: 0.7.0` and `superpowers@claude-plugins-official: 5.1.0`. |
| `scripts/reconcile-plugins.sh` | **New.** Executable bash reconciler (~80 lines). |
| `scripts/setup.sh` | **Modified.** Replace lines 73-77 (imperative `marketplace add` + `install`) with a single `bash "${APP_DIR}/scripts/reconcile-plugins.sh"` invocation. |
| `tests/test-reconcile.sh` | **New.** Smoke tests against PATH-shimmed `claude` CLI. |
| `Dockerfile` | **Unchanged.** No new deps; `jq` already present. |
| `agents/_shared/.mcp.json` | **Unchanged.** Still imperatively copied by setup.sh. |
| `agents/_shared/settings.json` | **Unchanged.** `extraKnownMarketplaces` + `enabledPlugins` continue to declare marketplaces + enable-toggles. |
| `CHANGELOG.md` | **Modified.** Entry under `[Unreleased]` describing the reconciler. |

Estimated diff: ~120 lines added (reconciler + manifest + tests), ~10
removed (the imperative lines in setup.sh), no Dockerfile changes.
Single PR.

## Acceptance Criteria

- [ ] `agents/_shared/plugin-manifest.json` exists and lists every
      plugin already declared in `settings.json.enabledPlugins`.
- [ ] `scripts/reconcile-plugins.sh` exists, executable, runs cleanly
      against a healthy install (zero diffs, exit 0).
- [ ] `scripts/setup.sh` no longer contains imperative
      `claude plugin marketplace add` or `claude plugin install` lines;
      the reconciler is invoked instead.
- [ ] `tests/test-reconcile.sh` runs under `bash` with no external
      network access, asserts all six cases above, exits 0.
- [ ] **End-to-end on the cluster:** after the next agent-smith image
      is cut and homelab chart is bumped, an `infrabot`/`devbot` pod
      boots, runs the reconciler, and `claude plugin list` shows
      `matrix@claude-code-channel-matrix: Version: 0.7.0` (the
      currently-stuck-at-0.6.0 plugin upgrades automatically).
- [ ] Bumping `plugin-manifest.json` to a future version (e.g. 0.7.1
      after a hypothetical fork release) and rolling pods causes the
      upgrade with no other intervention.
- [ ] Declaring a version the marketplace doesn't yet serve produces a
      `[reconcile] WARN:` log line and the pod still boots.

## Risk

- **Reconciler uninstalls a working plugin if the marketplace update
  failed earlier in the same pass.** The naive uninstall→install dance
  destroys a healthy install when the post-uninstall install can't
  reach the marketplace. **Mitigation:** Track per-marketplace
  `marketplace update` success in a bash variable; skip
  `uninstall+install` for plugins whose owning marketplace failed to
  refresh. Equivalent to "only upgrade if we know what to upgrade to."
- **Plugin install side-effects.** Uninstalling a channel plugin
  mid-session may break an active MCP connection (Claude Code spawns
  MCP servers from the install path). Since the reconciler runs in
  `setup.sh` (init container, before the main `agent` container
  starts), this isn't an in-session concern — Claude Code only
  connects after setup.sh completes. Documented for future
  contributors who might consider invoking the reconciler at runtime.
- **Logging verbosity on healthy pods.** Every boot logs at least one
  "in sync" line per declared plugin. With two plugins today this is
  trivial; if the manifest grows, the noise could matter. **Mitigation:**
  the lines are short and prefixed, easy to grep out; revisit if
  >20 plugins ever land.
- **Manifest drift from settings.json `enabledPlugins`.** If a plugin
  is enabled in settings.json but absent from the manifest, the
  reconciler ignores it (no version to converge to). Documented as
  expected: the manifest is the install/version source of truth; the
  enable toggle remains independent. Future hardening could log a WARN
  on plugins enabled-but-not-in-manifest.

## Implementation Note

The marketplace flip in `setup.sh` (`zekker6/...` →
`sherodtaylor/claude-code-channel-matrix`) lives in
`agents/_shared/settings.json.extraKnownMarketplaces` AND in
`scripts/setup.sh`'s imperative `marketplace add` line. After this
work lands, the imperative line is replaced by the reconciler's
phase-1 step, which reads the source from `settings.json`. The
`settings.json` declaration stays as today: pointing at the fork while
we test, slated to revert to `zekker6/...` after the three upstream
PRs land.
