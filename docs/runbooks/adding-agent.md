# Runbook: Add a new agent

Use this runbook when adding a brand-new agent to the fleet (a third
agent alongside infrabot + devbot, for example).

> **Chart version:** assumes `agent-smith` chart `v0.2.0+` (values-side
> `agents: [...]` array shape). For older charts that use the legacy
> single-agent shape, you instead copy a HelmRelease file.

## Preconditions

- You've picked a short, lowercase name matching `^[a-z][a-z0-9-]*$`.
- Agent has a Matrix account and access token; you have the bot's full
  user ID (e.g. `@cobot:lab.sherodtaylor.dev`).
- You've decided which repos the agent should clone at startup
  (`agentRepos`).

## Steps

### 1. Provision the agent's secret in Infisical

In the Infisical UI, under workspace `k3` env `prod`, add the keys the
agent needs at runtime — at minimum:

- `MATRIX_ACCESS_TOKEN`
- `GITHUB_TOKEN` (the iron-proxy placeholder — literal string `proxy-token-github`)
- `IRON_PROXY_CA_CRT`
- OAuth tokens if the agent uses Claude: `CLAUDE_ACCESS_TOKEN`,
  `CLAUDE_REFRESH_TOKEN`, `CLAUDE_EXPIRES_AT`
- Any project-specific tokens

### 2. Add an ExternalSecret in homelab

Create `k8s/apps/agents/externalsecret-<agent>.yaml` modeled on the
existing `externalsecret-infrabot.yaml`. The output Secret name
becomes `<agent>-secrets`.

Add the new file to `k8s/apps/agents/kustomization.yaml`.

### 3. Author the agent's persona

Two options — pick one.

**Option A — chart-bundled persona (the public path).** Add a
directory in the agent-smith repo:

```
charts/agent-smith/agents/<agent-name>/
├── CLAUDE.md      # the agent's persona text
└── mcp.json       # MCP server config
```

Open a PR against agent-smith. Once merged + a new chart version is
released, the new agent's persona is bundled in the chart and the
default `agent-smith-persona-<name>` ConfigMap renders from it.

**Option B — operator-supplied ConfigMap (faster iteration).** Create
`k8s/apps/agents/<agent>-persona-configmap.yaml` in homelab:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: <agent>-persona
  namespace: agents
data:
  CLAUDE.md: |
    # MyAgent
    ...persona text...
  mcp.json: |
    { "mcpServers": { ... } }
```

Add it to the Kustomize bundle. Reference via `configMapRef: <agent>-persona`
in the next step. Persona edits land via homelab PR → Flux reconcile →
~90s instead of waiting for a chart release.

### 4. Add the agent to the fleet HelmRelease

Edit `k8s/apps/agents/agent-smith-fleet-helmrelease.yaml`, append a
new entry to `spec.values.agents`:

```yaml
- name: <agent-name>
  existingSecret: <agent>-secrets
  # Option B only:
  # configMapRef: <agent>-persona
  matrix:
    botUserId: "@<agent>:lab.sherodtaylor.dev"
    allowedUsers: "@sherod:lab.sherodtaylor.dev,@infrabot:lab.sherodtaylor.dev,@devbot:lab.sherodtaylor.dev"
  agentRepos: ["sherodtaylor/homelab"]
  primaryRepo: homelab
```

### 5. Open a PR, merge, watch Flux

One PR with the ExternalSecret + (if Option B) ConfigMap + the
HelmRelease edit. Merge. Flux reconciles. The new pod `<agent>-0`
comes up. Tail its setup logs:

```bash
kubectl logs -n agents <agent>-0 -c setup --tail=200
```

Look for `[setup] complete` near the end. Common warnings:

- `[setup] CLAUDE.md assembled from baked-in image files (legacy fallback)`
  — means the persona/shared ConfigMap volumes didn't mount. Check
  the chart version matches what you expect (`v0.2.0+`).
- `[setup] WARN: env-init hook exited <rc>` — the dotfiles installer
  failed. Non-fatal; the pod still boots.
- `[setup] FATAL: ...` — actual fail; fix and re-roll.

### 6. Verify in Matrix

Tag the agent in `#dev` or `#infra`; it should respond per its persona.

## Staging the rollout

To bring up the new agent on a different chart or image version than
the rest of the fleet (canary), set `image.tag` on the agent entry:

```yaml
- name: <agent-name>
  existingSecret: <agent>-secrets
  image: { tag: v0.2.1 }   # canary
  matrix: { ... }
```

Drop the override after the agent proves out; the fleet-wide
`.image.tag` then applies.

See [`docs/runbooks/release.md`](release.md) for the broader release
flow including staged-release procedure.
