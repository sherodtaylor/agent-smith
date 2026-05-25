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
else your agent needs at boot.

Example — note the **pinned commit SHA**, not a branch (see "Supply-chain"
below):

````yaml
setup:
  # Replace <SHA> with a specific commit you trust. Don't track `main`.
  command: "curl -fsSL https://raw.githubusercontent.com/you/dotfiles/<SHA>/install.sh | bash"
````

**Execution contract:**
- Runs as root in the `setup` init container, `cwd=$HOME`.
- Invoked as `timeout 120 bash -o pipefail -c "${SETUP_COMMAND}"`:
  - `bash -o pipefail` catches `curl … | bash` upstream failures
    (404 / DNS / iron-proxy denial). Multi-statement snippets only observe
    the rightmost exit — chain with `&&` or add your own `set -e` for
    stop-on-first-failure.
  - `timeout 120` hard-caps a hung command (slow host, apt/dpkg lock).
    A timed-out hook exits 124 and falls through the warn-and-continue path.
- Best-effort: non-zero exit logs `[setup] WARN: env-init hook exited <rc>
  (continuing)` to stderr and the pod continues to start.
- Runs on **every** pod boot. Your command is responsible for being
  idempotent.

**Secret blast radius — read before you put anything in `setup.command`.**

The init container's `envFrom: existingSecret` exposes the entire secret as
env vars to your hook. With the homelab-style secret, the visible keys
include:

| Env var | Risk |
|---------|------|
| `MATRIX_ACCESS_TOKEN` | Full bot login — can post in any room the bot has joined |
| `GIT_GITHUB_TOKEN` | Real GitHub PAT, NOT swapped by iron-proxy — works from any host that has the value |
| `IRON_PROXY_CA_CRT` | Egress-firewall MITM CA (PEM) — anyone with this can MITM the bot's TLS |
| `GITHUB_TOKEN` | Placeholder stub; iron-proxy substitutes the real token only mid-flight for hosts in its allowlist. Persisting this stub to `~/.netrc` / `gh auth login` files saves a useless value. |

**Do NOT** `echo`, `cat`, `printf`, or otherwise log any env var inside
`setup.command`. The container's stdout/stderr ships to VictoriaLogs and is
indexed for cluster-wide search. A leaked token there is a leaked token
everywhere. The fact that the wrapping `[setup] env-init: running user hook`
line itself doesn't capture command output is no protection — your command's
own output goes directly to the pod log.

**Supply-chain — the hook is unverified remote code execution.**

`curl … | bash` runs whatever the URL returns, every pod boot. A force-push
to a `main` branch, a typo-squatted host, an account takeover, or a
compromised CDN all silently change what executes root-in-init with the
secret blast radius above. Mitigations:

- **Pin to a commit SHA**, not a branch (`<owner>/dotfiles/<full-sha>/...`).
  Switching to a new SHA becomes an explicit, reviewable Helm value change.
- **Make sure iron-proxy allows the host.** `raw.githubusercontent.com` is
  not in the same allowlist as `api.github.com`. If it isn't allowed, the
  hook silently warns every boot and you get nothing.
- Consider a checksum step inside `setup.command` itself
  (`curl … | sha256sum -c -`) before piping to `bash`.

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

**Rolling back a hook does NOT undo its side effects.**

`persistence.home` is a real PVC. Anything `setup.command` writes to `/root`
(binaries in `~/.local/bin`, `~/.zshrc`, `~/.gitconfig`, leftover state under
`~/.config/`) survives:

- `helm upgrade --set setup.command=""` — the new pod just doesn't run the
  hook anymore; everything from previous boots stays
- pod restarts, node moves, even `helm uninstall && helm install` under the
  same release name

To genuinely clean up, either run a cleanup `setup.command` first
(removing whatever the previous hook wrote), or
`kubectl delete pvc -n <ns> -l app.kubernetes.io/instance=<release>` per the
Uninstall section above.
