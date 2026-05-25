# agent-smith Helm chart

Deploys one [agent-smith](https://github.com/sherodtaylor/agent-smith) bot
(InfraBot, DevBot, or any custom persona baked into the image) as a
`StatefulSet` with all the supporting bits — ServiceAccount + ClusterRole
for cluster introspection, two PVCs for `~/.claude/` and `/workspace/`,
optional iron-proxy DNS routing for egress credential isolation.

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

The chart does NOT manage the underlying Secret — bring your own (manually
created, via ExternalSecrets, sealed-secrets, etc.) with these keys:

| Key | Purpose |
|---|---|
| `MATRIX_ACCESS_TOKEN` | Matrix bot login token |
| `GITHUB_TOKEN` | Placeholder proxy token (iron-proxy swaps the real PAT in at egress) |
| `IRON_PROXY_CA_CRT` | iron-proxy MITM CA certificate (PEM) |

## Values

| Key | Default | Notes |
|---|---|---|
| `agentName` | `""` | **Required.** Must match a directory baked into the image (`infrabot`, `devbot`, …) |
| `image.repository` | `ghcr.io/sherodtaylor/agent-smith` | |
| `image.tag` | `""` | Defaults to `Chart.AppVersion` when empty |
| `image.pullPolicy` | `IfNotPresent` | |
| `agentRepos` | `[sherodtaylor/homelab]` | Repos cloned to `/workspace/<basename>` by the init container |
| `primaryRepo` | `homelab` | Sets agent's working directory at startup |
| `matrix.homeserverUrl` | `""` | Required at runtime |
| `matrix.botUserId` | `""` | Required at runtime |
| `matrix.allowedUsers` | `""` | Comma-separated; empty defers to setup.sh default |
| `nats.url` | `""` | Optional — enables the bundled `mcp-nats` MCP server |
| `existingSecret` | `""` | Name of Secret with runtime env vars (see above) |
| `ironProxy.enabled` | `true` | Sets `dnsPolicy: None` + DNS at `ironProxy.clusterIp` |
| `ironProxy.clusterIp` | `10.43.100.100` | |
| `persistence.home.size` | `10Gi` | `~/.claude/` PVC |
| `persistence.workspace.size` | `20Gi` | `/workspace/` PVC (cloned repos) |
| `resources.requests` | `200m CPU / 512Mi memory` | |
| `resources.limits` | `2 CPU / 4Gi memory` | |
| `serviceAccount.create` | `true` | |
| `rbac.create` | `true` | Cluster-scoped role; defaults are read-only and InfraBot-shaped |
| `rbac.rules` | (see `values.yaml`) | Override for an agent that needs to mutate the cluster |
| `extraEnv` | `[]` | Extra env vars merged with the chart-managed ones |
| `nodeSelector`, `tolerations`, `affinity` | `{}` / `[]` / `{}` | |
| `setup.command` | `""` | Shell snippet run at the end of the init container — see [Environment initialization](#environment-initialization) |

## Upgrading

The chart version tracks the agent-smith image release (both bumped together
in the release workflow). To pin to the chart that ships with a specific
image:

```bash
helm upgrade infrabot oci://ghcr.io/sherodtaylor/charts/agent-smith \
  --version 0.2.0 --reuse-values
```

## Uninstall

```bash
helm uninstall infrabot -n agents
```

PVCs created from `volumeClaimTemplates` survive uninstall by design — delete
them by hand if you really want to wipe `~/.claude/` and the cloned repos:

```bash
kubectl delete pvc -n agents -l app.kubernetes.io/instance=infrabot
```

## Environment initialization

`setup.command` is a single shell command (or `;`-separated snippet) executed
inside the `setup` init container after all built-in setup steps (iron-proxy
CA, ~/.claude/ assembly, git/gh credentials, repo clones) complete. Use it to
layer in environment customizations the chart doesn't ship — bootstrap
dotfiles, install per-user tooling, fetch additional credentials, or anything
else your agent needs at boot:

````yaml
setup:
  command: "curl -fsSL https://raw.githubusercontent.com/you/dotfiles/main/install.sh | bash"
````

**Contract:**
- Runs as root in the init container, with `cwd=$HOME`.
- Inherits every env var on the init container, including `GITHUB_TOKEN`
  (proxy-swapped via iron-proxy) and all keys from the `existingSecret`.
- Executed via `bash -o pipefail -c`, so a `curl … | bash` pipeline that
  fails on the upstream side (404, DNS, iron-proxy denial) is detected.
  Multi-statement snippets are still your responsibility — `cmd1; cmd2; cmd3`
  only observes the rightmost exit code; chain with `&&` or add your own
  `set -e` if you need stop-on-first-failure semantics.
- Best-effort: non-zero exit logs `[setup] env-init: warn — hook exited <rc>
  (continuing)` to stderr and the pod continues to start.
- Runs on **every** pod boot. Your command is responsible for being
  idempotent.

**Files your command must NOT clobber:**

Standard dotfiles tools (chezmoi, yadm, stow, plain `ln -sf`) will happily
overwrite files the chart already wrote. The hook runs AFTER these files
exist, so any replacement strips the chart's defaults and breaks runtime:

| Path | Why it's load-bearing |
|------|----------------------|
| `~/.claude/` (entire tree) | Assembled agent persona, MCP config, channel plugin credentials, settings |
| `~/.gitconfig` | Contains `http.sslCAInfo=~/iron-proxy.crt` — required for iron-proxy MITM TLS on `git clone/pull/push` |
| `~/.git-credentials` | Contains the real `GIT_GITHUB_TOKEN` for HTTPS push (env `GITHUB_TOKEN` is the proxy stub) |
| `~/iron-proxy.crt` | iron-proxy CA, also referenced by `NODE_EXTRA_CA_CERTS` |
| `/etc/ssl/certs/ca-certificates.crt` | System trust store; iron-proxy CA was appended via `update-ca-certificates` |

If your installer manages any of these, either skip them in its config or
restore the chart-managed values yourself at the end of the hook.
