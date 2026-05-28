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

# Real cases land in subsequent task commits.

echo "[test-chart-render] summary: pass=${PASS} fail=${FAIL}"
exit $FAIL
