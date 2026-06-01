---
title: Operations
description: Running and maintaining agent-smith.
---

Operational playbooks for the running agent. One section per recurring
situation. Each section is the summary; the full runbook in the repo is
the copy-pasteable procedure.

If the playbook turns out to be wrong or stale, fix it in the same PR
as the code change that made it wrong. Drift between code and runbook
is the failure mode this directory exists to prevent.

## Cut a release

Use when shipping a new version of the image **and** chart.

1. Pick the semver bump (patch / minor / major) by reading merged PRs
   since the last tag.
2. Move `[Unreleased]` in `CHANGELOG.md` into a new `[X.Y.Z]` section.
   The GitHub Release body is copied from this section.
3. **Update the website** (`website/src/`) for any user-visible changes:
   feature flags surfaced to operators, persona / agent roster shifts,
   new chart values, docs that drift. Catch the drift here so the
   public-facing site doesn't slip a release behind the changelog.
4. Tag and create the GitHub Release in one shot via
   `.claude/references/cut-release.sh --version vX.Y.Z`. CI picks up the
   tag and publishes the image + chart automatically.
5. Verify all four artifacts (git tag, GitHub Release, container image,
   Helm chart OCI artifact) via `.claude/references/check-release.sh`.
6. Bump consuming `HelmRelease`s via
   `.claude/references/bump-homelab-chart.sh`. Flux reconciles on the
   next poll.
7. Confirm the new pods come up Ready and the bot acknowledges a tag in
   `#dev` on the new version.

Tags are the **only** trigger for the chart job. Pushes to `main` never
publish a chart and never move `:latest`. The chart version is derived
from the tag name, so chart and image are always at the same version.

Full procedure:
[`docs/runbooks/release.md`](https://github.com/sherodtaylor/agent-smith/blob/main/docs/runbooks/release.md).

## Add a new agent persona

Use when adding a third (or fourth, …) agent — e.g. `securitybot`,
`qabot`. The image is parametric on `AGENT_NAME`, so no image rebuild
is required for the runtime change; only a new `agents/<name>/`
directory and a Matrix identity.

1. Provision the Matrix identity on the homeserver. Store the access
   token in the operator's secret store.
2. Copy an existing persona as a template:
   `cp -r agents/devbot agents/<name>`. Edit `CLAUDE.md`, `mcp.json`,
   and any `subagents/`.
3. Add the new agent to the **Your Team** roster in
   `agents/_shared/CLAUDE.md`. The cross-agent PR review fan-out reads
   this list at runtime.
4. Verify the AgentConfig assembles by dry-running `setup.sh` in a
   throwaway container.
5. Open one PR per agent, merge to `main`, cut a release.
6. Deploy a `HelmRelease` for the new agent and an `ExternalSecret`
   that materialises `<name>-secrets`.
7. Watch the pod come up; tag the bot in `#dev` to confirm.

Full procedure:
[`docs/runbooks/adding-agent.md`](https://github.com/sherodtaylor/agent-smith/blob/main/docs/runbooks/adding-agent.md)
and the dedicated [Agents](/agent-smith/agents) page.

## Plugin updates are pod-bounce-deployed

Claude Code's `enabledPlugins` schema only accepts `true`/`false` — there is
no settings-level version pin for GitHub-source plugins. `reconcile-plugins.sh`
runs at every pod start and unconditionally uninstalls + reinstalls every
enabled plugin, so a pod bounce becomes the deploy mechanism for upstream
plugin fixes:

1. Upstream plugin repo (e.g. `claude-code-channel-matrix`) merges a fix
   and tags a new version.
2. Bounce the agent pod: `kubectl delete pod <agent>-0 -n agents` (the
   StatefulSet recreates it).
3. Init container's `reconcile-plugins.sh` uninstalls the cached plugin
   version and pulls the latest from the marketplace.
4. Pod is now on the new plugin version. Verify via `installed_plugins.json`
   inside the pod.

Safety net: if a marketplace's `add` or `update` call fails in the
marketplace-refresh phase, Phase 2 skips reinstall for any plugin sourced
from that marketplace — so a network blip during bounce doesn't take the
plugin offline entirely. The cached install stays put until the next
healthy reconcile.

Trade-off: every enabled plugin (including stable ones) reinstalls on
every bounce. Per-plugin opt-out can be added later if startup time grows
uncomfortably; for now the cost is "a few seconds of init."

## Anthropic 401 Unauthorized

Use when an agent's tmux pane shows `401 Unauthorized` from
`*.anthropic.com`, or `kubectl logs` reports auth errors after a
successful pod startup.

The pod never holds a real OAuth token —
`~/.claude/.credentials.json` contains literal stub strings
(`access-token-stub`, `refresh-token-stub`). iron-proxy sees those
strings in the `Authorization` header and rewrites them to the real
token at egress. A 401 means iron-proxy's swap **didn't fire**.

Two common causes:

1. **`.credentials.json` no longer contains the stub.** Claude Code's
   OAuth refresh path overwrites the file mid-flight with the upstream
   response, which strips `subscriptionType` and may change the access
   token. With the stub string gone, iron-proxy has nothing to match
   against. Fix: `.claude/references/restart-agent.sh` recreates the
   pod and `setup.sh` re-copies the stub.
2. **iron-proxy is holding a stale upstream token.** The real
   `CLAUDE_CODE_OAUTH_TOKEN` in iron-proxy's environment has expired
   or been rotated, but iron-proxy hasn't re-read it. Fix:
   `.claude/references/restart-ironproxy.sh`.

Restart the agent first (cheaper). Restart iron-proxy only if the agent
stub is intact and 401s persist.

Full procedure:
[`docs/runbooks/oauth-401.md`](https://github.com/sherodtaylor/agent-smith/blob/main/docs/runbooks/oauth-401.md).

## Agent is unresponsive

Use when an agent is silent in Matrix, hasn't reacted to a tag in
`#dev`, or appears to be in a restart loop. Excludes the specific 401
case.

Decision tree by symptom:

| Symptom | Where to look |
|---|---|
| Pod `CrashLoopBackOff` | `kubectl logs --previous` for the last error before the crash |
| Pod Running, no 👀 reaction | Matrix channel plugin: `~/.claude/plugins/cache/`, `~/.claude/channels/matrix/access.json` |
| Pod Running, 👀 but no reply | `kubectl logs` for 401/429/5xx/timeout; jump to the matching runbook |
| Pod `Pending` / `Init:…` | Init container logs (`kubectl logs <pod> -c setup`) |

The pod is a thin shell around a single `claude` process. Three things
can go wrong: `setup.sh` (init), `entrypoint.sh` / `claude-loop.sh`
(main), or the Matrix channel plugin (silent from the pod's POV — the
process is happy, it just isn't getting input). The 👀 reaction is the
single best liveness signal because it proves the channel-receive path
end-to-end.

Full procedure:
[`docs/runbooks/agent-down.md`](https://github.com/sherodtaylor/agent-smith/blob/main/docs/runbooks/agent-down.md).

## CI failure

Use when the `Build and push image` workflow failed on either a `main`
push or a `vX.Y.Z` tag.

Two jobs run:

- **`build`** — fires on every push to `main` and every tag.
- **`chart`** — fires only on `v*.*.*` tags, depends on `build`.

The split is intentional: an image failure short-circuits the whole
release, so a chart that points at a missing image can't be published.
The opposite case (image published, chart job failed) is the harder one
to recover from — re-run the chart job aggressively before rolling
forward. If a real bug killed it, fix it in a follow-up PR and publish
`vX.Y.Z+1`. Do **not** re-tag the same version: Helm OCI artifacts at
a given version are immutable; the second push fails.

Common failure modes are tabulated in the full runbook (mcp-nats Go
build, npm registry hiccup, GHCR token scope, malformed semver tag,
helm lint, helm package, helm push 403).

Full procedure:
[`docs/runbooks/ci-failure.md`](https://github.com/sherodtaylor/agent-smith/blob/main/docs/runbooks/ci-failure.md).

## Rotate a credential

Use when rotating a Matrix access token, GitHub PAT, Claude OAuth token,
or the iron-proxy CA. Each credential has a slightly different blast
radius and restart requirement.

| Credential | Restart |
|---|---|
| `MATRIX_ACCESS_TOKEN`, `MATRIX_HOMESERVER_URL`, `MATRIX_BOT_USER_ID`, `MATRIX_ALLOWED_USERS` | Agent pod |
| `GIT_GITHUB_TOKEN` (real PAT) | Agent pod |
| `IRON_PROXY_CA_CRT` | Agent pod |
| `CLAUDE_CODE_OAUTH_TOKEN` (the real Claude token iron-proxy uses) | **iron-proxy** |
| iron-proxy domain allowlist | **iron-proxy** |
| `GITHUB_TOKEN` (proxy stub) | n/a — it's a literal string, never rotate |

Procedure:

1. Update the value in the operator's secret store (Infisical, sealed-
   secrets, …). Don't echo new values into shell history.
2. Force ExternalSecrets to re-sync; the default refresh interval is
   1 hour.
3. Restart the right pod (see table above). Wait for Ready.
4. Verify with a tag in `#dev` (Matrix), a `git pull` from inside the
   pod (`GIT_GITHUB_TOKEN`), or a clean log of `200`s with no `401`s
   (Claude OAuth).

The iron-proxy CA rotation is the only one that couples agent and
proxy: existing agents trust the old CA but iron-proxy serves the new
one between the cert swap and the agent restart — all egress fails
during that window. Plan a maintenance window.

ESO is the single source-of-truth boundary between the operator's
secret store and the cluster. Pods read env at startup, so a Secret
change requires a pod restart to take effect.

Full procedure:
[`docs/runbooks/secret-rotation.md`](https://github.com/sherodtaylor/agent-smith/blob/main/docs/runbooks/secret-rotation.md).

## Full runbook index

The canonical, copy-pasteable runbooks live in the repo:
[`docs/runbooks/`](https://github.com/sherodtaylor/agent-smith/tree/main/docs/runbooks).
