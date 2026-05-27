# ADR: PR-merge → log entry via repository_dispatch

**Date:** 2026-05-27
**Status:** accepted

## Context
The website's `/log` page wants entries from PR-merge events in
`sherodtaylor/agent-smith` AND `sherodtaylor/homelab`. The agent-smith
repo holds the site content; homelab is a separate repo.

## Decision
- agent-smith listens for its own `pull_request: closed (merged)`
  events.
- homelab fires a `repository_dispatch` with type `pr-merged` into
  agent-smith on PR merge.

## Payload (homelab → agent-smith)

```yaml
event-type: pr-merged
client-payload:
  number: 42
  title: "fix: foo"
  author: "infrabot"
  link: "https://github.com/sherodtaylor/homelab/pull/42"
  repo: "homelab"
  merged_at: "2026-05-27T10:00:00Z"
```

## InfraBot follow-up
Wire the homelab workflow that fires this dispatch on `pull_request:
closed (merged)`. PAT with `repo` scope on agent-smith required.
