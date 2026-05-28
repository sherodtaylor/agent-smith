# Architecture

This is the long-form companion to the README. Read [`README.md`](../README.md)
first; come here when you need to know *why* something is the way it is, or
*how* a moving part actually works.

---

## Goal in one paragraph

A single Claude Code process per pod, listening on a Matrix room, with full
git+shell+kubectl access on a persistent workspace, configured purely by files
in `agents/<name>/`. Multiple agents = multiple `StatefulSet`s of the same
image with different `AGENT_NAME`. No real credentials ever live in a pod —
the egress credential firewall (iron-proxy) swaps them in at the network
boundary.

## The runtime

```
StatefulSet/<agent>                  (one per agent: infrabot, devbot, …)
├── init container: scripts/setup.sh
│     • install iron-proxy MITM CA into system trust store
│     • copy stub credentials into ~/.claude/.credentials.json
│     • concatenate agents/_shared/CLAUDE.md + agents/<name>/CLAUDE.md
│         → ~/.claude/CLAUDE.md
│     • copy settings.json, mcp.json, subagents/ into ~/.claude/
│     • mark first-run onboarding complete + pre-trust workspace repos
│     • install Matrix channel plugin (`claude plugin install matrix@…`)
│     • write Matrix channel .env + access.json
│     • configure git/gh credentials (split: gh uses proxy token; git uses real)
│     • clone every AGENT_REPOS entry into /workspace/<basename>
│
└── main container: scripts/entrypoint.sh
    • startup jitter (0–45 s) — desynchronises devbot/infrabot restarts
    • tmux session "main"
    │   ├── pane 0 — scripts/claude-loop.sh
    │   │             • restore stub creds before every start
    │   │             • claude --dangerously-load-development-channels
    │   │                      plugin:matrix@claude-code-channel-matrix
    │   │                      --remote-control "${AGENT_NAME}"
    │   │                      --permission-mode bypassPermissions
    │   │             • exponential backoff with jitter on crash
    │   │             • --continue if a prior session dir exists
    │   └── pane 1 — plain bash shell at /workspace/${PRIMARY_REPO}
    • dispatch() — auto-accept theme/Bypass/dev-channels first-run prompts
    • watchdog loop:
        • every 10 s: re-scan pane 0 for any prompts that reappear after a crash
        • every 1–3 h: inject organic keepalive prompt if pane 0 is idle 30 s+
```

The `claude-loop.sh` wrapper exists because Claude Code mutates
`.credentials.json` mid-flight (the OAuth refresh path overwrites the file with
the upstream response, which strips `subscriptionType`). Restoring the stub
before every start makes the iron-proxy swap reliable across restarts. Detail:
[`docs/runbooks/oauth-401.md`](runbooks/oauth-401.md).

## One image, many agents

The image is **parametric on `AGENT_NAME`**. Every agent runs
`ghcr.io/sherodtaylor/agent-smith:vX.Y.Z` with a different env var. `setup.sh`
reads `agents/${AGENT_NAME}/` at startup and assembles `~/.claude/` from these
sources:

| Source file | Assembled to | Purpose |
|---|---|---|
| `agents/_shared/CLAUDE.md` + `agents/<name>/CLAUDE.md` (concatenated) | `~/.claude/CLAUDE.md` | base rules + persona |
| `agents/_shared/settings.json` | `~/.claude/settings.json` | plugins, permissions, hooks |
| `agents/_shared/.credentials.json` | `~/.claude/.credentials.json` | stub OAuth (iron-proxy swaps in real tokens) |
| `agents/<name>/mcp.json` | `~/.claude/.mcp.json` | per-agent MCP servers |
| `agents/<name>/subagents/*.md` | `~/.claude/agents/*.md` | persona-specific subagents |

Adding a new agent is a directory + a `StatefulSet` referencing the same
image. No image rebuild. Detail:
[`docs/runbooks/adding-agent.md`](runbooks/adding-agent.md).

## Matrix as the channel

The agent's input path is the
[`claude-code-channel-matrix`](https://github.com/zekker6/claude-code-channel-matrix)
plugin. `settings.json` registers the marketplace; `setup.sh` materialises the
plugin with `claude plugin install`. Per-agent Matrix credentials and the
sender allowlist are written to `~/.claude/channels/matrix/`.

Every permitted message in a joined room becomes a Claude Code prompt for the
agent — no separate listener, no message queue, no per-room wiring. The 👀
reaction the bot posts on acknowledgement comes from the same plugin.

The plugin runs **inside the same `claude` process** as the rest of the
session. There is no second process to keep alive, no IPC, no bridge.

## Cross-agent collaboration

Two channels do different jobs:

**Matrix** — the wake signal. Bots respond to:
- their own name (plain text, `@name`, full Matrix ID, or Matrix display-name
  link from clients like Element);
- any message from `@sherod:lab.sherodtaylor.dev`;
- a threaded reply to one of their own messages.

NATS does **not** wake an agent — only Matrix does.

**NATS JetStream** — durable structured event log. Bots publish to
`swarm.events.{pr_opened, pr_merged, incident, task_done}` after meaningful
actions. Bots read from NATS only when explicitly asked. The audit room
`#audit` is the human-readable mirror.

**The cross-agent PR review loop:**

```
Author bot opens PR
   ├── publishes swarm.events.pr_opened
   └── posts in #dev mentioning every teammate (full Matrix IDs)
                 │
                 ▼
       Mentioned bot wakes, acknowledges in same thread
                 │
                 ▼
       gh pr diff … → code-review skill (--comment) posts inline findings
                 │
                 ▼
       Reviewer posts one-liner: "Reviewed #N — N findings, N blocking."
                 │
                 ▼
       Author addresses comments. The check-pr-comments.sh Stop hook
       rewakes the author whenever new comments arrive on their PRs.
```

## The PR-comment Stop hook

`scripts/check-pr-comments.sh` is wired into `settings.json` as a Stop hook
with `asyncRewake: true`. After every Claude turn:

1. List the author's open PRs in each known repo.
2. Count issue-level comments + unresolved inline review threads per PR.
3. Compare to a per-PR counter persisted at `~/.pr-comment-state.json`.
4. If any PR's count went up, exit `2` with a structured `hookSpecificOutput`
   that names which PRs.

Exit 2 = rewake. The agent sees the rewake message, reads the new comments,
addresses them, and posts a one-liner. The counter prevents infinite rewake on
already-seen comments.

## Security — iron-proxy

`iron-proxy` is the egress credential firewall. Cluster-internal name
`10.43.100.100`. All HTTPS egress from agent pods is routed through it via
`dnsPolicy: None` + `dnsConfig.nameservers: [<iron-proxy>]`. In-cluster names
(`*.cluster.local`) pass through to CoreDNS, so NATS and Matrix still resolve
normally.

```
   agent pod                            iron-proxy                       internet
   ─────────                            ──────────                       ────────
   git/gh/curl/claude
     │  Authorization: Bearer proxy-token-github
     │  Authorization: Bearer access-token-stub
     ▼
   resolve api.github.com  ─────►  iron-proxy MITM (private CA in pod's trust store)
                                       │
                                       │  match host → look up real credential
                                       │  rewrite Authorization header
                                       ▼
                                   forward to upstream  ───────────►  api.github.com
                                                                       api.anthropic.com
```

Properties this gives us:

- A leaked pod token is worthless outside the cluster (it's literally
  `proxy-token-github`).
- Token rotation is iron-proxy's job. Agents never refresh OAuth — the pod's
  `~/.claude/.credentials.json` is permanently the stub.
- Default-deny domain allowlist means a misbehaving agent can't exfiltrate to
  an attacker-controlled host even if it tried.
- The iron-proxy CA is distributed via ExternalSecret. `setup.sh` installs it
  into `update-ca-certificates`; the Dockerfile sets `NODE_EXTRA_CA_CERTS` so
  the Node-based `claude` CLI trusts it too.

**Why split `GITHUB_TOKEN` from `GIT_GITHUB_TOKEN`?**

- `gh` and the GitHub REST API use plain-text `Authorization: Bearer <token>`
  headers — iron-proxy can string-match and swap `proxy-token-github`.
- `git` HTTPS uses Basic Auth (`Authorization: Basic <base64(user:pass)>`),
  which is opaque to a plain-text match. So `setup.sh` writes the **real**
  PAT into `~/.git-credentials` via `GIT_GITHUB_TOKEN`, and routes `gh`/API
  calls through iron-proxy via `GITHUB_TOKEN=proxy-token-github`.

This is a known wart; an iron-proxy that can decode and rewrite Basic Auth
would let the second token disappear.

## Why Claude Code CLI (not the Agent SDK)

The README has the full version of this argument. Compressed:

- **Claude Agent SDK** is billed as Anthropic API consumption, separate from
  a Pro/Max subscription. Multi-agent always-on Matrix bots would turn a flat
  subscription into a metered bill.
- **`claude -p`** is on subscription quota but single-shot — every invocation
  is a cold start, no prompt cache, no MCP handshake, no Matrix connection.
- **opencode et al.** are good interactive tools but you bring your own model
  — they don't get you the Claude subscription itself.

So: long-lived Claude Code CLI per agent, Matrix channel plugin for input,
`--remote-control` for direct drive-in from a laptop, MCP for everything else.
The stub-credential isolation in iron-proxy is what makes putting a Claude
subscription inside a pod *safe*.

## Release pipeline

```
git tag vX.Y.Z + push                                          docker.yml fires
   │                                                                │
   │                                                                ▼
   │                                                       job: build  (always)
   │                                                       ┌──────────────────┐
   │                                                       │  Buildx multi-   │
   │                                                       │  stage build     │
   │                                                       │                  │
   │                                                       │  docker/metadata-│
   │                                                       │  action computes │
   │                                                       │  tags from ref:  │
   │                                                       │   • vX.Y.Z       │
   │                                                       │   • vX.Y         │
   │                                                       │   • vX           │
   │                                                       │   • latest       │
   │                                                       └────────┬─────────┘
   │                                                                ▼
   │                                                       push to GHCR
   │                                                                │
   │                                                                ▼
   │                                                       job: chart  (only on vX.Y.Z)
   │                                                       ┌──────────────────┐
   │                                                       │  helm package    │
   │                                                       │   --version X.Y.Z│
   │                                                       │  helm push       │
   │                                                       │   oci://ghcr.io/ │
   │                                                       │    sherodtaylor/ │
   │                                                       │    charts        │
   │                                                       │  attach .tgz to  │
   │                                                       │  GitHub Release  │
   │                                                       └──────────────────┘
   ▼
GitHub Release (created manually, see release runbook)
   │
   ▼
Consumer: bump version on HelmRelease in sherodtaylor/homelab
   ▼
Flux reconciles → image roll
```

Rules baked into the metadata-action config:

- Push to `main` → `:main` (moving) + `:sha-<short>` (immutable). **No
  `:latest`.**
- Tag `vX.Y.Z` → `:vX.Y.Z`, `:vX.Y`, `:vX`, `:latest`, *plus* the Helm chart
  job runs and publishes the OCI chart at the matching version.

So a downstream consumer that pins `:latest` only ever gets versioned
releases, never a mid-flight refactor. Detail:
[`docs/runbooks/release.md`](runbooks/release.md).

## Helm chart shape (v0.2.0+)

One Helm release of `agent-smith` deploys N agents from a values-side
`agents: [...]` array. Chart templates fan out per agent:

- `StatefulSet/<agent-name>` (one replica, two PVCs: `home-<agent>-0` +
  `workspace-<agent>-0`)
- `ServiceAccount/<agent-name>`
- `ClusterRoleBinding/agent-smith-<agent-name>` → shared
  `ClusterRole/agent-smith-base`
- `ConfigMap/agent-smith-persona-<agent-name>` (chart-rendered from
  bundled `charts/agent-smith/agents/<name>/` files; skipped when
  `configMapRef` overrides)
- `Service/<agent-name>-shell` + `Ingress/<agent-name>-shell` (when
  `reauth.tunnel.enabled`)
- Optional iron-proxy DNS routing per pod (`dnsPolicy: None`, nameserver
  at `ironProxy.clusterIp`)

One-instance resources (not per-agent):

- `ConfigMap/agent-smith-shared` — contains `_shared/CLAUDE.md`
  cross-cutting content; mounted at `/etc/agent-smith/shared/` in every
  agent's init container, concatenated with the per-agent persona by
  `setup.sh`
- `ClusterRole/agent-smith-base` — one role; N per-agent bindings

Per-agent staging knobs (default to fleet-wide value when omitted):

- `agents[i].image.tag` — overrides fleet-wide `image.tag` for canary
  rolls. Drop the override after promotion.
- `agents[i].configMapRef` — points at an operator-supplied persona
  ConfigMap instead of the chart-rendered default. Use for A/B testing
  personas or staged content rollouts.

Backward-compat: top-level single-agent shape (`agentName: foo` +
sibling fields) accepted during `v0.2.x`/`v0.3.x` via a synthetic
one-element array (`agent-smith.agentList` helper). Removed in
`v0.4.0`.

The chart **does not** manage the underlying `Secret`. The consumer
provides one per agent (manually, ExternalSecrets, sealed-secrets)
with these keys:

| Key | Used by |
|---|---|
| `MATRIX_ACCESS_TOKEN` | Matrix channel plugin |
| `GITHUB_TOKEN` | gh, GitHub API (proxy token; iron-proxy swaps) |
| `GIT_GITHUB_TOKEN` (optional) | git HTTPS Basic Auth (real PAT) |
| `IRON_PROXY_CA_CRT` | system trust store + NODE_EXTRA_CA_CERTS |
| `MATRIX_HOMESERVER_URL`, `MATRIX_BOT_USER_ID` | Matrix plugin |

Detail: [`charts/agent-smith/README.md`](../charts/agent-smith/README.md).

## Logs

`tmux pipe-pane -o 'cat >> /proc/1/fd/1'` is configured on both panes inside
`entrypoint.sh`, so PID 1 sees everything either pane prints. `kubectl logs`
returns the full stream. VictoriaLogs in-cluster captures it via the
DaemonSet.

A known cost: this includes Claude Code's JSONL transcript noise when it
prints assistant messages. We pay it because losing pane output across a
restart would be worse.

## Things that look weird but are load-bearing

| Thing | Why |
|---|---|
| Stub credentials committed to the repo (`access-token-stub`, `refresh-token-stub`) | They're literal placeholders, not secrets. Their presence is what iron-proxy string-matches on. |
| `claude-loop.sh` restoring `.credentials.json` before every start | Claude Code's OAuth refresh overwrites the file mid-flight, stripping `subscriptionType`. Restoring the stub each start keeps the iron-proxy swap working. |
| Two GitHub tokens (`GITHUB_TOKEN` proxy + `GIT_GITHUB_TOKEN` real) | git HTTPS uses Basic Auth which iron-proxy can't plain-text swap. |
| Startup jitter at the top of `entrypoint.sh` | Without it devbot and infrabot restart in lockstep, hammering Anthropic and GitHub simultaneously. |
| `dispatch()` matching prompt text by string | There's no headless config flag for the theme picker / Bypass warning / dev-channels consent. The string match is the workaround. |
| The keepalive prompt injector | Empty Matrix days plus a long idle pane look like a stuck process to outside observers (and sometimes to Claude itself). Random low-frequency activity prevents that. |

If you're about to "fix" one of these, read the related runbook first.
