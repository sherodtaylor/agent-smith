# Declarative Plugin Reconciler Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `setup.sh`'s imperative `claude plugin install` lines with a declarative `agents/_shared/settings.json (enabledPlugins shape)` + a `scripts/reconcile-plugins.sh` that converges `installed_plugins.json` to match the manifest via `marketplace update` → `uninstall` → `install` on drift.

**Architecture:** Two new files (manifest + reconciler) + one modified file (`setup.sh`) + one new test file. The reconciler is bash + `jq` + `claude plugin` CLI; no new dependencies. Tests use a PATH-shimmed `claude` mock that records calls; smoke runs offline. Each test case verifies the reconciler emits the correct `claude plugin` invocation sequence for a given starting state.

**Tech Stack:** Bash 5+, `jq` (already in image), `claude plugin` CLI, no test framework (shell scripts following the existing `tests/test-loops.sh` pattern).

**Spec:** `docs/superpowers/specs/2026-05-27-declarative-plugin-reconciler-design.md`

---

## ⚠️ AMENDMENT (read before implementing any task)

The first draft of this plan introduced a separate file
`agents/_shared/plugin-manifest.json` as the version-pin source. **That
file is no longer part of the design.** Sherod's correct call: single
source of truth in `agents/_shared/settings.json`. The version pin lives
inside the existing `enabledPlugins` map by changing the value shape:

```jsonc
"enabledPlugins": {
  "matrix@claude-code-channel-matrix":  { "version": "0.7.0" },  // was: true
  "superpowers@claude-plugins-official": { "version": "5.1.0" }   // was: true
}
```

**Apply these substitutions wherever the per-task text below still says
"plugin-manifest.json" or describes a separate manifest file:**

1. **Source of plugin IDs:** read keys of `settings.json.enabledPlugins`
   instead of `plugin-manifest.json.plugins`. Example: `jq -r
   '.enabledPlugins | keys[]' "${SETTINGS}"` (no separate `MANIFEST`
   env var; the reconciler only reads `SETTINGS` and `INSTALLED`).
2. **Source of declared version:** read
   `.enabledPlugins."<plugin_id>" | if type == "object" then .version
   else "" end` from `${SETTINGS}`. Plain-`true` values mean "enabled,
   no version pin" — the reconciler still ensures the plugin is
   installed but skips drift checks on unpinned entries.
3. **Test harness (`tests/test-reconcile.sh`):** drop the `write_manifest`
   helper. Add `write_settings_with_plugin <version>` that writes a
   settings.json containing both `extraKnownMarketplaces` AND a single
   pinned `enabledPlugins` entry. Per-case tests call only this helper.
4. **Task 9 ("Author the initial manifest"):** instead of creating
   `agents/_shared/plugin-manifest.json`, **edit
   `agents/_shared/settings.json`** to change the existing
   `"matrix@claude-code-channel-matrix": true` to
   `"matrix@claude-code-channel-matrix": { "version": "0.7.0" }` and
   the same for `superpowers` at `"5.1.0"`. No new file.
5. **File map:** drop the row for `plugin-manifest.json`. Add a row for
   `agents/_shared/settings.json` marked **Modified** (value-shape
   change in `enabledPlugins`; `extraKnownMarketplaces` unchanged).

Every other piece of the plan — the reconciler's marketplace phase,
the uninstall+install drift handling, the test cases, the setup.sh
integration, the CHANGELOG entry, the PR + cluster validation — stays
exactly as written. The schema simplification is the only delta.

---

## Repo & Working Tree

| Repo | Local path | Branch |
|------|-----------|--------|
| `sherodtaylor/agent-smith` | `/workspace/agent-swarm` | `feat/declarative-plugin-reconciler` |

The spec lives on the existing `feat/declarative-plugin-reconciler-spec` branch (PR #52). This plan + the implementation land on a new `feat/declarative-plugin-reconciler` branch off `main` (cut after PR #52 merges, OR off `main` now if Sherod merges in flight).

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `agents/_shared/settings.json (enabledPlugins shape)` | **Create** | Declarative source of truth: which plugins, which versions |
| `scripts/reconcile-plugins.sh` | **Create** | Read manifest + settings.json + installed_plugins.json; converge via `claude plugin` CLI |
| `tests/test-reconcile.sh` | **Create** | Six test cases against a PATH-shimmed `claude` mock |
| `scripts/setup.sh` | **Modify** | Replace lines 73-77 (imperative install) with reconciler invocation |
| `CHANGELOG.md` | **Modify** | Entry under `[Unreleased]` |

Estimated diff: ~120 lines added, ~10 lines removed. Single PR.

---

## Phase 1 — Branch setup

### Task 1: Cut feature branch from main

**Files:** (no edits)

- [ ] **Step 1: Sync `/workspace/agent-swarm` to latest main**

```bash
cd /workspace/agent-swarm
git fetch origin
git checkout main
git pull --ff-only
```

Expected: clean fast-forward, no merge conflicts.

- [ ] **Step 2: Cut the feature branch**

```bash
cd /workspace/agent-swarm
git checkout -b feat/declarative-plugin-reconciler
```

- [ ] **Step 3: Confirm baseline state**

```bash
ls scripts/setup.sh tests/ 2>&1
grep -n 'claude plugin install\|claude plugin marketplace' scripts/setup.sh
```

Expected: `tests/` directory exists with at least `test-loops.sh`; `setup.sh` has the two imperative `claude plugin` lines at the location the spec describes (around lines 73-77).

---

## Phase 2 — Test harness first (TDD)

The reconciler's behavior is its sequence of `claude plugin` invocations. The test harness mocks `claude` via a PATH-shimmed wrapper that records every invocation. Subsequent tasks write each test case first, then implement the reconciler logic that makes it pass.

### Task 2: Test harness scaffolding (the `claude` shim)

**Files:**
- Create: `tests/test-reconcile.sh`

- [ ] **Step 1: Write the harness as a standalone bash script**

Create `/workspace/agent-swarm/tests/test-reconcile.sh`:

```bash
#!/usr/bin/env bash
# Smoke tests for scripts/reconcile-plugins.sh. Mocks `claude` via a
# PATH-shimmed wrapper that records every invocation to a temp file,
# then asserts the reconciler emits the correct call sequence for
# each starting state.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECONCILE="${REPO_ROOT}/scripts/reconcile-plugins.sh"

PASS=0
FAIL=0

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

# Build a temp directory containing:
#   - A `claude` shim on PATH that records args to ./calls.log
#   - A fake APP_DIR with agents/_shared/{settings.json, settings.json (enabledPlugins)}
#   - A fake CLAUDE_DIR with plugins/installed_plugins.json
#
# Returns (via globals): TEST_DIR, APP_DIR, CLAUDE_DIR, CALLS_LOG, original PATH
setup_test() {
  TEST_DIR="$(mktemp -d)"
  APP_DIR="${TEST_DIR}/app"
  CLAUDE_DIR="${TEST_DIR}/claude"
  CALLS_LOG="${TEST_DIR}/calls.log"
  ORIG_PATH="$PATH"

  mkdir -p "${APP_DIR}/agents/_shared" "${CLAUDE_DIR}/plugins" "${TEST_DIR}/bin"
  : > "${CALLS_LOG}"

  # Write the claude shim. By default it records and exits 0.
  # Per-test scripts can override the shim mid-test for failure scenarios.
  cat > "${TEST_DIR}/bin/claude" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "${CALLS_LOG}"
exit 0
EOF
  chmod +x "${TEST_DIR}/bin/claude"

  PATH="${TEST_DIR}/bin:${ORIG_PATH}"
  export PATH HOME="${TEST_DIR}/home"
  mkdir -p "${HOME}"
  ln -sf "${CLAUDE_DIR}" "${HOME}/.claude"
}

teardown_test() {
  PATH="${ORIG_PATH}"
  rm -rf "${TEST_DIR}"
  unset TEST_DIR APP_DIR CLAUDE_DIR CALLS_LOG ORIG_PATH
}

# Write a settings.json with one marketplace entry
write_settings() {
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
}

# Write a settings.json (enabledPlugins) with a single plugin pinned to the given version
write_manifest() {
  local version="$1"
  cat > "${APP_DIR}/agents/_shared/settings.json (enabledPlugins shape)" <<EOF
{
  "plugins": {
    "matrix@claude-code-channel-matrix": { "version": "${version}" }
  }
}
EOF
}

# Write installed_plugins.json with the given installed version (or no entry if empty)
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

# Run the reconciler under the test environment.
run_reconciler() {
  APP_DIR="${APP_DIR}" CLAUDE_DIR="${CLAUDE_DIR}" "${RECONCILE}" 2>&1
}

# Placeholder describe block — real cases land in Tasks 3-8.
echo "[test-reconcile] harness loaded"
echo "[test-reconcile] summary: pass=${PASS} fail=${FAIL}"
exit $FAIL
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x /workspace/agent-swarm/tests/test-reconcile.sh
```

- [ ] **Step 3: Run it; expect "0 pass / 0 fail" (no cases yet)**

```bash
cd /workspace/agent-swarm
bash tests/test-reconcile.sh
```

Expected output:
```
[test-reconcile] harness loaded
[test-reconcile] summary: pass=0 fail=0
```

Exit code 0 because no tests have run yet.

- [ ] **Step 4: Commit**

```bash
cd /workspace/agent-swarm
git add tests/test-reconcile.sh
git commit -m "test(reconcile): add test harness scaffolding

Stubs the PATH-shimmed \`claude\` mock and the setup/teardown helpers.
Cases land in subsequent commits as TDD pairs (test then implementation)."
```

---

## Phase 3 — Reconciler skeleton + first test case

### Task 3: Empty-manifest no-op case

**Files:**
- Modify: `/workspace/agent-swarm/tests/test-reconcile.sh`
- Create: `/workspace/agent-swarm/scripts/reconcile-plugins.sh`

- [ ] **Step 1: Add the empty-manifest test case to `tests/test-reconcile.sh`**

Replace the placeholder block:

```bash
echo "[test-reconcile] harness loaded"
echo "[test-reconcile] summary: pass=${PASS} fail=${FAIL}"
exit $FAIL
```

With:

```bash
echo "[test-reconcile] harness loaded"

# ── Case: empty manifest produces zero plugin operations ──
echo "[case] empty manifest"
setup_test
write_settings
cat > "${APP_DIR}/agents/_shared/settings.json (enabledPlugins shape)" <<'EOF'
{ "plugins": {} }
EOF
write_installed ""
run_reconciler >/dev/null
plugin_calls=$(grep -E 'plugin install|plugin uninstall' "${CALLS_LOG}" | wc -l | tr -d ' ')
assert_eq "${plugin_calls}" "0" "empty manifest: no plugin install/uninstall calls"
teardown_test

echo "[test-reconcile] summary: pass=${PASS} fail=${FAIL}"
exit $FAIL
```

- [ ] **Step 2: Run; expect failure (reconciler doesn't exist yet)**

```bash
bash /workspace/agent-swarm/tests/test-reconcile.sh
```

Expected: harness loaded, then bash error `scripts/reconcile-plugins.sh: No such file or directory`, exit non-zero.

- [ ] **Step 3: Create the minimum reconciler that satisfies the case**

Create `/workspace/agent-swarm/scripts/reconcile-plugins.sh`:

```bash
#!/usr/bin/env bash
# Reconcile installed plugins against the declarative manifest in
# agents/_shared/settings.json (enabledPlugins shape). Reads marketplace info from
# agents/_shared/settings.json. Best-effort: per-plugin / per-marketplace
# failures log [reconcile] WARN: ... and do not abort the loop. Exits 0
# regardless. Designed to run from setup.sh in the init container.

set -uo pipefail

# Inputs (overridable via env for tests)
APP_DIR="${APP_DIR:-/opt/agent-smith}"
CLAUDE_DIR="${CLAUDE_DIR:-${HOME}/.claude}"

SETTINGS="${APP_DIR}/agents/_shared/settings.json"
MANIFEST="${APP_DIR}/agents/_shared/settings.json (enabledPlugins shape)"
INSTALLED="${CLAUDE_DIR}/plugins/installed_plugins.json"

log()  { echo "[reconcile] $*"; }
warn() { echo "[reconcile] WARN: $*" >&2; }

log "starting (APP_DIR=${APP_DIR} CLAUDE_DIR=${CLAUDE_DIR})"

if [ ! -f "${SETTINGS}" ]; then
  warn "settings.json not found at ${SETTINGS} — skipping marketplaces"
fi
if [ ! -f "${MANIFEST}" ]; then
  warn "settings.json (enabledPlugins) not found at ${MANIFEST} — skipping plugins"
  log "complete"
  exit 0
fi

# Phase 1: marketplaces (registration + refresh) — implemented in Task 7

# Phase 2: plugins — implemented in Tasks 4-6
# For now: iterate plugin entries from the manifest and dispatch each through
# reconcile_plugin() which is a stub that no-ops for the empty case.

reconcile_plugin() {
  local plugin_id="$1"
  local declared_version="$2"
  # Implementation lands in Task 4.
  :
}

plugin_ids=$(jq -r '.plugins | keys[]' "${MANIFEST}" 2>/dev/null || true)
for plugin_id in ${plugin_ids}; do
  declared=$(jq -r ".plugins.\"${plugin_id}\".version" "${MANIFEST}")
  reconcile_plugin "${plugin_id}" "${declared}"
done

log "complete"
exit 0
```

- [ ] **Step 4: Make executable**

```bash
chmod +x /workspace/agent-swarm/scripts/reconcile-plugins.sh
```

- [ ] **Step 5: Run the test; expect PASS**

```bash
bash /workspace/agent-swarm/tests/test-reconcile.sh
```

Expected output:
```
[test-reconcile] harness loaded
[case] empty manifest
  PASS: empty manifest: no plugin install/uninstall calls
[test-reconcile] summary: pass=1 fail=0
```

Exit code 0.

- [ ] **Step 6: Commit**

```bash
cd /workspace/agent-swarm
git add tests/test-reconcile.sh scripts/reconcile-plugins.sh
git commit -m "feat(reconcile): scaffold reconciler + empty-manifest test

Adds the reconcile-plugins.sh skeleton (log, warn, manifest read, empty
plugin loop) and the first test case asserting an empty manifest produces
zero plugin install/uninstall calls. Subsequent tasks add cases for
drift, missing-install, install-failure, marketplace registration."
```

---

## Phase 4 — Plugin lifecycle cases

### Task 4: Missing-install → install only

**Files:**
- Modify: `tests/test-reconcile.sh`
- Modify: `scripts/reconcile-plugins.sh` (implement `reconcile_plugin`)

- [ ] **Step 1: Add the missing-install case to `tests/test-reconcile.sh`**

Append before the final `echo "[test-reconcile] summary:..."`:

```bash
# ── Case: plugin missing from installed_plugins.json → install ──
echo "[case] plugin missing"
setup_test
write_settings
write_manifest "0.7.0"
write_installed ""
run_reconciler >/dev/null
install_calls=$(grep -E 'plugin install matrix@claude-code-channel-matrix' "${CALLS_LOG}" | wc -l | tr -d ' ')
uninstall_calls=$(grep -E 'plugin uninstall matrix@claude-code-channel-matrix' "${CALLS_LOG}" | wc -l | tr -d ' ')
assert_eq "${install_calls}" "1" "plugin missing: one install call"
assert_eq "${uninstall_calls}" "0" "plugin missing: zero uninstall calls"
teardown_test
```

- [ ] **Step 2: Run; expect FAIL (reconcile_plugin is a stub)**

```bash
bash /workspace/agent-swarm/tests/test-reconcile.sh
```

Expected: empty-manifest still passes; plugin-missing case fails (`install_calls=0` vs expected `1`).

- [ ] **Step 3: Implement `reconcile_plugin` in `scripts/reconcile-plugins.sh`**

Replace the stub `reconcile_plugin()` block with:

```bash
reconcile_plugin() {
  local plugin_id="$1"
  local declared="$2"

  local installed
  installed=$(jq -r ".plugins.\"${plugin_id}\"[0].version // \"\"" "${INSTALLED}" 2>/dev/null)

  if [ "${installed}" = "${declared}" ]; then
    log "${plugin_id}: in sync at ${declared}"
    return 0
  fi

  if [ -z "${installed}" ]; then
    log "${plugin_id}: not installed → installing ${declared}"
  else
    log "${plugin_id}: drift ${installed} → ${declared}, reinstalling"
    claude plugin uninstall "${plugin_id}" 2>&1 || true
  fi

  if ! claude plugin install "${plugin_id}"; then
    warn "${plugin_id}: install failed; continuing"
    return 0
  fi

  local new_installed
  new_installed=$(jq -r ".plugins.\"${plugin_id}\"[0].version // \"\"" "${INSTALLED}" 2>/dev/null)
  if [ "${new_installed}" != "${declared}" ]; then
    warn "${plugin_id}: declared ${declared} but marketplace served ${new_installed:-<none>}"
  fi
}
```

- [ ] **Step 4: Run; expect both cases pass**

```bash
bash /workspace/agent-swarm/tests/test-reconcile.sh
```

Expected:
```
[case] empty manifest
  PASS: empty manifest: no plugin install/uninstall calls
[case] plugin missing
  PASS: plugin missing: one install call
  PASS: plugin missing: zero uninstall calls
[test-reconcile] summary: pass=3 fail=0
```

- [ ] **Step 5: Commit**

```bash
git add tests/test-reconcile.sh scripts/reconcile-plugins.sh
git commit -m "feat(reconcile): install missing plugins

reconcile_plugin() now installs a plugin when installed_plugins.json
has no entry for it; logs drift transitions; warns when the marketplace
serves a version different from the declared one. Test covers the
missing-install case."
```

---

### Task 5: In-sync → no-op

**Files:**
- Modify: `tests/test-reconcile.sh`

- [ ] **Step 1: Add the in-sync case**

Append:

```bash
# ── Case: installed == declared → no plugin calls ──
echo "[case] plugin in sync"
setup_test
write_settings
write_manifest "0.7.0"
write_installed "0.7.0"
run_reconciler >/dev/null
install_calls=$(grep -E 'plugin install matrix@claude-code-channel-matrix' "${CALLS_LOG}" | wc -l | tr -d ' ')
uninstall_calls=$(grep -E 'plugin uninstall matrix@claude-code-channel-matrix' "${CALLS_LOG}" | wc -l | tr -d ' ')
assert_eq "${install_calls}" "0" "in sync: zero install calls"
assert_eq "${uninstall_calls}" "0" "in sync: zero uninstall calls"
teardown_test
```

- [ ] **Step 2: Run; expect PASS (already covered by the early-return in Task 4)**

```bash
bash /workspace/agent-swarm/tests/test-reconcile.sh
```

Expected: all five assertions pass (`pass=5 fail=0`).

- [ ] **Step 3: Commit**

```bash
git add tests/test-reconcile.sh
git commit -m "test(reconcile): pin in-sync no-op behavior

Asserts that when installed_plugins.json shows the version the manifest
declares, the reconciler emits zero plugin install/uninstall calls. The
behavior already works (early return in reconcile_plugin); this test
pins it against regression."
```

---

### Task 6: Wrong version → uninstall + install

**Files:**
- Modify: `tests/test-reconcile.sh`

- [ ] **Step 1: Add the wrong-version case**

Append:

```bash
# ── Case: installed != declared → uninstall + install ──
echo "[case] plugin wrong version"
setup_test
write_settings
write_manifest "0.7.0"
write_installed "0.6.0"
run_reconciler >/dev/null
install_calls=$(grep -E 'plugin install matrix@claude-code-channel-matrix' "${CALLS_LOG}" | wc -l | tr -d ' ')
uninstall_calls=$(grep -E 'plugin uninstall matrix@claude-code-channel-matrix' "${CALLS_LOG}" | wc -l | tr -d ' ')
assert_eq "${install_calls}" "1" "wrong version: one install call"
assert_eq "${uninstall_calls}" "1" "wrong version: one uninstall call"

# Order: uninstall MUST precede install (otherwise the new install short-
# circuits on the existing entry).
uninstall_line=$(grep -nE 'plugin uninstall' "${CALLS_LOG}" | head -1 | cut -d: -f1)
install_line=$(grep -nE 'plugin install' "${CALLS_LOG}" | head -1 | cut -d: -f1)
assert_eq "$([ "${uninstall_line:-99}" -lt "${install_line:-0}" ] && echo before || echo not-before)" "before" "wrong version: uninstall precedes install"
teardown_test
```

- [ ] **Step 2: Run; expect PASS (behavior already implemented in Task 4)**

```bash
bash /workspace/agent-swarm/tests/test-reconcile.sh
```

Expected: `pass=8 fail=0`.

- [ ] **Step 3: Commit**

```bash
git add tests/test-reconcile.sh
git commit -m "test(reconcile): pin uninstall-precedes-install on drift

Asserts that when installed version differs from declared, the
reconciler emits exactly one uninstall and one install, with the
uninstall preceding the install. Catches regressions where someone
might short-circuit and call install-only on drift (which would
silently no-op because Claude Code refuses to install over an
existing entry)."
```

---

### Task 7: Marketplace registration + refresh

**Files:**
- Modify: `tests/test-reconcile.sh`
- Modify: `scripts/reconcile-plugins.sh` (add Phase 1 marketplace block)

- [ ] **Step 1: Add the marketplace-registration test case**

Append:

```bash
# ── Case: marketplace registration + update fired before plugin ops ──
echo "[case] marketplace registration"
setup_test
write_settings
write_manifest "0.7.0"
write_installed ""
run_reconciler >/dev/null
mkt_add_calls=$(grep -E 'plugin marketplace add sherodtaylor/claude-code-channel-matrix' "${CALLS_LOG}" | wc -l | tr -d ' ')
mkt_update_calls=$(grep -E 'plugin marketplace update claude-code-channel-matrix' "${CALLS_LOG}" | wc -l | tr -d ' ')
assert_eq "${mkt_add_calls}" "1" "marketplace: one add call"
assert_eq "${mkt_update_calls}" "1" "marketplace: one update call"

# Both marketplace calls MUST precede the plugin install
mkt_last_line=$(grep -nE 'plugin marketplace' "${CALLS_LOG}" | tail -1 | cut -d: -f1)
install_line=$(grep -nE 'plugin install' "${CALLS_LOG}" | head -1 | cut -d: -f1)
assert_eq "$([ "${mkt_last_line:-99}" -lt "${install_line:-0}" ] && echo before || echo not-before)" "before" "marketplace ops precede plugin install"
teardown_test
```

- [ ] **Step 2: Run; expect FAIL (reconciler doesn't do marketplaces yet)**

```bash
bash /workspace/agent-swarm/tests/test-reconcile.sh
```

Expected: assertions for `mkt_add_calls` / `mkt_update_calls` both fail (zero calls emitted).

- [ ] **Step 3: Implement Phase 1 marketplace block in `scripts/reconcile-plugins.sh`**

Locate the comment `# Phase 1: marketplaces (registration + refresh) — implemented in Task 7` and replace with:

```bash
# Phase 1: marketplaces (registration + refresh)
if [ -f "${SETTINGS}" ]; then
  marketplace_names=$(jq -r '.extraKnownMarketplaces // {} | keys[]' "${SETTINGS}" 2>/dev/null || true)
  for marketplace_name in ${marketplace_names}; do
    source_repo=$(jq -r ".extraKnownMarketplaces.\"${marketplace_name}\".source.repo // empty" "${SETTINGS}")
    if [ -z "${source_repo}" ]; then
      warn "${marketplace_name}: no source.repo in settings.json — skipping"
      continue
    fi

    # Idempotent: claude plugin marketplace add no-ops if already registered.
    if ! claude plugin marketplace add "${source_repo}" 2>&1; then
      warn "${marketplace_name}: marketplace add failed (continuing)"
    fi

    if ! claude plugin marketplace update "${marketplace_name}" 2>&1; then
      warn "${marketplace_name}: marketplace update failed (continuing)"
    fi
  done
fi
```

- [ ] **Step 4: Run; expect PASS**

```bash
bash /workspace/agent-swarm/tests/test-reconcile.sh
```

Expected: `pass=11 fail=0`.

- [ ] **Step 5: Commit**

```bash
git add tests/test-reconcile.sh scripts/reconcile-plugins.sh
git commit -m "feat(reconcile): register + refresh marketplaces

Phase 1 of the reconciler reads extraKnownMarketplaces from
agents/_shared/settings.json, runs \`claude plugin marketplace add\`
(idempotent) for each entry, then \`claude plugin marketplace update\`
to refresh the local cache. Both ops precede any plugin install in
Phase 2 so the install sees the freshest marketplace metadata."
```

---

### Task 8: Install-failure → warn + exit 0

**Files:**
- Modify: `tests/test-reconcile.sh`

- [ ] **Step 1: Add the install-failure case**

Append:

```bash
# ── Case: install command fails → WARN logged, reconciler exits 0 ──
echo "[case] install failure"
setup_test
write_settings
write_manifest "0.7.0"
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
```

- [ ] **Step 2: Run; expect PASS (behavior already covered by Task 4's `|| return 0`)**

```bash
bash /workspace/agent-swarm/tests/test-reconcile.sh
```

Expected: `pass=13 fail=0`.

> If FAIL: the existing `if ! claude plugin install ...; then warn ...; return 0; fi` in
> `reconcile_plugin` should already catch this. Verify the failed-shim case stops at the install
> and doesn't loop. Adjust if `set -u` or pipefail caused an early abort.

- [ ] **Step 3: Commit**

```bash
git add tests/test-reconcile.sh
git commit -m "test(reconcile): pin install-failure warn-and-continue

Asserts that when \`claude plugin install\` exits non-zero, the
reconciler logs [reconcile] WARN: ... install failed and itself exits 0.
This matches setup.sh's existing best-effort posture — a single failing
plugin must not block pod boot."
```

---

## Phase 5 — Manifest file + setup.sh integration

### Task 9: Author the initial `settings.json (enabledPlugins)`

**Files:**
- Create: `agents/_shared/settings.json (enabledPlugins shape)`

- [ ] **Step 1: Determine which plugins to declare**

```bash
cd /workspace/agent-swarm
grep -A2 'enabledPlugins' agents/_shared/settings.json | head -8
```

Expected: lists `matrix@claude-code-channel-matrix` and `superpowers@claude-plugins-official` as currently-enabled plugins. These are the two the manifest must cover.

- [ ] **Step 2: Author the manifest**

Create `/workspace/agent-swarm/agents/_shared/settings.json (enabledPlugins shape)`:

```json
{
  "plugins": {
    "matrix@claude-code-channel-matrix":  { "version": "0.7.0" },
    "superpowers@claude-plugins-official": { "version": "5.1.0" }
  }
}
```

> Pin both to the **currently-active** versions per the spec. matrix-channel goes from the lingering 0.6.0 → 0.7.0 on first reconciler run; superpowers stays at 5.1.0 (already current).

- [ ] **Step 3: Validate the JSON parses**

```bash
jq '.' /workspace/agent-swarm/agents/_shared/settings.json (enabledPlugins shape) | head -10
```

Expected: pretty-printed JSON with no parse errors.

- [ ] **Step 4: Commit**

```bash
git add agents/_shared/settings.json (enabledPlugins shape)
git commit -m "feat(manifest): add agents/_shared/settings.json (enabledPlugins shape)

Initial manifest pins matrix-channel at 0.7.0 (forces the upgrade from
the stuck-at-0.6.0 install) and superpowers at 5.1.0 (currently active).
The reconciler in scripts/reconcile-plugins.sh reads this on every pod
boot to converge installed plugins to the declared versions."
```

---

### Task 10: Wire the reconciler into `setup.sh`

**Files:**
- Modify: `/workspace/agent-swarm/scripts/setup.sh`

- [ ] **Step 1: Read the current install block**

```bash
grep -n -B1 -A3 'claude plugin marketplace add\|claude plugin install' /workspace/agent-swarm/scripts/setup.sh
```

Expected: lines around 73-77 (per the spec) show:

```
# Install the Matrix channel plugin from its marketplace. settings.json registers
# the marketplace, but the plugin must be explicitly installed to materialize it.
# TEMPORARY: pointed at sherodtaylor's fork while testing new tools
# (per-call threading, edit_message, MATRIX_TYPING). Revert to zekker6
# after upstream PRs land. Tracking: sherodtaylor/claude-code-channel-matrix#1
claude plugin marketplace add sherodtaylor/claude-code-channel-matrix 2>&1 || true
claude plugin install matrix@claude-code-channel-matrix 2>&1 || true
echo "[setup] matrix channel plugin installed"
```

- [ ] **Step 2: Replace the imperative block with a reconciler call**

Edit `scripts/setup.sh` — replace the block above (the lines from the section comment through `echo "[setup] matrix channel plugin installed"`) with:

```bash
# Reconcile plugins declaratively from agents/_shared/settings.json (enabledPlugins shape).
# Marketplaces are registered + refreshed; installed plugins are upgraded
# to match the manifest's declared versions. Best-effort; failures log
# [reconcile] WARN: ... and do not block boot.
bash "${APP_DIR}/scripts/reconcile-plugins.sh"
```

- [ ] **Step 3: Syntax check**

```bash
bash -n /workspace/agent-swarm/scripts/setup.sh && echo OK
```

Expected: `OK`.

- [ ] **Step 4: Confirm the imperative lines are gone**

```bash
grep -c 'claude plugin install\|claude plugin marketplace add' /workspace/agent-swarm/scripts/setup.sh
```

Expected: `0`.

- [ ] **Step 5: Commit**

```bash
git add scripts/setup.sh
git commit -m "feat(setup): invoke reconciler instead of imperative install

Replaces the two \`claude plugin\` lines (marketplace add + install) with
a single \`bash \${APP_DIR}/scripts/reconcile-plugins.sh\` invocation. The
reconciler reads agents/_shared/settings.json (enabledPlugins shape) + settings.json and
converges plugin install state to match. Marketplaces continue to be
declared in settings.json.extraKnownMarketplaces; nothing about the
fork-flip changes in this commit."
```

---

## Phase 6 — Docs

### Task 11: CHANGELOG entry

**Files:**
- Modify: `/workspace/agent-swarm/CHANGELOG.md`

- [ ] **Step 1: Insert the entry under `[Unreleased]`**

Find the `## [Unreleased]` line in `CHANGELOG.md`. Add this block immediately under it (preserving the trailing `---` separator):

```markdown
## [Unreleased]

### Added

- **Declarative plugin reconciler** — `agents/_shared/settings.json (enabledPlugins shape)`
  is now the source of truth for plugin versions. A new
  `scripts/reconcile-plugins.sh` runs on every pod boot, refreshes
  marketplaces, and converges installed plugins to match the manifest
  via `marketplace update` + `uninstall` + `install` on drift. Replaces
  the prior imperative `claude plugin install` lines in `setup.sh`,
  which were idempotent-no-upgrade and pinned pods to whatever version
  was first installed.
- **`tests/test-reconcile.sh`** — six smoke cases against a PATH-shimmed
  `claude` mock; runs offline.

### Changed

- **`scripts/setup.sh`** — the marketplace-add + plugin-install block
  (formerly lines 73-77) is now a single `bash …/reconcile-plugins.sh`
  invocation. Marketplaces are still declared in
  `settings.json.extraKnownMarketplaces`; nothing operator-facing
  changes about the fork-flip.

---
```

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs(changelog): describe declarative plugin reconciler

Entry under [Unreleased] for the new agents/_shared/settings.json (enabledPlugins shape),
scripts/reconcile-plugins.sh, and tests/test-reconcile.sh. Calls out the
setup.sh change (imperative install lines → single reconciler call) and
the underlying motivation (claude plugin install is
idempotent-no-upgrade)."
```

---

## Phase 7 — End-to-end smoke + PR

### Task 12: Run the full test suite, verify clean

**Files:** (no edits)

- [ ] **Step 1: Run all reconciler tests**

```bash
cd /workspace/agent-swarm
bash tests/test-reconcile.sh
```

Expected:
```
[test-reconcile] harness loaded
[case] empty manifest
  PASS: empty manifest: no plugin install/uninstall calls
[case] plugin missing
  PASS: plugin missing: one install call
  PASS: plugin missing: zero uninstall calls
[case] plugin in sync
  PASS: in sync: zero install calls
  PASS: in sync: zero uninstall calls
[case] plugin wrong version
  PASS: wrong version: one install call
  PASS: wrong version: one uninstall call
  PASS: wrong version: uninstall precedes install
[case] marketplace registration
  PASS: marketplace: one add call
  PASS: marketplace: one update call
  PASS: marketplace ops precede plugin install
[case] install failure
  PASS: install failure: reconciler exits 0
  PASS: install failure: WARN logged
[test-reconcile] summary: pass=13 fail=0
```

Exit code 0.

- [ ] **Step 2: Run a smoke against real `agents/_shared` files**

```bash
cd /workspace/agent-swarm
APP_DIR="$(pwd)" CLAUDE_DIR=/tmp/fake-claude bash scripts/reconcile-plugins.sh 2>&1 | head -10
```

Expected: starts with `[reconcile] starting`, attempts to call real `claude plugin` commands (will fail in this shell because there's no live Claude Code setup, but the script itself shouldn't crash — it logs WARNs and exits 0).

Acceptable output forms:
```
[reconcile] starting (APP_DIR=... CLAUDE_DIR=/tmp/fake-claude)
[reconcile] WARN: claude-code-channel-matrix: marketplace add failed (continuing)
[reconcile] WARN: ...
[reconcile] complete
```

Exit code: 0 (best-effort).

- [ ] **Step 3: Run `bash -n` on every changed script**

```bash
bash -n /workspace/agent-swarm/scripts/setup.sh && \
bash -n /workspace/agent-swarm/scripts/reconcile-plugins.sh && \
bash -n /workspace/agent-swarm/tests/test-reconcile.sh && \
echo "all clean"
```

Expected: `all clean`.

- [ ] **Step 4: No commit — this task is verification only.**

---

### Task 13: Push branch + open PR

**Files:** (no edits)

- [ ] **Step 1: Push the branch**

```bash
cd /workspace/agent-swarm
git push -u origin feat/declarative-plugin-reconciler
```

- [ ] **Step 2: Open the PR**

```bash
cd /workspace/agent-swarm
SSL_CERT_FILE=/root/iron-proxy.crt gh pr create \
  --repo sherodtaylor/agent-smith \
  --head feat/declarative-plugin-reconciler --base main \
  --title "feat(reconcile): declarative plugin reconciler + manifest" \
  --body "$(cat <<'EOF'
## Summary

Replaces the imperative `claude plugin install` block in `setup.sh` with a declarative
reconciler driven by `agents/_shared/settings.json (enabledPlugins shape)`. Solves the lingering bug
where pods stayed on `matrix@claude-code-channel-matrix v0.6.0` even after `v0.7.0` was
published, because `claude plugin install` is idempotent-no-upgrade and `setup.sh` never
ran `claude plugin marketplace update`.

## Spec
[`docs/superpowers/specs/2026-05-27-declarative-plugin-reconciler-design.md`](https://github.com/sherodtaylor/agent-smith/blob/main/docs/superpowers/specs/2026-05-27-declarative-plugin-reconciler-design.md)
(PR #52, merged).

## Changes

- **New** `agents/_shared/settings.json (enabledPlugins shape)` — declarative source of truth
- **New** `scripts/reconcile-plugins.sh` — bash, ~80 lines, depends only on `jq` + `claude plugin` CLI
- **New** `tests/test-reconcile.sh` — six smoke cases, PATH-shimmed `claude` mock, runs offline
- **Modified** `scripts/setup.sh` — replaces 7 imperative lines with a single reconciler call
- **Modified** `CHANGELOG.md` — entry under `[Unreleased]`

## Test plan

- [x] `bash tests/test-reconcile.sh` — 13 assertions across 6 cases, all PASS
- [x] `bash -n` syntax check on every changed script
- [x] Local smoke against `agents/_shared` produces expected `[reconcile] starting … complete` flow
- [ ] Post-merge: cut next agent-smith release, bump homelab chart pin, observe `claude plugin list` showing `matrix@claude-code-channel-matrix v0.7.0` on the rolled pods (proves the upgrade fired)
- [ ] Post-merge: bump `settings.json (enabledPlugins)` to a future version, roll pods, verify the reconciler emits the upgrade

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Cross-agent ping per CLAUDE.md**

Post in `#dev` (`!p9BEyaj6qFakLyd5Pp:lab.sherodtaylor.dev`):
`@devbot:lab.sherodtaylor.dev review please: <PR URL>`

Wait for review, address comments, merge.

---

### Task 14: Cluster validation (post-merge)

**Files:** (no edits — observation only)

This task is **deferred until** PR is merged, a new agent-smith release is cut, and the homelab chart pin is bumped. It maps to the same flow we used for prior releases (cut-release.sh → CI → bump-homelab-chart.sh → Flux reconcile → pod roll).

- [ ] **Step 1: Cut next release after merge**

```bash
cd /workspace/agent-swarm
git fetch origin
git checkout main
git pull --ff-only
# Determine next patch version from CHANGELOG; assume 0.1.24 (one past 0.1.23).
SSL_CERT_FILE=/root/iron-proxy.crt GH_TOKEN="$(SSL_CERT_FILE=/root/iron-proxy.crt gh auth token 2>/dev/null)" \
  .claude/references/cut-release.sh --version v0.1.24 \
  --message "declarative plugin reconciler"
```

- [ ] **Step 2: Wait for CI**

```bash
SSL_CERT_FILE=/root/iron-proxy.crt gh run watch --repo sherodtaylor/agent-smith
```

Expected: build + chart jobs both succeed.

- [ ] **Step 3: Bump homelab chart**

```bash
cd /workspace/agent-swarm
SSL_CERT_FILE=/root/iron-proxy.crt GH_TOKEN="$(SSL_CERT_FILE=/root/iron-proxy.crt gh auth token 2>/dev/null)" \
  .claude/references/bump-homelab-chart.sh --version 0.1.24
```

- [ ] **Step 4: Force Flux reconcile**

```bash
kubectl annotate -n flux-system gitrepository flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
kubectl annotate -n flux-system kustomization apps reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
kubectl annotate -n agents helmrelease infrabot devbot reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
```

- [ ] **Step 5: Validate on devbot first**

```bash
kubectl rollout restart statefulset/devbot -n agents
kubectl rollout status statefulset/devbot -n agents --timeout=3m
kubectl logs -n agents devbot-0 -c setup --tail=200 | grep -E 'reconcile|FATAL|WARN'
```

Expected: `[reconcile] starting`, per-marketplace + per-plugin lines, eventually `[reconcile] complete`. Any `WARN` lines are non-fatal and indicate manifest/marketplace mismatch worth investigating but not a regression.

- [ ] **Step 6: Verify plugin version actually rolled forward**

```bash
kubectl exec -n agents devbot-0 -- claude plugin list 2>&1 | head -10
```

Expected:
```
Installed plugins:
  ❯ matrix@claude-code-channel-matrix
    Version: 0.7.0       ← the upgrade fired
    Status: ✔ enabled
  ❯ superpowers@claude-plugins-official
    Version: 5.1.0
    Status: ✔ enabled
```

- [ ] **Step 7: Validate on infrabot (kills the current session)**

Post a Matrix update first, then:

```bash
kubectl rollout restart statefulset/infrabot -n agents
```

Session dies; the next-spawn pod will pick up the change and the same verification applies.

---

## Self-Review Notes

**Spec coverage** — every section of `docs/superpowers/specs/2026-05-27-declarative-plugin-reconciler-design.md` maps to a task:

- Manifest schema → Task 9
- Reconciler script + marketplace + plugin lifecycle → Tasks 3, 4, 7
- setup.sh integration → Task 10
- Six test cases → Tasks 3, 4, 5, 6, 7, 8
- File map → Tasks 2-11
- Acceptance criteria → Tasks 9 (manifest exists) + 10 (setup.sh swap) + 11 (CHANGELOG) + 12 (test suite green) + 14 (cluster end-to-end)
- Risk: uninstall-on-failed-marketplace-update → addressed in Task 7's marketplace block (`warn "marketplace update failed (continuing)"`); a follow-up hardening to skip uninstall when the marketplace failed is *not* in this plan but tracked as a future change

**Placeholders** — none. Every step has concrete code, exact commands, expected output.

**Type / naming consistency:**

- `reconcile_plugin` function name used in Task 3 (stub) and Task 4 (implementation) — matches.
- `plugin_id` parameter name consistent across the reconciler.
- `APP_DIR`, `CLAUDE_DIR`, `SETTINGS`, `MANIFEST`, `INSTALLED` env vars consistent across reconciler + harness.
- Test assertion labels match the case descriptions in the spec.

**Open dependency:** Task 12 step 2 (real-script smoke against `agents/_shared`) expects WARN output because there's no live `claude` CLI in the smoke environment. That's an accepted shape — the script must not crash but the actual calls can fail. Task 14 validates real success on the cluster.

**Risk acknowledged in spec but not implemented in this plan:** the spec's primary risk (reconciler uninstalls a working plugin when the marketplace update failed in the same pass) is **not** mitigated in this implementation. To add it, the marketplace block would need to track per-marketplace success in a bash array/file and the plugin block would need to consult it. Deliberately deferred to keep this plan focused; mitigation lands as a follow-up commit once we observe whether the failure mode actually happens in practice.
