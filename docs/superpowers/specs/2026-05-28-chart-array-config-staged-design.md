# Chart Array of Agents + Config Decouple + Staged Release

**Date:** 2026-05-28
**Status:** Approved (design phase)
**Owner:** InfraBot
**Scope:** `sherodtaylor/agent-smith` chart + `sherodtaylor/homelab` consumer-side rewire
**Companion:** Spec B (deferred) — reference agent personas bundled with the chart, iron-proxy as conditional chart dependency. This spec is the foundation Spec B builds on.

## Goal

Refactor the `agent-smith` Helm chart so a single HelmRelease can deploy N
agents from a values-side `agents: [...]` array, with each agent's persona
config decoupled from the Docker image and mounted from a Kubernetes
ConfigMap. Add per-agent staging knobs (`image.tag` override,
`configMapRef` override) so a single fleet can canary one agent without
rolling the whole set.

## Background

Three friction points motivated this:

1. **Per-HelmRelease-per-agent boilerplate.** Today, every new agent
   needs a copy of `infrabot-helmrelease.yaml` with four field edits
   (name, secret, agentRepos, matrix.botUserId). Same chart, same image,
   same everything else. Adding a third agent means doubling the YAML
   surface in `k8s/apps/agents/`.

2. **Persona changes require an image rebuild.** Today,
   `agents/_shared/CLAUDE.md` and `agents/<name>/CLAUDE.md` live in the
   `agent-smith` Docker image at `/opt/agent-smith/agents/`. A wording
   tweak to a persona is a 5–10 min CI loop (push → image build →
   `cut-release.sh` → chart bump in homelab → Flux reconcile → pod roll).
   Decoupling the persona files into ConfigMaps mounted at runtime
   collapses that to ~90s (push homelab → Flux reconcile → pod restart).

3. **Fleet-wide rolls are too coarse-grained.** A new image release
   today is "all agents on the new version simultaneously." We've
   wanted a "canary infrabot, leave devbot on stable until proven"
   model multiple times during this work. The unified-chart refactor
   would make this WORSE (all agents share a HelmRelease, all roll
   together) unless staging knobs are built in from the start.

## Decision

Three coupled changes in one chart refactor:

1. **`values.agents` is an array.** Each entry declares an agent's
   identity (name), secret reference, and per-agent overrides
   (matrix bot ID, repos to clone, optional image tag, optional
   configMap reference). Chart templates use `{{- range .Values.agents }}`
   to fan out per-agent resources.

2. **Persona config mounted from a ConfigMap (hybrid sourcing).** Each
   agent has a persona ConfigMap providing `CLAUDE.md`, `mcp.json`, and
   optional `subagents/*.md`. The chart ships default persona content
   bundled from the `agents/` directory in the chart source (the
   "example" persona set — primarily a target for Spec B). Per-agent
   `configMapRef` overrides point at an operator-supplied ConfigMap
   instead. `setup.sh` reads from the mounted path; the image stops
   needing per-agent persona files baked in.

3. **Per-agent `image.tag` + `configMapRef` overrides.** Both default
   to the top-level value when omitted (entire fleet on one version).
   Override per-agent for canary rolls: one agent on a new image tag
   or a new persona ConfigMap while others stay pinned to the
   defaults.

## Non-Goals

- **Reference persona content** ("example-infrabot", "example-devbot"
  files in the chart source) — that's Spec B; this spec only ships
  the *mount mechanism* and the chart structure that lets bundled
  defaults work. The defaults can be empty or stub-only in this PR.
- **iron-proxy as a chart dependency** — Spec B. Conditional
  `dependencies:` entry in `Chart.yaml` lands later.
- **Migrating shared cluster RBAC.** `homelab/k8s/apps/agents/rbac.yaml`
  pre-creates ClusterRoleBindings today; moving those into the chart
  is in scope for this spec (one binding per agent, all under the
  same ClusterRole), but the ClusterRole itself stays as-is.
- **Per-agent StorageClass / PVC size overrides.** Out of scope; one
  set of persistence values applies to all agents in the array. Add
  later if needed.
- **Per-agent reauth-tunnel hostname overrides beyond the existing
  `<name>-shell<hostSuffix>` pattern.** Hostname stays templated;
  enabling/disabling stays a top-level value.
- **Multi-namespace fleets.** All agents in an array land in the
  same namespace as the HelmRelease.
- **An "agentsTemplate" base + override pattern** (i.e., one
  base config with array-level diffs only). Each array entry is
  fully self-contained; values that share defaults live at top-level
  outside the array (`image`, `persistence`, `resources`, etc.). YAML
  anchors handle any further dedup the operator wants.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ HelmRelease: agent-smith-fleet (homelab/k8s/apps/agents/)       │
│                                                                  │
│   chart: agent-smith                                             │
│   values:                                                        │
│     image: { tag: v0.2.0 }                ◄─ fleet default       │
│     agents:                                                      │
│       - name: infrabot                                           │
│         existingSecret: infrabot-secrets                         │
│         configMapRef: infrabot-persona-v3   ◄─ persona override  │
│         matrix: { botUserId: "@infrabot:..." }                   │
│       - name: devbot                                             │
│         existingSecret: devbot-secrets                           │
│         image: { tag: v0.2.1 }              ◄─ canary image      │
│         matrix: { botUserId: "@devbot:..." }                     │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
       chart templates run `range .Values.agents` and emit:
                              │
   ┌──────────────────────────┼──────────────────────────┐
   ▼                          ▼                          ▼
┌──────────┐            ┌──────────┐            ┌──────────┐
│ infrabot │            │ devbot   │            │ shared   │
│ resources│            │ resources│            │ resources│
├──────────┤            ├──────────┤            ├──────────┤
│ STS      │ image=v0.2.0│ STS      │ image=v0.2.1│ CM       │
│ SA       │ persona-v3  │ SA       │ persona-def │ (shared  │
│ CRB      │             │ CRB      │             │  CLAUDE) │
│ PVC×2    │             │ PVC×2    │             │ CR       │
│ Svc-ttyd │             │ Svc-ttyd │             │ (one     │
│ Ingr-ttyd│             │ Ingr-ttyd│             │  role)   │
└──────────┘            └──────────┘            └──────────┘
```

## Components

### 1. `values.agents[]` schema

Each entry in the array is a self-contained agent declaration:

```yaml
agents:
  - name: infrabot                     # required, unique within array
    existingSecret: infrabot-secrets   # required, name of pre-existing Secret
    configMapRef: infrabot-persona     # optional, overrides bundled defaults
    image:                             # optional, falls back to top-level .image
      tag: v0.2.0
    matrix:                            # required
      botUserId: "@infrabot:lab.sherodtaylor.dev"
      allowedUsers: "@sherod:lab.sherodtaylor.dev,@devbot:..."
    agentRepos:                        # required
      - sherodtaylor/homelab
    primaryRepo: homelab               # required
```

All values in the entry are **leaves** — no deeper nesting that would
require merge logic. If a value is omitted, the template substitutes
the corresponding top-level value (e.g. `image.tag`, `persistence.home.size`).

The `name` field is the StatefulSet name, ServiceAccount name, and the
key used for chart-generated bundled-persona ConfigMap lookup
(`agent-smith-persona-<name>` if no `configMapRef` provided).

### 2. Persona mount (hybrid sourcing)

Each agent gets persona content from one of two sources:

**Operator-supplied ConfigMap (recommended for production):**
- Agent entry sets `configMapRef: <name>`
- Chart mounts that ConfigMap at `/etc/agent-smith/persona/` in the
  init container
- Expected keys in the ConfigMap: `CLAUDE.md` (required), `mcp.json`
  (required), `subagents/*.md` (optional; ConfigMap's binaryData or
  named subkeys depending on subagent format).

**Bundled default (works out-of-box, primary target for Spec B):**
- Agent entry omits `configMapRef`
- Chart renders a ConfigMap from a Helm `Files.Glob` over its own
  `agents/<name>/` source tree at install time
- ConfigMap name: `agent-smith-persona-<agent-name>`
- For Spec A, the chart ships *empty* or *stub* persona files at
  these paths (only enough to keep the mount valid); real reference
  personas land in Spec B
- A user installing the chart with `agents: [{name: example-bot,
  existingSecret: ...}]` gets a working pod that boots with a
  placeholder persona; they replace via `configMapRef` later

**Shared persona** (one instance, all agents):
- Chart renders ONE shared ConfigMap (`agent-smith-shared`) containing
  the cross-cutting `_shared/CLAUDE.md` and any other shared files
- Mounted at `/etc/agent-smith/shared/` in every init container
- `setup.sh` concatenates `shared/CLAUDE.md` + `persona/CLAUDE.md` →
  `~/.claude/CLAUDE.md` (same concat logic as today, just reading from
  different paths)
- For Spec A: the shared ConfigMap's content is rendered from the
  chart source's `agents/_shared/CLAUDE.md`. For Spec B: this is the
  living `_shared/CLAUDE.md` that public users see as reference.

### 3. Per-agent staging knobs

Two override dials, both per-agent, both optional, both default to the
top-level fleet value:

**`agents[i].image.tag`** — when set, that agent's StatefulSet uses
the named image tag instead of `.Values.image.tag`. Use case: bump
fleet to `v0.2.0`, then later set `agents[devbot].image.tag: v0.2.1`
to canary the new image on devbot first. After validation, drop the
override and bump top-level `.image.tag` to `v0.2.1`. Repeat for
infrabot when ready.

**`agents[i].configMapRef`** — when set, mounts that operator-supplied
ConfigMap as the agent's persona instead of the chart's bundled
default. Use case: stage a persona rewrite by creating
`infrabot-persona-v4` ConfigMap, point one agent at it, watch behavior,
then point the rest of the fleet at it. Rollback: re-point at v3.

Other fields are not staging-knobs by design — `existingSecret`,
`matrix.botUserId`, `agentRepos` are identity for the agent and
shouldn't change between canary and production for the same name.

### 4. Chart-generated per-agent resources

Inside `{{- range .Values.agents }}`:

- `StatefulSet/<name>` — same shape as today's chart, with `.name`,
  `.existingSecret`, `.image.tag` (override or fallback),
  `.matrix.botUserId`, etc. interpolated.
- `ServiceAccount/<name>` — moved out of homelab `rbac.yaml`; chart
  generates one per agent.
- `ClusterRoleBinding/agent-smith-<name>` — binds the per-agent SA to
  the shared `ClusterRole/agent-smith-base`.
- `Service/<name>-shell` + `Ingress/<name>-shell` — only when
  `.reauth.tunnel.enabled: true` (which is the fleet-wide knob;
  per-agent enable/disable not in scope).
- Persona ConfigMap (when no `configMapRef` provided) — rendered from
  bundled `agents/<name>/` source files via `Files.Glob`.

PVCs are still managed by `volumeClaimTemplates` inside each
StatefulSet (`home-<name>-0`, `workspace-<name>-0`). No data
migration needed when switching from per-HR-per-agent to array — the
PVC names depend on StatefulSet name, which the chart preserves as
`{{ .name }}`.

### 5. Chart-generated shared resources (one instance)

- `ClusterRole/agent-smith-base` — single role, N per-agent bindings.
- `ConfigMap/agent-smith-shared` — shared persona content (cross-cutting
  rules from `_shared/CLAUDE.md`).
- `HelmRepository` is still managed by Flux as a separate resource
  in homelab (not chart-internal).

### 6. Backward compatibility shim

The chart accepts the OLD single-agent shape during a deprecation
window:

```yaml
# Old shape (still works for one release cycle)
agentName: infrabot
existingSecret: infrabot-secrets
matrix: { botUserId: "@infrabot:..." }
# ... etc.

# New shape (this PR introduces)
agents:
  - name: infrabot
    existingSecret: infrabot-secrets
    matrix: { botUserId: "@infrabot:..." }
```

Logic in `_helpers.tpl`:

- If `.Values.agents` is non-empty → use the array.
- Else if `.Values.agentName` is set → construct a one-element synthetic
  array from the legacy top-level fields. Log a `helm install --dry-run`
  warning (NOTES.txt) that the legacy shape is deprecated.
- Both set → template render fails with: `Both .Values.agentName and
  .Values.agents are set — remove top-level agentName; use agents[] only`.
- Neither set → template render fails with: `Set either .Values.agents
  (recommended) or .Values.agentName (legacy)`.

The shim survives for two chart minor releases (`v0.2.x` and `v0.3.x`),
then is removed in `v0.4.0`. CHANGELOG documents the deprecation
window in the v0.2.0 entry.

## Migration plan (homelab side)

Two-phase rollout to keep risk low — neither agent rolls onto the new
chart shape simultaneously.

### Phase 1 — devbot canary

1. agent-smith ships `v0.2.0` with the new chart and the deprecation
   shim.
2. homelab gains a NEW HelmRelease `agent-smith-fleet-helmrelease.yaml`
   with chart `0.2.0` and `agents: [{name: devbot, ...}]` (single entry).
3. homelab's existing `devbot-helmrelease.yaml` is set to
   `spec.suspend: true` (Flux stops reconciling; the existing
   StatefulSet/PVCs remain).
4. Flux reconciles → the new HelmRelease takes ownership of the `devbot`
   StatefulSet. Because the StatefulSet's `metadata.name` stays as
   `devbot` (same as before), it operates on the SAME `home-devbot-0`
   and `workspace-devbot-0` PVCs — no data migration.
5. devbot pod rolls onto the new chart's pod template. Same Matrix
   bot ID, same Infisical secret, same workspace. Observe ~24h for
   regressions in any of: setup.sh init, plugin reconciler, matrix
   plugin behavior, persona content rendering correctly from the
   mounted ConfigMap.

### Phase 2 — infrabot migration

1. After devbot stable: edit `agent-smith-fleet-helmrelease.yaml` and
   append `{name: infrabot, existingSecret: infrabot-secrets, ...}` to
   the `agents` array.
2. Suspend `infrabot-helmrelease.yaml` (`spec.suspend: true`).
3. Flux reconciles → infrabot's StatefulSet now lives in the fleet
   HelmRelease, same PVCs preserved. Pod rolls onto the new template.
4. After both agents are stable on the fleet HelmRelease, delete both
   suspended `*-helmrelease.yaml` files entirely (clean up).

### Rollback at either phase

- Re-enable the suspended old HelmRelease (`spec.suspend: false`).
- The old chart version's StatefulSet takes ownership again (same
  name, same PVCs).
- Suspend the new fleet HelmRelease.
- Pod rolls back onto the old chart's templates.

The PVCs are the durability anchor; both chart shapes name the
StatefulSet the same, so PVC ownership transfers transparently.

## File Map

### `sherodtaylor/agent-smith` (this PR)

| File | Action | Responsibility |
|------|--------|----------------|
| `charts/agent-smith/values.yaml` | **Modified** | Drop `agentName`, `existingSecret`, `matrix`, `agentRepos`, `primaryRepo` from top level (move into per-agent entries); introduce empty `agents: []` default; keep `image`, `persistence`, `resources`, `nodeSelector`, `tolerations`, `affinity`, `setup`, `extraEnv`, `reauth`, `ironProxy`, `rbac` at top level |
| `charts/agent-smith/templates/statefulset.yaml` | **Modified** | Wrap whole template in `{{- range .Values.agents }}`; interpolate per-agent fields; pull `image.tag` from `.image.tag` if set else `$.Values.image.tag`; mount persona ConfigMap (operator-supplied via `.configMapRef` OR chart-rendered `agent-smith-persona-<name>`) at `/etc/agent-smith/persona/`; mount shared ConfigMap at `/etc/agent-smith/shared/` |
| `charts/agent-smith/templates/serviceaccount.yaml` | **Modified** | Loop per-agent; ClusterRole stays singular |
| `charts/agent-smith/templates/rbac.yaml` | **Modified** | One `ClusterRole/agent-smith-base`; N `ClusterRoleBinding/agent-smith-<name>` looped per-agent |
| `charts/agent-smith/templates/configmap-shared.yaml` | **New** | Single ConfigMap `agent-smith-shared` containing `_shared/CLAUDE.md` via `Files.Get` |
| `charts/agent-smith/templates/configmap-persona.yaml` | **New** | Loop per-agent; only emit when `.configMapRef` is NOT set; renders ConfigMap `agent-smith-persona-<name>` from bundled `agents/<name>/` files |
| `charts/agent-smith/templates/service-reauth.yaml` | **Modified** | Loop per-agent; conditional on top-level `reauth.tunnel.enabled` |
| `charts/agent-smith/templates/ingress-reauth.yaml` | **Modified** | Loop per-agent |
| `charts/agent-smith/templates/_helpers.tpl` | **Modified** | Add `agent-smith.agentList` helper that returns either `.Values.agents` (new shape) or a one-element synthetic array (legacy shape); add deprecation warning emission |
| `charts/agent-smith/templates/NOTES.txt` | **Modified** | Warn if legacy `agentName` shape used; list each agent in the array on success |
| `charts/agent-smith/Chart.yaml` | **Modified** | Bump `version` to `0.2.0` (minor — breaking-with-shim) |
| `scripts/setup.sh` | **Modified** | Read `CLAUDE.md` + `mcp.json` from `/etc/agent-smith/persona/` and `/etc/agent-smith/shared/` instead of `/opt/agent-smith/agents/<name>/`; concat logic preserved |
| `agents/_shared/CLAUDE.md`, `agents/_shared/settings.json` | **Unchanged in repo location** | Still the source of truth in the chart source; chart-rendered into `agent-smith-shared` ConfigMap |
| `charts/agent-smith/agents/example-infrabot/`, `example-devbot/` | **New (chart-bundled)** | **Generic example personas only** — public chart must not ship operator-specific content. Source for chart-rendered `agent-smith-persona-<name>` ConfigMaps when an operator uses these names AND omits `configMapRef`. Production operators (including this homelab) override via `configMapRef` pointing at their own ConfigMaps. |
| Top-level `agents/infrabot/`, `agents/devbot/` | **Removed** | Sherod-specific persona content moves out of the chart repo into operator-side ConfigMap manifests (in `sherodtaylor/homelab`). The chart-bundled `example-*` entries are documentation, not deployable production personas. |
| `Dockerfile` | **Unchanged** | Persona files still copied to `/opt/agent-smith/agents/` for legacy shape compatibility during deprecation window |
| `CHANGELOG.md` | **Modified** | Entry under `[Unreleased]` describing the array shape, persona mount, staging knobs, migration, and the deprecation window |
| `docs/architecture.md` | **Modified** | Update the system overview to describe the array-of-agents pattern |
| `docs/runbooks/adding-agent.md` | **Modified** | Rewrite for the array shape — "add an entry to `agents:`, create an ExternalSecret, you're done" |
| `docs/runbooks/release.md` | **Modified** | Mention per-agent `image.tag` override as the supported canary mechanism |

### `sherodtaylor/homelab` (follow-up PR after agent-smith merges)

| File | Action | Responsibility |
|------|--------|----------------|
| `k8s/apps/agents/agent-smith-fleet-helmrelease.yaml` | **New** | The single fleet HelmRelease with `agents: [...]` array |
| `k8s/apps/agents/devbot-helmrelease.yaml` | **Modified → Removed** | Phase 1: add `spec.suspend: true`. Phase 2: delete. |
| `k8s/apps/agents/infrabot-helmrelease.yaml` | **Modified → Removed** | Phase 2: suspend then delete |
| `k8s/apps/agents/rbac.yaml` | **Modified or removed** | Per-agent ClusterRoleBindings move into chart; only cluster-wide pieces stay |
| `k8s/apps/agents/shared-values.yaml` | **Modified** | Continues to ConfigMap-export shared values referenced by the fleet HelmRelease's `valuesFrom` |
| `k8s/apps/agents/externalsecret-infrabot.yaml` | **Unchanged** | Still creates `infrabot-secrets` |
| `k8s/apps/agents/externalsecret-devbot.yaml` | **Unchanged** | Still creates `devbot-secrets` |
| `k8s/apps/agents/kustomization.yaml` | **Modified** | Drop the two single-agent HelmReleases, add the fleet HelmRelease |
| `k8s/apps/agents/<agent>-persona-configmap.yaml` | **Optional new** | If operator wants to override the chart's bundled persona, ship a ConfigMap here and reference via `configMapRef` |

The homelab side ships in its OWN PR after the chart PR merges and a
`v0.2.0` chart release is published.

## Acceptance Criteria

- [ ] Chart `v0.2.0` renders without errors for an `agents: [...]`
      array of length 1, 2, and 3 (verified via `helm template`).
- [ ] Chart `v0.2.0` renders without errors for legacy `agentName: foo`
      shape (deprecation shim works) and emits a NOTES.txt warning.
- [ ] Chart `v0.2.0` rejects (template error) when BOTH `agents` and
      `agentName` are set.
- [ ] Per-agent `image.tag` override produces a StatefulSet with the
      overridden tag while other agents in the array use the top-level
      tag (verified via `helm template … | grep image:`).
- [ ] Per-agent `configMapRef` override produces a StatefulSet whose
      persona-mount volume references the supplied ConfigMap name (not
      the chart-rendered `agent-smith-persona-<name>`).
- [ ] When `configMapRef` is omitted, the chart renders an
      `agent-smith-persona-<name>` ConfigMap containing the bundled
      `agents/<name>/CLAUDE.md` + `mcp.json`.
- [ ] `setup.sh` boots cleanly when given persona content from
      `/etc/agent-smith/persona/` and `/etc/agent-smith/shared/`
      (verified end-to-end on a real pod in cluster validation).
- [ ] Phase 1 cluster: devbot rolls onto the fleet HelmRelease,
      preserves its PVCs (`home-devbot-0`, `workspace-devbot-0`),
      reconnects to Matrix as `@devbot:lab.sherodtaylor.dev`, and
      processes messages normally.
- [ ] Phase 2 cluster: infrabot rolls onto the fleet HelmRelease,
      same identity, same PVCs.
- [ ] Documentation updated in the same PR: `docs/architecture.md`,
      `docs/runbooks/adding-agent.md`, `docs/runbooks/release.md`,
      `CHANGELOG.md`. No doc drift.

## Risks

- **PVC identity migration depends on StatefulSet name stability.**
  The new chart MUST name StatefulSets exactly `<agent-name>` (no
  release-name prefix). If the new template accidentally prepends
  `{{ include "agent-smith.fullname" . }}`, the new StatefulSet gets
  a different name and creates fresh PVCs — devbot loses its
  `~/.claude/` and `/workspace/<repo>` data. Mitigation: template
  asserts `metadata.name: {{ .name }}` and a `helm template`
  smoke-check in the implementation plan grep-asserts the rendered
  output contains `name: devbot` (not `name: agent-smith-fleet-devbot`).
- **Persona ConfigMap mutation triggers pod restart.** Kubernetes
  doesn't auto-restart pods when a mounted ConfigMap changes; the
  mounted files update on the FS but the init container has already
  run. Operator must annotate-restart the StatefulSet after a persona
  ConfigMap edit. Mitigation: chart adds a `checksum/persona-<name>`
  annotation on the StatefulSet pod template so Helm itself triggers
  a rolling restart on persona change (standard Helm pattern).
- **Legacy shape removal lands too soon.** External chart consumers
  (none today, but Spec B opens that door) might rely on the
  `agentName: foo` shape after we remove it. Mitigation: two-release
  deprecation window (`v0.2.x` and `v0.3.x`), CHANGELOG calls it out
  in `v0.2.0` and again in `v0.3.0`.
- **Suspended HelmRelease leaves orphaned resources.** Flux's
  `suspend: true` stops reconciliation but does NOT delete the
  StatefulSet. During Phase 1, two HelmReleases would BOTH manage a
  resource named `devbot` if the new release reconciles before the
  old is suspended. Mitigation: the runbook orders the steps
  explicitly — suspend old FIRST, then commit the new HelmRelease.
- **ConfigMap size limits.** Each ConfigMap is capped at 1 MiB.
  Persona files today are 10–30 KB each; well under. Mitigation:
  not needed for foreseeable persona growth; the chart can split into
  multiple keyed entries if it ever becomes an issue.

## Implementation Note

This spec ships in TWO PRs in sequence:

1. **agent-smith chart PR** — the chart refactor + setup.sh update +
   docs + CHANGELOG + deprecation shim. Tagged as `v0.2.0`. CI builds
   image, publishes chart.
2. **homelab PR** — add the fleet HelmRelease, suspend devbot's old
   HelmRelease (Phase 1). After validation (~24h), follow-up homelab
   PR for Phase 2 (infrabot migration + remove suspended HelmReleases).

The chart PR is independently mergeable (deprecation shim means
existing homelab `v0.1.24` consumers continue working). The homelab
side is the consumer adoption.
