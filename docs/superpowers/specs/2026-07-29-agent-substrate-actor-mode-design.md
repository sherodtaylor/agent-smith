# Agent Substrate Actor Mode — Chart Integration Design

**Date:** 2026-07-29
**Status:** Draft (Phase 1/2 spike gates it)
**Owner:** InfraBot
**Scope:** `sherodtaylor/agent-smith` (chart + docs); consumes upstream `agent-substrate/substrate`.

## Companion docs

- **Product framing (generic)**: `sherodtaylor/homelab@main:docs/product/agent-smith/prds/2026-07-28-agent-substrate-bundling-eval.md`
- **Lab execution**: `sherodtaylor/homelab@main:docs/product/homelab/prds/2026-07-28-agent-substrate-lab-execution.md`
- **Homelab Phase 1 install scaffold (draft PR)**: [sherodtaylor/homelab#126](https://github.com/sherodtaylor/homelab/pull/126)
- **k3s v1.36 upgrade runbook (Phase 0, merged)**: `sherodtaylor/homelab@main:docs/runbooks/k3s-v1.36-upgrade.md` (via [homelab#123](https://github.com/sherodtaylor/homelab/pull/123))

This spec is the **implementation-side design** paired with the product PRDs. PRD decisions (Q1–Q16) are inherited and not re-litigated here. This doc answers "what shape does the chart take" and "how do we install substrate under it."

## Goal

Design the chart shape for **opt-in actor mode** in `agent-smith`, so that a fleet operator can toggle a persona from `runtime: deployment` (today's StatefulSet) to `runtime: actor` (substrate-hosted ActorTemplate) in `values.yaml` with no other change to their workflow. Ship the design with concrete answers to:

1. Chart `values.yaml` surface — the exact keys, defaults, and per-persona vs fleet-wide split.
2. Templates — what emits, when, and what stays untouched to preserve the deployment-mode default.
3. Substrate install shape — **bundle-and-vendor** vs **point-at-`install-ate.sh`** (the open follow-up on homelab #126).
4. Snapshot format assumptions — what actor state is in the snapshot vs. what stays in PVC (`DurableDir`).
5. Upstream contribution plan — the concrete PRs/issues we'd file against `agent-substrate/substrate` for gaps U1/U2/U4.

Non-goals: verdict framing (that's the PRD's), density numbers (Phase 2 measures), harness scope beyond claude-code (out per PRD non-goals).

## Chart integration surface

### Fleet-wide values (new)

```yaml
# Opt-in for the fleet. When false, chart behaves exactly as today:
# StatefulSet per persona, ConfigMap-mounted persona, PVC-backed workspace.
actor:
  enabled: false

  # Substrate worker pool config. One pool per fleet.
  workerPool:
    replicas: 2                    # warm workers; sized below persona count for multiplex pressure
    sandboxClass: gvisor           # or 'microvm' when KVM available
    resources:                     # per-worker resource shape
      requests: { cpu: 200m, memory: 512Mi }
      limits:   { memory: 2Gi }
    nodeSelector: {}
    tolerations: []

  # Snapshot storage — S3-compatible; supports self-hosted (rustfs, minio, seaweedfs)
  # and cloud (S3, GCS). Path-style addressing enabled when needed.
  snapshotStore:
    backend: s3                    # 's3' | 'gcs'
    endpoint: rustfs.ate-system.svc.cluster.local:9000
    bucket: agent-smith
    usePathStyle: true             # required for MinIO/rustfs/SeaweedFS
    credentialsSecret: rustfs-credentials  # projects AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY into atelet + actor env

  # Container-level readyz probe on the harness container (skips substrate's
  # default 20s warm-up on golden snapshot creation).
  readyz:
    enabled: true
    path: /readyz
    port: 8081                     # matches the port the harness exposes for suspend-safe wake

  # Iron-proxy re-plumbing: 'sidecar' co-locates iron-proxy inside the ActorTemplate
  # (default per PRD decision), 'atenet' would route egress through atenet's Envoy
  # (deferred; requires atenet HTTPForward config we don't ship today).
  ironProxyMode: sidecar
```

### Per-persona (existing `agents:` array; new field)

```yaml
agents:
  - name: brandbot
    runtime: actor                 # 'deployment' (default) | 'actor'
    # ... all other existing fields still apply. When runtime=actor:
    #   - existingSecret projects into the ActorTemplate's env
    #   - configMapRef (persona) is baked into the golden snapshot at template
    #     apply time — hot-reload no longer applies, per PRD Q16
    #   - matrix.botUserId / allowedUsers still flow through, unchanged
    #   - agentRepos / primaryRepo still applied via initContainers before
    #     the first golden-snapshot capture
```

**Compatibility rule:** if `actor.enabled=false` (default) OR the per-persona `runtime` is unset or equals `deployment`, the chart emits today's StatefulSet + ConfigMap + PVC — bit-for-bit. Nothing changes for existing users unless they opt in twice (fleet + persona).

### Templates

New:
- `templates/workerpool.yaml` — emits one `ate.dev/v1alpha1/WorkerPool` when `actor.enabled=true`. Skipped otherwise.
- `templates/actor-template.yaml` — emits one `ate.dev/v1alpha1/ActorTemplate` per `agents[]` entry with `runtime: actor`. Each template contains:
  - `containers[0]`: the harness (existing agent-smith image), with digest-pinned image (substrate hard-requirement — an image tag will fail template validation).
  - `containers[1..N]`: sidecars for the plugin set + `iron-proxy` when `actor.ironProxyMode=sidecar`. Same env, same secret refs as today's StatefulSet spec.
  - `durableDir`: mounts persona + workspace state, survives suspend/resume.
  - `snapshotsConfig.location`: `s3://{{ .Values.actor.snapshotStore.bucket }}/{{ .Release.Name }}/{{ agent name }}/`
- `templates/rustfs-secret-ref.yaml` — projects the `credentialsSecret` for atelet/actor S3 auth if the operator opts to have the chart manage the projection. Skipped if operator manages the Secret themselves.

Preserved (unchanged when `runtime=deployment`):
- `templates/statefulset.yaml`
- `templates/configmap-persona.yaml`
- `templates/configmap-shared.yaml`
- `templates/serviceaccount.yaml`
- `templates/rbac.yaml`
- `templates/ingress-reauth.yaml` / `service-reauth.yaml`

Modified (add a `runtime` gate at the top; render only when persona is in deployment mode):
- `templates/statefulset.yaml` — `{{- if or (not .Values.actor.enabled) (ne (.agent.runtime | default "deployment") "actor") -}}` guard.
- `templates/configmap-persona.yaml` — same guard. In actor mode the persona is baked into the golden snapshot, not mounted at runtime.

Helper additions in `_helpers.tpl`:
- `agent-smith.runtimeFor` — returns `"actor"` or `"deployment"` for a given agent entry, honoring the fleet gate.
- `agent-smith.actorContainers` — assembles the container list (harness + sidecars per iron-proxy mode) so `actor-template.yaml` stays declarative.

### Chart validation additions

Add JSON-Schema constraints (`values.schema.json`) to catch operator mistakes at `helm template` / `flux reconcile` time rather than at admission:

- If `actor.enabled=true` and any `agents[].runtime=actor`: `actor.snapshotStore.bucket` must be non-empty; `actor.workerPool.replicas` must be ≥ 1; `image.tag` must be a digest (`sha256:...`) — substrate requires digest-pinned images.
- If `agents[].runtime=actor` but `actor.enabled=false`: schema fails with a clear message ("enable `actor.enabled` at fleet level before setting per-persona `runtime: actor`").

## Substrate install shape decision

**Question**: how do consumers get substrate itself (atelet, ate-api-server, atenet, atecontroller, podcertcontroller polyfill) installed on their cluster?

**Path A: bundle a `substrate` sub-chart** under `charts/agent-smith/charts/substrate/`.
- Pros: single `helm install`, versioned in git, GitOps-native.
- Cons: substrate ships `ko://` image references (build-and-resolve at install time); we'd need to pre-build every substrate release to an image registry we control (`ghcr.io/sherodtaylor/agent-substrate-*`) and re-pin. Substrate has 6 binaries; each release means 6 image builds + a chart version bump. Substrate is disclaimed pre-1.0 — this is a moving target.

**Path B: document `install-ate.sh` as a prereq**, chart assumes substrate already present.
- Pros: zero substrate-image toil on our side; substrate operators manage their own version pinning via `INSTALL_ATE_VERSION` (analog). No entanglement with substrate's pre-1.0 velocity.
- Cons: not a single `helm install`; operator runs upstream script separately. GitOps deployments have to shell out to a Job or hand-roll a Kustomization overlay.

**Recommendation: Path B for the eval + initial actor-mode release, revisit Path A after substrate v1.0.**

Rationale:
- Substrate's own README calls the API "VERY early, not prod-ready, APIs will change." Bundling a moving target into `agent-smith`'s chart means every substrate release potentially breaks our chart's semver contract.
- Path B lets us ship actor mode fast and adopt Path A cleanly once substrate stabilizes — the chart contract (`actor.enabled`, `runtime: actor`) doesn't change between paths.
- Path B is honest about the maturity gap the PRD Risk #1 already calls out ("substrate is pre-1.0"). Bundling would paper over that risk.

**What the chart README documents** (for Path B):

> **Prereqs for actor mode:**
> 1. Kubernetes ≥ v1.36 with feature gates `ClusterTrustBundle`, `ClusterTrustBundleProjection`, `PodCertificateRequest` and `runtime-config: certificates.k8s.io/v1beta1=true`.
> 2. `net.ipv4.conf.all.proxy_arp=1` on every node.
> 3. Agent Substrate installed in-cluster — see [upstream install guide](https://github.com/agent-substrate/substrate#quickstart). The chart's `values.actor.snapshotStore.endpoint` must point at a reachable S3-compatible endpoint (rustfs, MinIO, SeaweedFS, or cloud).
> 4. If your egress is filtered, allowlist `storage.googleapis.com` for atelet's runsc self-install.
>
> Chart-side, once substrate is up: set `actor.enabled: true` at fleet level and `runtime: actor` on any persona you want to move onto substrate. Other personas stay on the default StatefulSet path.

If the operator wants a "run this and get everything" bundle, they can wrap the chart install + `install-ate.sh` invocation in their own script or Helmfile. That's a downstream convenience, not part of this chart's contract.

## Snapshot format assumptions

The golden snapshot for an ActorTemplate captures:
1. Process memory of every container (via `runsc checkpoint`) — includes secrets loaded into RAM (Anthropic API keys, GitHub tokens, iron-proxy CA material).
2. Filesystem writes to the container rootfs (up to the snapshot moment).

`DurableDir` captures (separate from process memory):
1. Persona state that must survive across suspend/resume + across template revisions: `~/.claude/`, `~/.config/`, agent workspace (`/workspace/`).

**Implication for the chart**:
- `DurableDir` mount == today's PVC mount for `~/.claude` + `/workspace`. Same TrueNAS-NFS-backed shape, same size defaults.
- Golden-snapshot revalidation trigger = any change to `agents[].configMapRef` (persona) or the harness image digest. Chart could emit a checksum annotation on the ActorTemplate to hint at this to a future controller; substrate handles it natively via ActorTemplate immutability.
- Snapshot bucket layout: `s3://<bucket>/<release>/<agent-name>/` — collision-free across multiple `agent-smith` releases and across personas.

**Security implication (documented per pmbot's #126 finding)**:
- The snapshot bucket is a secrets-adjacent surface once real actors start running. `values.actor.snapshotStore.credentialsSecret` **must** be set + the referenced Secret must exist before Phase 2. Chart JSON-Schema enforces the non-empty-when-actor-enabled constraint.
- rustfs default deployment (per homelab #126) runs unauth. **Blocker for Phase 2**, not for Phase 1 demo actors. Homelab-side fix path documented in `k8s/apps/ate-system/README.md`.

## Upstream contribution plan

Three concrete gaps from the PRD's upstream list. Each is a specific issue/PR against `agent-substrate/substrate`:

| Gap | Type | Effort | When |
|---|---|---|---|
| **U1** — no HelmRelease-friendly install path | Small Chart wrapper PR against upstream, `chart/` sub-dir with a `Chart.yaml` templating over the existing kustomize overlays | ~1 day | Only if Path A revisited after substrate v1.0; otherwise not needed |
| **U2** — `SandboxConfig.assets.*.url` scheme support (`gs://` + `https://` today, no HTTPS mirror override without a fork) | Issue first — clarify whether HTTPS URLs already work end-to-end for a self-hosted mirror. If not, PR adding a `httpsMirror` field to `SandboxConfig.assets.*` | ~2 days if PR needed | Before airgap-tier customers land; not a blocker for our eval |
| **U4** — kind-only quickstart, no k3s / on-prem documentation | Documentation PR + optional overlay under `manifests/ate-install/k3s/` capturing the k3s v1.36 feature-gate + proxy_arp story from our Phase 0 runbook. Small, high value for anyone else doing this. | ~half day | After Phase 1 green — write from actual experience, not speculation |

Filer of record: InfraBot (this spec's owner). PMBot tracks issue/PR status in the PRD's gap list.

## Open questions for Phase 2 measurements

Answers inform verdict paragraph in the PRD:

1. **Iron-proxy sidecar in-sandbox behavior**: co-located iron-proxy container inside the actor sandbox — does gVisor's network give it the same interception path as today's peer-sidecar model? Or does iron-proxy need atenet-side routing changes? Measured on brandbot in Phase 2.
2. **Matrix WS reconnection cost on resume**: even with atenet-router holding the persistent connection, the matrix-plugin sidecar inside the actor still needs to receive events. Does substrate's suspend/resume preserve the plugin's local WS to atenet-router (in-cluster call → low RTT → checkpointable) or does it re-handshake? Measured on brandbot in Phase 2.
3. **DurableDir mount semantics on RWO TrueNAS-NFS PVC**: substrate's `DurableDir` is per-actor; if brandbot has an existing 5 Gi TrueNAS PVC from StatefulSet mode, can we mount it as a `DurableDir` and preserve `~/.claude` state? Or does actor mode require a fresh PVC?
4. **Iron-proxy per-SA scoping**: devbot's #126 review lane. Whether iron-proxy supports per-source (per-ServiceAccount) allowlist rules; if yes, `storage.googleapis.com` scopes to `atelet` only rather than fleet-wide.

## Cross-repo hand-off

- **`sherodtaylor/homelab`** — Phase 1 install scaffold + iron-proxy allowlist landed in #126 (draft). Phase 1 test = install substrate via upstream `install-ate.sh`, run `demos/claude-code-multiplex`.
- **`sherodtaylor/agent-smith`** (this repo) — this spec + follow-up chart change PR when Phase 2 kicks off.
- **`agent-substrate/substrate`** — U1/U2/U4 filed by InfraBot post-Phase 1.
- **`sherodtaylor/claude-code-channel-matrix`** — no expected changes. If Phase 2 finds suspend/resume breaks the matrix plugin's WS handling, that's DevBot's lane to file against the plugin repo.

---

**Ownership going forward:**
- InfraBot owns Phase 1 install + iron-proxy allowlist + Phase 2 substrate-side measurements (atenet HA, snapshot latency, DurableDir semantics).
- DevBot owns Phase 2 chart change (this spec's `values.yaml` sketch → concrete templates + `values.schema.json`).
- PMBot folds Phase 2 numbers into the PRD verdict.
