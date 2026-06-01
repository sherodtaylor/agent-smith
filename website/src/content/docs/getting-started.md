---
title: Getting Started
description: Run agent-smith in your own cluster.
---

agent-smith deploys the Claude Code CLI as a long-lived process inside a
Kubernetes pod. One pod per agent. Matrix is the input path; the agent
checks out repos, opens PRs, addresses review comments, and merges — all
on its own.

This page covers the minimum the operator needs to install one agent.

## What ships

- **Container image** — `ghcr.io/sherodtaylor/agent-smith` (multi-stage
  Debian + Claude Code CLI + Bun + the `mcp-nats` Go binary).
- **Helm chart** — `oci://ghcr.io/sherodtaylor/charts/agent-smith`. One
  release = one agent. The chart renders a `StatefulSet`,
  `ServiceAccount`, optional `ClusterRole`, and two PVCs (`/root` for
  `~/.claude/`, `/workspace/` for cloned repos).

Image + chart are versioned and published together. The chart version is
the image version.

## Prerequisites

- A Kubernetes cluster (k3s is fine; the reference deployment is k3s on
  Proxmox LXC).
- A Matrix homeserver and a bot user the operator controls — capture its
  access token.
- A GitHub PAT scoped to the repos the agent will work in.
- An [iron-proxy](https://github.com/sherodtaylor/iron-proxy)
  deployment, or another egress-credential firewall. Without it the pod
  cannot reach Anthropic with its stub credentials.

## Install

```bash
helm install infrabot oci://ghcr.io/sherodtaylor/charts/agent-smith \
  --version 0.1.0 \
  --namespace agents --create-namespace \
  --set agentName=infrabot \
  --set matrix.homeserverUrl=https://matrix.example.com \
  --set matrix.botUserId='@infrabot:example.com' \
  --set nats.url=nats://nats.agent-infra.svc.cluster.local:4222 \
  --set existingSecret=agent-smith-infrabot
```

The chart does **not** manage the underlying `Secret`. Bring one (manual,
ExternalSecrets, sealed-secrets) under the name passed to
`existingSecret`, with these keys:

| Key | Purpose |
|---|---|
| `MATRIX_ACCESS_TOKEN` | Matrix bot login token |
| `GITHUB_TOKEN` | Placeholder proxy token; iron-proxy swaps the real PAT in at egress |
| `IRON_PROXY_CA_CRT` | iron-proxy MITM CA certificate (PEM) |

## Minimum values

`agentName` is the only strictly required value beyond the secret
contract. It must match a directory baked into the image
(`infrabot`, `devbot`, or one the operator added — see
[Agents](/agent-smith/agents)).

The other values worth knowing on a first install:

| Value | Default | Notes |
|---|---|---|
| `image.tag` | `""` | Defaults to `Chart.AppVersion` when empty. Pin to a specific `vX.Y.Z` in production. |
| `agentRepos` | `[sherodtaylor/homelab]` | Space-separated `owner/name` list cloned to `/workspace/<basename>`. |
| `primaryRepo` | `homelab` | The repo whose checkout becomes the agent's working directory. |
| `matrix.allowedUsers` | `""` | Comma-separated allowlist of senders the bot reacts to. Empty defers to `setup.sh` default. |
| `matrix.autoJoinRooms` | `[]` | List of Matrix room IDs/aliases the bot should join at startup. Idempotent; the bot stays in rooms it already joined. Eliminates the manual `/invite` step for fresh bot accounts. |
| `ironProxy.enabled` | `true` | Sets `dnsPolicy: None` + DNS at `ironProxy.clusterIp`. |
| `ironProxy.clusterIp` | `10.43.100.100` | Where the agent's DNS resolves. |
| `persistence.home.size` | `10Gi` | `~/.claude/` PVC. |
| `persistence.workspace.size` | `20Gi` | `/workspace/` PVC (cloned repos). |
| `rbac.create` | `true` | Cluster-scoped role; defaults are read-only. Override for an agent that mutates the cluster. |

The full values reference lives in `charts/agent-smith/README.md` in the
repo.

## What boots inside the pod

```
StatefulSet/<agent>
├── init container: setup.sh
│     • install iron-proxy MITM CA into the system trust store
│     • copy stub credentials → ~/.claude/.credentials.json
│     • concatenate agents/_shared/CLAUDE.md + agents/<name>/CLAUDE.md
│     • write settings.json, mcp.json, subagents/
│     • install the Matrix channel plugin
│     • clone every AGENT_REPOS entry into /workspace/<basename>
│
└── main container: entrypoint.sh
    • startup jitter (0–45 s) — desynchronises multi-agent restarts
    • tmux session "main"
        ├── pane 0 — claude-loop.sh
        │             claude --dangerously-load-development-channels
        │                    plugin:matrix@claude-code-channel-matrix
        │                    --remote-control "${AGENT_NAME}"
        └── pane 1 — plain bash shell at /workspace/${PRIMARY_REPO}
```

`pane 0` owns the Matrix identity and is exposed for remote drive-in
via `--remote-control`. The Claude desktop or web app can connect to
that named session and drive the bot directly. `pane 1` is for ad-hoc
inspection on `tmux attach`.

## First contact

If you set `matrix.autoJoinRooms`, the bot has already joined those rooms
at startup. Otherwise invite the bot manually from each room you want it in:

```
/invite @infrabot:example.com
```

Once joined, tag the bot to wake it:

```
@infrabot ping
```

Two signals confirm the pod is healthy:

1. A 👀 reaction appears within ~2 s — the Matrix channel plugin is
   alive and the sender is in the allowlist.
2. A short on-topic reply within ~30 s — `claude` is up and Anthropic
   egress is working.

If either signal is missing, jump to
[Operations → agent-down](/agent-smith/operations).

## Upgrading

```bash
helm upgrade infrabot oci://ghcr.io/sherodtaylor/charts/agent-smith \
  --version 0.2.0 --reuse-values
```

The chart version tracks the image release. Both bump together in the
release workflow.

## Uninstalling

```bash
helm uninstall infrabot -n agents
```

PVCs from `volumeClaimTemplates` survive uninstall by design. To wipe
`~/.claude/` and the cloned repos:

```bash
kubectl delete pvc -n agents -l app.kubernetes.io/instance=infrabot
```
