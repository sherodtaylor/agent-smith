#!/usr/bin/env bash
# Called by the Stop hook (asyncRewake). Checks open PRs authored by this
# agent for new review comments since the last check. Exits 2 (rewake) only
# when the count increases — prevents infinite rewake on already-seen comments.
set -euo pipefail

STATE_FILE="${HOME}/.pr-comment-state.json"
state=$(cat "$STATE_FILE" 2>/dev/null || echo '{}')
new_state="$state"
pending=""

for repo in sherodtaylor/homelab sherodtaylor/agent-smith; do
  while IFS=$'\t' read -r num _title; do
    # Count issue-level comments + unresolved inline review threads
    count=$(gh pr view "$num" --repo "$repo" \
      --json comments,reviewThreads \
      --jq '(.comments | length) + ([.reviewThreads[] | select(.isResolved == false)] | length)' \
      2>/dev/null || echo 0)

    key="${repo}#${num}"
    prev=$(echo "$state" | jq -r --arg k "$key" '.[$k] // 0')

    if [ "$count" -gt "$prev" ]; then
      pending="${pending} ${key}(${count})"
    fi

    new_state=$(echo "$new_state" | jq --arg k "$key" --argjson v "$count" '.[$k] = $v')
  done < <(gh pr list --author "@me" --state open --repo "$repo" \
    --json number,title --jq '.[] | [.number, .title] | @tsv' 2>/dev/null || true)
done

echo "$new_state" > "$STATE_FILE"

if [ -n "$pending" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"PRs with new review comments:%s. Use: gh pr view <n> --comments --repo <repo>"}}\n' "$pending"
  exit 2
fi
