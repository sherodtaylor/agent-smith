# D2 spike — chart-deployed substrate installer Job

**Date:** 2026-07-30
**Status:** spike / draft PR
**Owner:** InfraBot
**Scope:** `sherodtaylor/agent-smith` chart

## What this spike answers

Second of three parallel spikes on substrate install-UX bundling (D1 baked-binaries → D2 installer-Job → D3 helm-native). Each ships an actual working install path so Phase 1 measurements happen as a byproduct.

**D2's shape**: when `actor.enabled=true` AND `actor.installMode=job`, the chart emits a one-shot Job that runs `kubectl apply` on vendored substrate manifests. Job runs post-install / post-upgrade (Helm hook), TTLs out in 1h. Substrate images come from the pinned `ghcr.io/sherodtaylor/substrate/<binary>:sha-<8char>` tags built by our `docker.yml` `substrate` job (PR #120).

## What this PR ships

- **`charts/agent-smith/templates/substrate-install-job.yaml`** — one file emitting SA + ClusterRoleBinding + ConfigMap + Job when the opt-in gates are set.
- **`charts/agent-smith/values.yaml`** — new `actor.installMode` (`bring-your-own` | `job` | `helm-native`) and `actor.substrateImageTag` (default `sha-46adcb80`).
- **Spike doc** (this file).

## Design decisions

- **ClusterRoleBinding to `cluster-admin`** for the installer SA. Substrate touches CRDs + ClusterRoles + Deployments + DaemonSets across `ate-system` + `kube-system`; enumerating the exact verbs/groups is toil for no security gain (the installer is a one-shot with a TTL). Scoped-per-release SA + TTL is the guardrail.
- **ConfigMap for manifests, not fetching from git at runtime.** Deterministic, air-gap-friendly, and the checksum drives the Job's helm-hook re-run behavior on chart upgrade.
- **`helm.sh/hook: post-install,post-upgrade`** + `before-hook-creation` delete policy — Job re-runs on every chart upgrade (needed if `substrateImageTag` bumps), previous Job is cleared before the new one lands.
- **`bitnami/kubectl:1.36.1`** for the installer container — small (~40MB), matches our K8s server version, no shell tricks needed.

## What this spike does NOT do (yet)

- **Real substrate manifests** — the ConfigMap ships a placeholder namespace resource only. Vendoring the full manifest tree (ate-api-server, ate-controller, atelet, atenet-{dns,router}, pod-certificate-controller, sandboxconfig-gvisor) with `ko://` refs replaced by our CI-pushed tags is Phase-2-of-spike work. This PR proves the plumbing.
- **`values.schema.json`** validation for the new keys.
- **Chart integration test** — a `tests/` shape that verifies `helm template ... --set actor.enabled=true --set actor.installMode=job` emits exactly the expected Job manifest.

## Tradeoffs (for the D1/D2/D3 comparison)

| Dimension | D2 (this) |
|---|---|
| Image size | agent-smith runtime image unchanged; new Job pulls `bitnami/kubectl:1.36.1` (~40MB) |
| CI build time | Unchanged (agent-smith build). CI ↑ per substrate SHA bump = the `substrate` job in `docker.yml` (~5min). |
| Substrate version coupling | Loose — `actor.substrateImageTag` bumps independently of the agent-smith release |
| Chart install UX | `helm upgrade ... --set actor.enabled=true --set actor.installMode=job` — two flags |
| Manifest customization | ConfigMap contains the full manifest tree; edit + helm upgrade re-applies |
| Rollback | Substrate resources are NOT owned by Helm — rollback of the chart doesn't roll back substrate. Would need a separate `--uninstall`-style Job |
| Onboarding path for D1 operators | Doesn't help (they've already baked binaries in) |
| Onboarding path for D3 operators | Doesn't help (they want Helm-native ownership) |

## When D2 wins

- Operators who want a **one-shot install-and-forget** — substrate installs once, they don't want Helm managing its lifecycle after that.
- Operators who need to **customize substrate manifests** (e.g. tune resource limits, add tolerations) can edit the ConfigMap without touching Helm.
- Substrate + agent-smith **release cadences decouple** — bump substrate by editing one values-file line, no chart version bump.

## When D2 loses

- Chart rollback doesn't roll back substrate — a footgun for GitOps flows expecting atomic behavior.
- No drift detection. If someone `kubectl edit`s substrate resources, the Job won't reconcile.
- Helm's dry-run + install-plan doesn't show what substrate resources will land.

## Verification

- [x] `helm template test ./charts/agent-smith --set actor.enabled=true --set actor.installMode=job` emits the SA + ClusterRoleBinding + ConfigMap + Job.
- [x] Default rendering (both gates off) does NOT emit any of these (opt-in preserved).
- [ ] Post-merge (chart CI on tag push): renders cleanly against the packaged chart.
- [ ] On eval cluster: `helm install ... --set actor.enabled=true --set actor.installMode=job` completes, Job Runs to Completion, `kubectl get ns ate-system` shows the namespace up.
