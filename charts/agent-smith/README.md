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
