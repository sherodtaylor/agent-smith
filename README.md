# agent-smith

> Your engineering team, running in Kubernetes.

<img width="764" height="503" alt="image" src="https://github.com/user-attachments/assets/64c9037e-fc46-4212-b3c6-b5400a6123d1" />

`agent-smith` deploys [Claude Code](https://docs.claude.com/en/docs/claude-code/overview)
as persistent, long-lived engineering agents inside Kubernetes pods. Each agent has a
permanent workspace with real cluster credentials, follows the same git workflow as a
human teammate, and works autonomously until the task is done — feature branches,
conventional commits, pull requests, review comments addressed, merged.

The current team is two agents — **InfraBot** for k3s/Flux and **DevBot** for code —
but the container image is parametric: one new `agents/<name>/` directory and you have a
third teammate.

---

## What your team can do

Each agent:

- **Owns a persistent workspace** — full filesystem + shell access on a long-lived volume
  with real cluster credentials. Work carries over across sessions; context isn't lost on
  restart.
- **Follows the full engineering workflow** — reads the code, writes the fix, opens the
  PR, waits for review, addresses comments, merges. The whole loop, autonomously.
- **Watches its own PRs** — a `Stop`-hook reruns the agent when unaddressed review
  comments appear. No human prompt required to close the loop.
- **Coordinates with teammates** — one agent opens a PR, the other reviews it end-to-end
  and posts inline findings. NATS is the durable audit log for every team action.
- **Never holds production secrets** — stub tokens are swapped for real credentials at the
  network boundary by an egress firewall (see [Security](#security--iron-proxy)). A
  compromised pod can't reach outside the allowlist.

Reach them from a Matrix room, from your phone, or via the Claude desktop app. The
interface is up to you; the engineering capability is always there.

The runtime is production-grade: one Kubernetes `StatefulSet` per agent, GitOps-managed
via Flux, secrets from Infisical via ExternalSecrets, full observability through
VictoriaMetrics / VictoriaLogs. These agents ship work that ends up in `main`.

### Why Claude Code CLI (not the Agent SDK, `claude -p`, or an alternative wrapper)

The interactive CLI is the only option that is long-lived, subscription-billed, and
MCP-capable at the same time:

- **[Agent SDK](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan)** — billed as Anthropic API tokens, not a Pro/Max subscription. An always-on crew turns a flat monthly cost into a per-token meter.
- **`claude -p`** — subscription quota, but exits after each response. No persistent state, no warm prompt cache, no MCP handshake.
- **Alternatives (opencode, etc.)** — you supply the model. Can't drive a Claude subscription.

---

## How it works

One image, many agents. The runtime in a single pod looks like this:

```
StatefulSet/<agent>           (one per agent: infrabot, devbot, …)
└── init container: setup.sh  (assembles ~/.claude, installs plugin, clones repos)
└── main container: entrypoint.sh
    └── tmux session "main"
        ├── pane 0 — claude (channels + --remote-control)  ← receives Matrix messages
        │                                                    + exposed for remote drive-in
        └── pane 1 — plain bash shell                       ← ad-hoc inspection on attach
```

**One image, parametric persona.** Every agent runs `ghcr.io/sherodtaylor/agent-smith:latest`
with a different `AGENT_NAME`. At startup `scripts/setup.sh` reads `agents/<AGENT_NAME>/` and
assembles `~/.claude/` from:

| Source file | Becomes | Purpose |
|---|---|---|
| `agents/_shared/CLAUDE.md` + `agents/<name>/CLAUDE.md` (concatenated) | `~/.claude/CLAUDE.md` | base rules + persona |
| `agents/_shared/settings.json` | `~/.claude/settings.json` | plugins, permissions, hooks |
| `agents/_shared/.credentials.json` | `~/.claude/.credentials.json` | stub OAuth creds (iron-proxy swaps in real tokens at egress) |
| `agents/<name>/mcp.json` | `~/.claude/.mcp.json` | per-agent MCP servers |
| `agents/<name>/subagents/*.md` | `~/.claude/agents/*.md` | persona-specific subagents |

**One claude per pod, channels + remote-control on the same instance.** The entrypoint
launches a single `claude` process with both the Matrix channel plugin
(`--dangerously-load-development-channels plugin:matrix@claude-code-channel-matrix`) and
`--remote-control "${AGENT_NAME}"`. The same instance owns the Matrix identity *and* is
remotely drivable — attaching the Claude desktop/web app picks up that named session. The
second tmux pane is just a plain bash shell for ad-hoc inspection when you `tmux attach`.

**Matrix as the channel.** `~/.claude/settings.json` registers the
[`claude-code-channel-matrix`](https://github.com/zekker6/claude-code-channel-matrix)
plugin via Claude Code's marketplace mechanism, and `setup.sh` writes the per-agent Matrix
credentials and the sender allowlist to `~/.claude/channels/matrix/`. Every permitted
message in a joined room becomes a Claude Code prompt for that agent — no separate
listener, no message queue, no per-room wiring. The 👀 reaction the bot posts on
acknowledgement comes from the same plugin.

**Bots that watch their own PRs.** A `Stop`-hook (`scripts/check-pr-comments.sh`) runs after
every turn, queries GitHub for unaddressed review comments on PRs this agent authored, and
exits `2` to rewake the agent if any are found. The agent then addresses comments without a
human prompt and posts a one-liner back in `#dev`.

**Cross-agent collaboration over Matrix + NATS.** PR notifications and review requests flow
through Matrix mentions (the actual wake signal). NATS is a durable, structured event log
for `pr_opened`, `pr_merged`, `incident`, and `task_done` — written for audit and future
agents to query, not as a trigger.

---

## Repository layout

```
.
├── Dockerfile                       # multi-stage: mcp-nats (Go) + claude CLI + bun
├── .github/workflows/docker.yml     # push-to-main → ghcr.io/sherodtaylor/agent-smith:latest
├── agents/
│   ├── _shared/
│   │   ├── CLAUDE.md                # base rules every agent inherits
│   │   └── settings.json            # plugins, permissions, hooks, allow/deny
│   ├── infrabot/
│   │   ├── CLAUDE.md                # infra persona (k3s, Flux, VictoriaMetrics)
│   │   ├── mcp.json                 # victoria-metrics, victoria-logs, nats
│   │   └── subagents/               # DiagnosticsAgent, FluxAuditor, DocWriter, TestWriter
│   └── devbot/
│       ├── CLAUDE.md                # dev persona (Go/bash/YAML, PR workflow)
│       ├── mcp.json                 # nats
│       └── subagents/               # CodeReviewer, TestWriter
└── scripts/
    ├── setup.sh                     # init container: assemble ~/.claude, clone repos
    ├── entrypoint.sh                # main container: launch tmux + claude (pane 0) + shell (pane 1)
    └── check-pr-comments.sh         # Stop-hook: rewake on unaddressed PR comments
```

The Kubernetes manifests that actually run these pods live in the
[`sherodtaylor/homelab`](https://github.com/sherodtaylor/homelab) repo under
`k8s/apps/agent-smith/`. They are intentionally not in this repo, so the agent image is
deployable from anywhere.

---

## The agents today

**InfraBot** — homelab infrastructure specialist. Owns the k3s cluster, Flux GitOps, Helm
releases, and observability via the VictoriaMetrics/VictoriaLogs MCP servers. Has
subagents for diagnostics (`DiagnosticsAgent`), Flux auditing (`FluxAuditor`),
documentation (`DocWriter`), and validation (`TestWriter`).

**DevBot** — software developer across all repos. Implements features, fixes bugs, writes
tests, and opens PRs. Has subagents for self-review (`CodeReviewer`) and tests
(`TestWriter`).

Both agents are peers. They coordinate through Matrix rooms (`#dev`, `#infra`,
`#general`, `#audit`). NATS JetStream is a shared durable event log they publish to and
query on demand — it never wakes them autonomously; Matrix mentions do.

---

## Configuration

### Init container environment variables

Sourced from Infisical via ExternalSecrets in the homelab manifests, then handed to
`scripts/setup.sh` as plain env vars. Secrets are never echoed.

| Variable | Required | Purpose |
|---|---|---|
| `AGENT_NAME` | yes | Selects `agents/<AGENT_NAME>/` — must match a directory in the image |
| `AGENT_REPOS` | yes | Space-separated `owner/name` list; cloned to `/workspace/<name>` |
| `PRIMARY_REPO` | no (default `homelab`) | Repo basename whose checkout becomes the agent's working directory |
| `MATRIX_HOMESERVER_URL` | yes | e.g. `https://matrix.lab.sherodtaylor.dev` |
| `MATRIX_ACCESS_TOKEN` | yes | Matrix bot login token |
| `MATRIX_BOT_USER_ID` | yes | e.g. `@devbot:lab.sherodtaylor.dev` |
| `MATRIX_ALLOWED_USERS` | no (default `@sherod:lab.sherodtaylor.dev`) | Comma-separated allowlist of senders the bot reacts to |
| `GITHUB_TOKEN` | yes | **Placeholder** proxy token (`proxy-token-github`); iron-proxy swaps in the real PAT at egress |
| `IRON_PROXY_CA_CRT` | yes | iron-proxy MITM CA; installed into the system trust store |

> **Claude credentials are no longer an env var.** Earlier versions used `SWARM_CLAUDE_CREDENTIALS` to inject a real OAuth payload at startup, and prior to that a one-shot setup token. Both are gone — see [Claude credentials](#claude-credentials-stub--login-not-setup-token) below.

### Runtime environment variables

Read by `scripts/entrypoint.sh` and (transitively) by the channel plugin / MCP servers:

| Variable | Used by | Purpose |
|---|---|---|
| `AGENT_NAME` | entrypoint, logs | identifies the pod in tmux/attach messages |
| `PRIMARY_REPO` | entrypoint | sets the tmux pane working directory to `/workspace/$PRIMARY_REPO` |
| `NATS_URL` | `mcp-nats` (per `mcp.json`) | NATS connection string for event publishing |

### AgentConfig anatomy

To make a new agent, create `agents/<name>/`:

```
agents/<name>/
├── CLAUDE.md         # appended after _shared/CLAUDE.md; defines persona, repos, examples
├── mcp.json          # MCP servers to expose to this agent
└── subagents/        # optional persona-specific subagents (one .md per subagent)
    └── *.md
```

That is the entire contract. The image picks it up at build time; deploying a new agent is
adding the directory + a new `StatefulSet` referencing the same image with a different
`AGENT_NAME`.

### Shared settings (`agents/_shared/settings.json`)

The shared settings file is what makes runtime behaviour consistent across agents:

- **`enabledPlugins`** — `matrix@claude-code-channel-matrix` (Matrix channel) and
  `superpowers@claude-plugins-official` (skill framework).
- **`permissions.defaultMode: "auto"`** with a tight allowlist (`Bash(git*)`, `Bash(gh*)`,
  read-only `kubectl` and `flux`, plus filesystem tools) and explicit denies for
  `kubectl delete*` and `git push origin main*`.
- **`hooks.UserPromptSubmit`** — injects a verbosity reminder before every reply so Matrix
  output stays short.
- **`hooks.Stop`** — runs `scripts/check-pr-comments.sh` with `asyncRewake: true`; an exit
  code of `2` rewakes the agent with the rewake message so PR comments don't sit unanswered.

### Claude credentials: stub + login, not setup-token

In-cluster credentials live in `agents/_shared/.credentials.json`, committed to the repo
as a **stub** OAuth payload:

```json
{"claudeAiOauth":{"accessToken":"access-token-stub","refreshToken":"refresh-token-stub", ...}}
```

`setup.sh` copies this file to `~/.claude/.credentials.json` (mode 600). Claude Code reads
it, treats it as a valid signed-in session, and starts. Every request the CLI makes to
`*.anthropic.com` then crosses iron-proxy, which sees the literal `access-token-stub`
string in the `Authorization` header and rewrites it to the real OAuth token before
forwarding upstream. The pod itself never sees the real credential, ever.

**Why not a setup token?**

`claude setup-token` (and its older API key flow) is what you use in a development
environment to bootstrap auth. We don't use it in agent-smith because:

- **Setup tokens are short-lived.** They mint a real OAuth pair on first use and embed it
  in `~/.claude/.credentials.json`. The pod would then be holding a real refresh token —
  exactly the thing iron-proxy exists to prevent.
- **They only work interactively.** `claude setup-token <code>` blocks on a browser flow
  to get the code in the first place. A headless pod has no browser, so the only path was
  to copy a credentials.json from a human's machine — which we used to do via
  `SWARM_CLAUDE_CREDENTIALS` and which had all the rotation/secret-leak problems iron-proxy
  was meant to solve.
- **They get rotated by the upstream.** When Anthropic rotates a refresh token mid-flight,
  the pod's credentials silently expire. With the stub-token flow there is nothing
  rotating — iron-proxy holds the live credential and refreshes it on its own schedule.

**Bootstrapping auth for a local dev clone.** If you want to drive a `claude` CLI from
your own machine against this codebase (without going through iron-proxy), the supported
flow is interactive:

```bash
claude /login
```

Pick the OAuth path, complete the browser flow. That writes a real
`~/.claude/.credentials.json` on your laptop, and the rest of the repo (settings, MCP
config, channels, hooks) Just Works against it. **Never copy that file into a pod** —
that's the exact failure mode the stub + iron-proxy approach was introduced to fix.

---

## Security — iron-proxy

All agent egress runs through **iron-proxy** at ClusterIP `10.43.100.100`. This is the
**egress credential firewall**: agents hold only worthless proxy tokens, and iron-proxy
swaps real secrets in at the network boundary. A leaked agent token is worthless outside
the cluster.

- Agents carry `proxy-token-github` (GitHub) and the stub OAuth payload in
  `agents/_shared/.credentials.json` (`access-token-stub` / `refresh-token-stub`) — literal
  placeholder strings, never the real GitHub PAT or Claude OAuth tokens. See
  [Claude credentials](#claude-credentials-stub--login-not-setup-token) for why.
- iron-proxy MITMs all HTTPS egress, enforces a default-deny domain allowlist, and
  rewrites `Authorization` headers with the real credentials scoped to each host.
- Agent DNS is pointed at iron-proxy (`dnsPolicy: None`). In-cluster names
  (`*.cluster.local`) pass through to CoreDNS so NATS and the Matrix homeserver still
  resolve normally.
- The iron-proxy CA cert is distributed to agent pods via ExternalSecret. `setup.sh`
  installs it into the system trust store with `update-ca-certificates` so `git`, `gh`,
  and `curl` trust the MITM; the Dockerfile sets `NODE_EXTRA_CA_CERTS` so the Node-based
  `claude` CLI does too.

The agent code itself is unaware of any of this — it sends `Authorization:
Bearer proxy-token-github`, iron-proxy turns it into a real PAT, the target site sees a
normal request. The blast radius of a compromised agent pod is therefore "what can be done
through the allowlist" rather than "all of the homelab owner's accounts".

---

## Deployment

The agent runs in the homelab's `agents` namespace as a `StatefulSet` (one per agent) with:

- a PVC at `/root` for the assembled `~/.claude/` and persistent state,
- an init container running `scripts/setup.sh` to populate `/root` and `/workspace`,
- the main container running `scripts/entrypoint.sh` to start tmux,
- env vars sourced from an `ExternalSecret` backed by Infisical,
- `dnsPolicy: None` with `dnsConfig.nameservers: [10.43.100.100]` to route through iron-proxy.

Manifests live in
[`sherodtaylor/homelab/k8s/apps/agent-smith/`](https://github.com/sherodtaylor/homelab/tree/main/k8s/apps/agent-smith).
Reconciliation is via Flux; rolling the image is `flux reconcile kustomization agent-smith`.

---

## Operations

### Attach to a running agent

Both tmux panes are recoverable from a shell on the pod:

```bash
kubectl exec -it -n agents <agent>-0 -- tmux attach -t main
# Ctrl-b o  toggles between pane 0 (claude) and pane 1 (shell)
# Ctrl-b d  detaches without killing anything
```

**Pane 0** is the single live `claude` process — it owns the Matrix identity *and* is
exposed for remote drive-in. Typing into it is fine for ad-hoc prompts, but the Matrix
plugin is the normal input path. Because the same process runs with `--remote-control
<agent>`, the Claude desktop/web app can connect to that named session and you can drive
the bot from your laptop without going through Matrix at all.

**Pane 1** is just a plain `bash` shell in the same `${WORKDIR}` — useful for `kubectl`,
`git status`, `flux logs`, peeking at `~/.claude/`, anything that doesn't belong in the
`claude` REPL.

### Build the image locally

```bash
docker build -t agent-smith:local .
```

The Dockerfile is multi-stage: stage 1 builds [`mcp-nats`](https://github.com/sinadarbouy/mcp-nats)
from source (Go 1.25+), stage 2 produces the runtime image (Debian + `gh`, `kubectl`,
Node.js + Claude Code CLI, Bun for the channel plugin, the mcp-nats binary).

### CI / image publishing

`.github/workflows/docker.yml` builds via Buildx + GitHub Actions cache and pushes to
`ghcr.io/sherodtaylor/agent-smith` with the following tagging contract:

| Trigger | Tags published | Use for |
|---|---|---|
| push to `main` | `:main`, `:sha-<short>` | dev / staging — `:main` moves with every merge; `:sha-…` is immutable |
| git tag `vX.Y.Z` | `:vX.Y.Z`, `:vX.Y`, `:vX`, `:latest` | production — pin to whichever level of mutability you want |

`:latest` only moves on a versioned release, **never on a push to `main`**, so a
consumer that pins `:latest` won't get surprise breakage when an in-flight refactor
lands. The image also carries OCI labels (`org.opencontainers.image.source`,
`description`, `title`, `licenses`) so it renders properly on the GHCR package page.

**Cutting a release:**

```bash
git tag -a v0.1.0 -m "Release v0.1.0 — …"
git push origin v0.1.0
```

The workflow fires on the tag push and produces the four image tags above **and** the
matching Helm chart (see below).

### Helm chart

The chart in [`charts/agent-smith/`](charts/agent-smith) packages a single agent as a
`StatefulSet` with ServiceAccount + ClusterRole, two PVCs (`~/.claude/`, `/workspace/`),
and optional iron-proxy DNS routing. The same release workflow that publishes the image
also packages the chart and pushes it to GHCR as an OCI artifact:

| Trigger | Chart artifact |
|---|---|
| git tag `vX.Y.Z` | `oci://ghcr.io/sherodtaylor/charts/agent-smith:X.Y.Z` + `.tgz` attached to the GH Release |

Install one agent:

```bash
helm install infrabot oci://ghcr.io/sherodtaylor/charts/agent-smith \
  --version 0.1.0 \
  --namespace agents --create-namespace \
  --set agentName=infrabot \
  --set matrix.homeserverUrl=https://matrix.example.com \
  --set matrix.botUserId='@infrabot:example.com' \
  --set nats.url=nats://nats.svc:4222 \
  --set existingSecret=infrabot-secrets
```

`existingSecret` is **required** and must contain `MATRIX_ACCESS_TOKEN`, `GITHUB_TOKEN`,
and `IRON_PROXY_CA_CRT`. The chart doesn't manage the secret itself — bring your own
(manual, ExternalSecrets, sealed-secrets, …). Full values reference in
[`charts/agent-smith/README.md`](charts/agent-smith/README.md).

### Logs

Pane output is teed to PID 1's stdout (`tmux pipe-pane … cat >> /proc/1/fd/1`), so
`kubectl logs` on either container shows both the setup output and the live tmux content.
VictoriaLogs in the cluster captures the full stream.

### Inspect a Matrix sender allowlist

```bash
cat ~/.claude/channels/matrix/access.json
```

To change it, update `MATRIX_ALLOWED_USERS` in Infisical and restart the pod — `setup.sh`
regenerates the file on init.

---

## Agent behaviour

The behavioural contract lives in [`agents/_shared/CLAUDE.md`](agents/_shared/CLAUDE.md)
and the per-agent files. Highlights worth knowing when you watch the bots work:

- **Response triggers.** A bot responds when (a) its name appears in the message, (b) the
  sender is `@sherod:lab.sherodtaylor.dev`, or (c) the message is a threaded reply to
  something the bot said. All other messages get a `👀` reaction and silence.
- **Loop prevention.** Agents never reply to each other unless directly named; max three
  consecutive messages per room without a human in between.
- **Cross-agent PR review.** After opening a PR, the author publishes
  `swarm.events.pr_opened` to NATS and mentions every other teammate by full Matrix ID in
  `#dev`. Mentioned agents read the diff, run the `code-review` skill with `--comment` to
  post inline findings, and post a one-line summary.
- **Autonomous PR follow-up.** The `check-pr-comments.sh` Stop hook rewakes the author on
  unaddressed review comments; the agent addresses or replies to each, then posts a
  one-liner in `#dev`.
- **Secret handling.** Agents are forbidden from echoing, logging, or returning secret
  values in Matrix replies. Generated secrets are written directly to their destination.

For the full set of rules see `agents/_shared/CLAUDE.md`; for per-agent behaviour see
`agents/infrabot/CLAUDE.md` and `agents/devbot/CLAUDE.md`.

---

## Adding a new agent

1. Create `agents/<name>/` with `CLAUDE.md`, `mcp.json`, and an optional `subagents/` dir.
   Use an existing agent as a template — match the section structure.
2. Build and push the image (CI does this automatically on merge to `main`).
3. Provision Matrix credentials for the new bot user in Infisical (`MATRIX_ACCESS_TOKEN`,
   `MATRIX_BOT_USER_ID`).
4. Add the new `StatefulSet` in `sherodtaylor/homelab/k8s/apps/agent-smith/` referencing the
   same image with the new `AGENT_NAME` and the right `AGENT_REPOS`.
5. Reconcile Flux. The pod comes up, joins Matrix, and is ready to be tagged in `#dev` or
   `#infra`.

The shared base rules (`agents/_shared/CLAUDE.md`) automatically include the new agent in
the cross-agent PR review fan-out — no per-agent code change required, the rules read the
**Your Team** list at runtime.
