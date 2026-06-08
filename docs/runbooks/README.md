# Runbooks

Operational playbooks for the `agent-smith` project. One file per recurring
situation. Each runbook is **self-contained**: open it, follow it, fix the
problem.

If the playbook turns out to be wrong or stale, fix it in the same PR as the
code change that made it wrong. Drift between code and runbook is the failure
mode this directory exists to prevent.

## Index

| Runbook | When to use |
|---|---|
| [`release.md`](release.md) | Cutting a new versioned release (image + chart + GitHub Release) |
| [`adding-agent.md`](adding-agent.md) | Onboarding a new agent persona (e.g. `securitybot`) |
| [`oauth-401.md`](oauth-401.md) | Agent returns Anthropic `401 Unauthorized` |
| [`agent-down.md`](agent-down.md) | Agent is unresponsive, restarting, or silent in Matrix |
| [`ci-failure.md`](ci-failure.md) | The release workflow failed |
| [`secret-rotation.md`](secret-rotation.md) | Rotating a Matrix / GitHub / iron-proxy credential |
| [`website-deploy.md`](website-deploy.md) | Site triggers, PR-preview URLs, and CDN propagation |

## How to write a runbook

1. **Title + when to use.** The first paragraph must let a reader decide if
   they're in the right document.
2. **Preconditions.** What needs to be true before running anything (cluster
   access, GH token, etc.).
3. **The actual steps.** Numbered. Copy-pasteable commands. State the
   *expected* output of each step — that's how the reader knows it worked.
4. **Verify.** A single command at the end that confirms the fix.
5. **Rollback.** What to do if a step fails halfway. Even a one-liner is
   better than nothing.
6. **Why it works (optional).** One paragraph at the bottom for the curious.

Keep runbooks short. If one balloons past ~150 lines, split it.
