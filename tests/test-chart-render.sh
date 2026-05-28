#!/usr/bin/env bash
# Smoke tests for charts/agent-smith. Each case invokes `helm template`
# with a values fragment and asserts the rendered YAML contains
# (or does not contain) specific strings. No real cluster needed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART_DIR="${REPO_ROOT}/charts/agent-smith"

PASS=0
FAIL=0

assert_eq() {
  local actual="$1"; local expected="$2"; local label="$3"
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS + 1)); echo "  PASS: $label"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $label"
    echo "    expected: $expected"
    echo "    actual:   $actual"
  fi
}

assert_contains() {
  local haystack="$1"; local needle="$2"; local label="$3"
  if echo "$haystack" | grep -qE "$needle"; then
    PASS=$((PASS + 1)); echo "  PASS: $label"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $label"
    echo "    pattern: $needle"
    echo "    (not found in rendered output)"
  fi
}

assert_not_contains() {
  local haystack="$1"; local needle="$2"; local label="$3"
  if echo "$haystack" | grep -qE "$needle"; then
    FAIL=$((FAIL + 1)); echo "  FAIL: $label"
    echo "    pattern: $needle (should NOT be present)"
  else
    PASS=$((PASS + 1)); echo "  PASS: $label"
  fi
}

render() {
  local values_file="$1"
  helm template testrls "${CHART_DIR}" -f "${values_file}" 2>&1
}

render_fails() {
  local values_file="$1"
  if helm template testrls "${CHART_DIR}" -f "${values_file}" >/dev/null 2>&1; then
    echo ""
  else
    helm template testrls "${CHART_DIR}" -f "${values_file}" 2>&1
  fi
}

echo "[test-chart-render] harness loaded"

# ── Case: new-shape values render with a single agent in the array ──
echo "[case] new-shape single agent renders"
cat > /tmp/values-new-single.yaml <<'EOF'
image:
  repository: ghcr.io/sherodtaylor/agent-smith
  tag: v0.2.0
  pullPolicy: IfNotPresent
agents:
  - name: testbot
    existingSecret: testbot-secrets
    matrix:
      botUserId: "@testbot:example.com"
      allowedUsers: "@admin:example.com"
    agentRepos: ["sherodtaylor/homelab"]
    primaryRepo: homelab
EOF
out=$(render /tmp/values-new-single.yaml)
assert_contains "$out" 'name: testbot' "single-agent: StatefulSet/SA name interpolated"

# ── Case: two agents in array → two StatefulSets ──
echo "[case] two-agent fan-out"
cat > /tmp/values-two-agents.yaml <<'EOF'
image:
  repository: ghcr.io/sherodtaylor/agent-smith
  tag: v0.2.0
agents:
  - name: alpha
    existingSecret: alpha-secrets
    matrix: { botUserId: "@alpha:example.com" }
    agentRepos: [example/repo-a]
    primaryRepo: repo-a
  - name: beta
    existingSecret: beta-secrets
    matrix: { botUserId: "@beta:example.com" }
    agentRepos: [example/repo-b]
    primaryRepo: repo-b
EOF
out=$(render /tmp/values-two-agents.yaml)
sts_count=$(echo "$out" | grep -cE '^kind: StatefulSet' || true)
assert_eq "$sts_count" "2" "two-agent: exactly 2 StatefulSets emitted"
assert_contains "$out" 'name: alpha' "two-agent: alpha StatefulSet present"
assert_contains "$out" 'name: beta'  "two-agent: beta StatefulSet present"

# ── Case: two-agent RBAC fan-out (1 CR, N CRBs, N SAs) ──
echo "[case] two-agent RBAC"
out=$(render /tmp/values-two-agents.yaml)
sa_count=$(echo "$out" | grep -cE '^kind: ServiceAccount' || true)
cr_count=$(echo "$out" | grep -cE '^kind: ClusterRole$' || true)
crb_count=$(echo "$out" | grep -cE '^kind: ClusterRoleBinding' || true)
assert_eq "$sa_count" "2" "RBAC: 2 ServiceAccounts"
assert_eq "$cr_count" "1" "RBAC: 1 shared ClusterRole"
assert_eq "$crb_count" "2" "RBAC: 2 ClusterRoleBindings"

# ── Case: reauth tunnel enabled → per-agent Service + Ingress ──
echo "[case] reauth tunnel fan-out"
out=$(render /tmp/values-two-agents.yaml)
svc_count=$(echo "$out" | grep -cE '^kind: Service$' || true)
ing_count=$(echo "$out" | grep -cE '^kind: Ingress$' || true)
assert_eq "$svc_count" "2" "reauth: 2 Services"
assert_eq "$ing_count" "2" "reauth: 2 Ingresses"
assert_contains "$out" 'alpha-shell' "reauth: alpha hostname"
assert_contains "$out" 'beta-shell'  "reauth: beta hostname"

# ── Case: reauth disabled → no Service/Ingress ──
echo "[case] reauth tunnel disabled"
cat > /tmp/values-reauth-off.yaml <<'EOF'
image: { repository: ghcr.io/sherodtaylor/agent-smith, tag: v0.2.0 }
reauth: { tunnel: { enabled: false } }
agents:
  - name: alpha
    existingSecret: alpha-secrets
    matrix: { botUserId: "@alpha:example.com" }
    agentRepos: [example/repo]
    primaryRepo: repo
EOF
out=$(render /tmp/values-reauth-off.yaml)
svc_count=$(echo "$out" | grep -cE '^kind: Service$' || true)
ing_count=$(echo "$out" | grep -cE '^kind: Ingress$' || true)
assert_eq "$svc_count" "0" "reauth off: no Services"
assert_eq "$ing_count" "0" "reauth off: no Ingresses"

# ── Case: shared ConfigMap is rendered as a single instance ──
echo "[case] shared ConfigMap"
out=$(render /tmp/values-two-agents.yaml)
shared_cm_count=$(echo "$out" | grep -cE '# Source: agent-smith/templates/configmap-shared.yaml' || true)
assert_eq "$shared_cm_count" "1" "shared CM: exactly 1 instance (not per agent)"
assert_contains "$out" 'kind: ConfigMap' "shared CM: kind ConfigMap present"

# ── Case: per-agent persona ConfigMap rendered (no configMapRef) ──
echo "[case] persona ConfigMap chart-rendered"
out=$(render /tmp/values-two-agents.yaml)
# Count rendered persona templates via Helm's Source comment, not resource
# name (the name also appears in StatefulSet volume refs and the
# checksum annotation Task 8 will add). Helm emits one # Source: per
# document boundary, so 2 agents → 2 Source lines from this template.
persona_renders=$(echo "$out" | grep -cE '^# Source: agent-smith/templates/configmap-persona.yaml' || true)
assert_eq "$persona_renders" "2" "persona CM: configmap-persona.yaml renders for each agent (range emits both agents inside)"
# Both agent persona CMs should be in the output by metadata.name
assert_contains "$out" 'name: agent-smith-persona-alpha' "persona CM: alpha rendered"
assert_contains "$out" 'name: agent-smith-persona-beta'  "persona CM: beta rendered"

# ── Case: configMapRef provided → no chart-rendered persona CM for that agent ──
echo "[case] configMapRef override skips chart-rendered CM"
cat > /tmp/values-configmapref.yaml <<'EOF'
image: { repository: ghcr.io/sherodtaylor/agent-smith, tag: v0.2.0 }
agents:
  - name: alpha
    existingSecret: alpha-secrets
    configMapRef: alpha-persona-v3
    matrix: { botUserId: "@alpha:example.com" }
    agentRepos: [example/repo]
    primaryRepo: repo
EOF
out=$(render /tmp/values-configmapref.yaml)
# The configmap-persona.yaml template still renders (Helm emits a # Source line)
# but the range body is entirely skipped because configMapRef is set →
# zero ConfigMaps named agent-smith-persona-alpha.
chart_persona_alpha=$(echo "$out" | grep -cE 'name: agent-smith-persona-alpha$' || true)
assert_eq "$chart_persona_alpha" "0" "configMapRef: chart-rendered persona CM skipped"
assert_contains "$out" 'name: alpha-persona-v3' "configMapRef: mount references operator-supplied name"

# ── Case: persona/shared checksum annotations on the pod template ──
echo "[case] checksum annotations"
out=$(render /tmp/values-two-agents.yaml)
assert_contains "$out" 'checksum/persona-alpha:' "checksum: alpha persona annotation"
assert_contains "$out" 'checksum/persona-beta:'  "checksum: beta persona annotation"
assert_contains "$out" 'checksum/shared:'         "checksum: shared annotation"

# ── Case: legacy agentName shape still renders (deprecation shim) ──
echo "[case] legacy agentName shape"
cat > /tmp/values-legacy.yaml <<'EOF'
image: { repository: ghcr.io/sherodtaylor/agent-smith, tag: v0.2.0 }
agentName: legacybot
existingSecret: legacybot-secrets
matrix: { botUserId: "@legacybot:example.com" }
agentRepos: [example/repo]
primaryRepo: repo
EOF
out=$(render /tmp/values-legacy.yaml)
sts_count=$(echo "$out" | grep -cE '^kind: StatefulSet' || true)
assert_eq "$sts_count" "1" "legacy: one StatefulSet from synthetic array"
assert_contains "$out" 'name: legacybot' "legacy: agentName interpolated into StatefulSet"

# ── Case: both agents AND agentName set → render fails ──
echo "[case] both shapes set → error"
cat > /tmp/values-both.yaml <<'EOF'
image: { repository: ghcr.io/sherodtaylor/agent-smith, tag: v0.2.0 }
agentName: oops
existingSecret: oops-secrets
matrix: { botUserId: "@oops:example.com" }
agentRepos: [example/repo]
primaryRepo: repo
agents:
  - name: also-oops
    existingSecret: also-oops-secrets
    matrix: { botUserId: "@also-oops:example.com" }
    agentRepos: [example/repo]
    primaryRepo: repo
EOF
err=$(render_fails /tmp/values-both.yaml)
assert_contains "$err" 'Both .Values.agentName and .Values.agents are set' "both-shape error: explanatory message"

# ── Case: neither agents nor agentName set → render fails ──
echo "[case] neither shape set → error"
cat > /tmp/values-empty.yaml <<'EOF'
image: { repository: ghcr.io/sherodtaylor/agent-smith, tag: v0.2.0 }
agents: []
EOF
err=$(render_fails /tmp/values-empty.yaml)
assert_contains "$err" 'Set either .Values.agents .* or .Values.agentName' "empty: explanatory error"

# ── Case: per-agent image.tag override + fleet-default fallback ──
echo "[case] per-agent image.tag override"
cat > /tmp/values-tag-override.yaml <<'EOF'
image:
  repository: ghcr.io/sherodtaylor/agent-smith
  tag: v0.2.0
agents:
  - name: alpha
    existingSecret: alpha-secrets
    image: { tag: v0.2.1 }
    matrix: { botUserId: "@alpha:example.com" }
    agentRepos: [example/repo]
    primaryRepo: repo
  - name: beta
    existingSecret: beta-secrets
    matrix: { botUserId: "@beta:example.com" }
    agentRepos: [example/repo]
    primaryRepo: repo
EOF
out=$(render /tmp/values-tag-override.yaml)
# Two containers per StatefulSet (init "setup" + main "agent") so a healthy
# override produces 2 occurrences of the override tag and 2 of the fallback.
v021_count=$(echo "$out" | grep -cE 'agent-smith:v0\.2\.1' || true)
v020_count=$(echo "$out" | grep -cE 'agent-smith:v0\.2\.0' || true)
assert_eq "$v021_count" "2" "image override: 2 occurrences of v0.2.1 (alpha init + main)"
assert_eq "$v020_count" "2" "image override: 2 occurrences of v0.2.0 (beta init + main, fallback to top-level)"

echo "[test-chart-render] summary: pass=${PASS} fail=${FAIL}"
exit $FAIL
