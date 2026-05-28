# CLAUDE.md — agent-smith

This file is loaded into every Claude Code session that opens this repo. It is
**not** the agent persona — that lives in `agents/_shared/CLAUDE.md` and
`agents/<name>/CLAUDE.md` and is assembled into `~/.claude/CLAUDE.md` inside the
running pod. This file is for **whoever is editing the codebase** (Sherod, a
contributor, or a Claude Code session driving the repo from a laptop).

---

## What this project is

`agent-smith` packages the **Claude Code CLI** as a long-lived process inside a
Kubernetes pod, with a Matrix room as the human interface. Tag a bot, it
executes the task on a checked-out repo, opens a PR, and reviews its teammate's
PRs in return.

- **Scope** — the container image, agent personas (`agents/`), runtime scripts
  (`scripts/`), and the Helm chart (`charts/agent-smith/`).
- **Out of scope** — the Kubernetes manifests that deploy it (those live in
  [`sherodtaylor/homelab`](https://github.com/sherodtaylor/homelab)), and the
  iron-proxy egress firewall (separate project, referenced as infrastructure).
- **Distribution model** — public OSS. The container is `ghcr.io/sherodtaylor/agent-smith`
  and the chart is `oci://ghcr.io/sherodtaylor/charts/agent-smith`. Both are
  consumable by anyone, not just the original homelab.

## Intended goal — production-ready, not a homelab toy

The repo's homelab origin is incidental. The design constraints are
production constraints:

- **No agent ever holds a real credential.** Stub tokens in the image,
  iron-proxy swaps real values in at egress. A pod compromise leaks nothing
  outside the allowlist.
- **One image, parametric persona.** New agents are a directory under `agents/`
  plus a `StatefulSet`. No image rebuild per agent, no per-agent forks.
- **Single source of truth for behaviour.** Cross-agent rules (PR review,
  mention handling, secret hygiene) live in `agents/_shared/CLAUDE.md`. Persona
  files only add specifics.
- **Auditable everything.** Every meaningful action emits a NATS event
  (`swarm.events.*`). The `#audit` room is the durable record.
- **Reproducible releases.** Semver tag → CI builds image + packages Helm
  chart → both published as OCI artifacts. The chart version *is* the image
  version. Detail: [`docs/runbooks/release.md`](docs/runbooks/release.md).

When changing anything in this repo, treat it as software anyone could deploy
into their own cluster — not a personal script.

## Repository layout (one-screen view)

```
.
├── CLAUDE.md                          # ← you are here (session memory)
├── README.md                          # public-facing project overview
├── CHANGELOG.md                       # release history (Keep a Changelog)
├── Dockerfile                         # multi-stage: mcp-nats + claude CLI + bun
├── .github/workflows/docker.yml       # CI: image + chart on tag, image on main
│
├── agents/
│   ├── _shared/
│   │   ├── CLAUDE.md                  # base rules every agent inherits
│   │   ├── settings.json              # plugins, permissions, hooks
│   │   └── .credentials.json          # stub OAuth payload (literal placeholders)
│   ├── devbot/   CLAUDE.md mcp.json subagents/
│   └── infrabot/ CLAUDE.md mcp.json subagents/
│
├── scripts/
│   ├── setup.sh                       # init container: assemble ~/.claude, clone repos
│   ├── entrypoint.sh                  # main container: tmux + claude (pane 0) + shell (pane 1)
│   ├── claude-loop.sh                 # pane 0 wrapper: restore stub creds, exp backoff
│   └── check-pr-comments.sh           # Stop-hook: rewake on unaddressed PR comments
│
├── charts/agent-smith/                # Helm chart (one release = one agent)
│   ├── Chart.yaml  README.md  values.yaml
│   └── templates/  _helpers.tpl  rbac.yaml  serviceaccount.yaml  statefulset.yaml  NOTES.txt
│
├── .claude/
│   └── references/                    # reusable scripts referenced from runbooks
│       ├── README.md                  # script index
│       ├── gh-token.sh                # (source) resolve GH_TOKEN from env or gh config
│       ├── compare-since-tag.sh       # show commits since last release tag
│       ├── cut-release.sh             # tag + GitHub Release via API
│       ├── bump-homelab-chart.sh      # bump HelmRelease versions in sherodtaylor/homelab
│       ├── check-release.sh           # verify image + chart + release all exist
│       ├── restart-agent.sh           # delete pod + wait for Ready
│       ├── restart-ironproxy.sh       # rollout restart iron-proxy
│       ├── force-eso-sync.sh          # force ExternalSecret re-sync from Infisical
│       └── restore-stub-creds.sh      # restore stub credentials in a running pod
│
└── docs/
    ├── architecture.md                # full design detail (when README isn't enough)
    ├── matrix-communication.md        # how agents send messages to Matrix (room/thread/native reply)
    ├── runbooks/                      # operational playbooks (reference scripts above)
    │   ├── README.md                  # runbook index
    │   ├── release.md
    │   ├── adding-agent.md
    │   ├── oauth-401.md
    │   ├── agent-down.md
    │   ├── ci-failure.md
    │   └── secret-rotation.md
    └── superpowers/                   # implementation plans + specs (history)
```

The Kubernetes manifests that deploy the agents are intentionally **not** in
this repo — they live in
[`sherodtaylor/homelab/k8s/apps/agents/`](https://github.com/sherodtaylor/homelab/tree/main/k8s/apps/agents).
Bumping the chart version there is the last step of every release.

## Progressive disclosure — what to read, when

You almost never need the whole repo at once. Start at the smallest layer and
descend only when the layer above doesn't answer the question.

| If you're about to... | Read first | Then if needed |
|---|---|---|
| **Understand the project** | [`README.md`](README.md) | [`docs/architecture.md`](docs/architecture.md) |
| **Cut a release** | [`docs/runbooks/release.md`](docs/runbooks/release.md) | [`.claude/references/`](.claude/references/README.md), [`CHANGELOG.md`](CHANGELOG.md) |
| **Add a new agent persona** | [`docs/runbooks/adding-agent.md`](docs/runbooks/adding-agent.md) | `charts/agent-smith/agents/example-devbot/CLAUDE.md` as a template (production personas live in operator-supplied ConfigMaps, referenced via `configMapRef`) |
| **Debug a 401 from Anthropic** | [`docs/runbooks/oauth-401.md`](docs/runbooks/oauth-401.md) | `scripts/claude-loop.sh`, iron-proxy logs |
| **Diagnose an unresponsive agent** | [`docs/runbooks/agent-down.md`](docs/runbooks/agent-down.md) | pod logs, tmux attach, `claude-loop.sh` |
| **Investigate a CI failure** | [`docs/runbooks/ci-failure.md`](docs/runbooks/ci-failure.md) | `.github/workflows/docker.yml` |
| **Rotate a credential** | [`docs/runbooks/secret-rotation.md`](docs/runbooks/secret-rotation.md) | Infisical + ESO refresh policy |
| **Change agent behaviour** | `agents/_shared/CLAUDE.md` | per-agent `agents/<name>/CLAUDE.md` |
| **Understand how agents talk to Matrix** | `agents/_shared/CLAUDE.md` ("How Matrix replies work") | [`docs/matrix-communication.md`](docs/matrix-communication.md) |
| **Change cluster deploy shape** | `charts/agent-smith/values.yaml` | `templates/statefulset.yaml` |

If a runbook is missing or wrong, fix it in the same PR as the code change.
Drift between code and runbook is the failure mode they exist to prevent.

## Working in this repo — communication norms

This file applies to *you, the Claude Code session*, not the running bot. When
editing this repo:

1. **Read before writing.** Open the file. Open the surrounding files. Match
   the existing style — bash uses `set -euo pipefail`, YAML is 2-space, Go
   matches what's already there. Don't write a function whose conventions
   clash with the file it lives in.
2. **One concern per PR.** A release bump is one PR. A new runbook is one PR.
   Don't ride along a refactor on top of a bug fix. This applies to docs too —
   README and runbook edits go through a PR, not direct pushes to `main`.
3. **Verify before claiming done.** `helm lint charts/agent-smith`,
   `bash -n scripts/*.sh`, `docker build .` if you can. State the verification
   command in the PR body.
4. **Document the *why*, not the *what*.** A comment that just restates the
   code is noise. A comment that names the constraint (`# git HTTPS uses Basic
   Auth which iron-proxy can't swap → use GIT_GITHUB_TOKEN`) earns its place.
5. **No placeholders, no TODOs, no commented-out code** in merged PRs.
6. **Update CHANGELOG.md** in the same PR for any user-visible change. The
   release runbook expects to copy from `[Unreleased]` into the new version
   section.
7. **Update the affected runbook** if the change alters operational behaviour.
   A new env var → update `release.md` and/or `adding-agent.md`. A new failure
   mode → add it to `agent-down.md` or `oauth-401.md`.

## Communication with Sherod (and any human reader)

The narration model here is the same one the bots use in Matrix — it works for
humans too:

- **Start with a one-line plan** before any tool call. What you understood,
  how you'll approach it.
- **One sentence per significant transition** — finished a step, hit a
  blocker, changed direction. Silence between actions is a bug, not a feature.
- **End with the result + verification command.** What changed and how to
  confirm it. One sentence.
- **No filler.** Skip "Great question!", "Happy to help!", "Let me…". Start
  with the action.
- **Tailor to the sender.** Sherod has the full context; skip basic
  explanations and lead with the relevant path/line/command.

## Release model (one-screen view, detail in the runbook)

| Trigger | Image tags | Chart version | Consumer impact |
|---|---|---|---|
| Push to `main` | `:main`, `:sha-<short>` | (none) | Dev/staging — `:main` moves with every merge |
| Git tag `vX.Y.Z` | `:vX.Y.Z`, `:vX.Y`, `:vX`, `:latest` | `X.Y.Z` (OCI + GH Release tarball) | Production — `:latest` only moves on a versioned release |

Cutting a release is **(1)** tag on `main`, **(2)** GitHub Release with body
copied from the CHANGELOG section, **(3)** bump the chart version on the
consuming HelmReleases in `sherodtaylor/homelab`. Full detail:
[`docs/runbooks/release.md`](docs/runbooks/release.md).

## Security model (one-screen view, detail in architecture)

- Agent pods receive real Claude OAuth tokens (`CLAUDE_ACCESS_TOKEN`, `CLAUDE_REFRESH_TOKEN`, `CLAUDE_EXPIRES_AT`) via ESO-backed k8s Secrets. `setup.sh` writes them into `credentials.json` at init so Claude self-refreshes before expiry.
- **iron-proxy** sits in front of all egress, MITMs HTTPS via a private CA,
  and rewrites `Authorization` headers with real credentials scoped per host.
- Domain allowlist is default-deny — only listed hosts get egress.
- Claude token rotation: run `scripts/refresh-claude-creds.sh --local` (or via SSH) on any host with `claude auth login` to push fresh tokens to Infisical. ESO syncs them to pod secrets; pods pick them up on next restart.
- Stop hook (`check-pr-comments.sh`) and persona rules forbid agents from
  echoing secrets into Matrix.

Detail and threat model:
[`docs/architecture.md#security--iron-proxy`](docs/architecture.md#security--iron-proxy).

## Bot persona vs. session memory — don't confuse them

| File | Loaded by | Audience | Purpose |
|---|---|---|---|
| `CLAUDE.md` (this file) | Claude Code editing this repo | Sherod / contributors / a coding session | How to work in the codebase |
| `agents/_shared/CLAUDE.md` | the running bot (assembled into `~/.claude/CLAUDE.md` at pod startup) | the deployed agent | How to behave on Matrix |
| `agents/<name>/CLAUDE.md` | the running bot (concatenated after shared) | the deployed agent | Per-persona rules |

When changing **how the bot acts at runtime**, edit `agents/_shared/CLAUDE.md`
or the persona file. When changing **how this codebase is maintained**, edit
this file.

## When you're stuck

- Public-facing overview → [`README.md`](README.md)
- Architecture detail → [`docs/architecture.md`](docs/architecture.md)
- Matrix communication mechanism → [`docs/matrix-communication.md`](docs/matrix-communication.md)
- Operational playbook → [`docs/runbooks/`](docs/runbooks/)
- Release history → [`CHANGELOG.md`](CHANGELOG.md)
- Bot runtime behaviour → `agents/_shared/CLAUDE.md` + persona files

If the answer isn't in any of those, read the script. The scripts are short
and heavily commented for exactly this case.
