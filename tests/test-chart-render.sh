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

echo "[test-chart-render] summary: pass=${PASS} fail=${FAIL}"
exit $FAIL
