# D3 spike — helm-native substrate install

**Date:** 2026-07-30
**Status:** spike / draft PR
**Owner:** InfraBot
**Scope:** `sherodtaylor/agent-smith` chart

## What this spike answers

Third of three parallel spikes on substrate install-UX bundling (D1 baked-binaries → D2 installer-Job → **D3 helm-native**). Each ships an actual working install path.

**D3's shape**: when `actor.enabled=true` AND `actor.installMode=helm-native`, chart emits substrate resources directly as first-class Helm templates. Helm owns them — `helm rollback` rolls substrate back, `helm diff` shows drift, `helm uninstall` tears them down atomically. Substrate images come from the pinned `ghcr.io/sherodtaylor/substrate/<binary>:sha-<8char>` tags built by our `docker.yml` `substrate` job (PR #120).

## What this PR ships

- **`charts/agent-smith/templates/substrate/namespace.yaml`** — first substrate resource (the ate-system Namespace) rendered as a Helm template, gated by the two opt-in flags.
- **`charts/agent-smith/values.yaml`** — same `actor.installMode` (`bring-your-own` | `job` | `helm-native`) + `actor.substrateImageTag` additions as D2. The gate values are shared across D2/D3; only the templates differ.
- **Spike doc** (this file).

## Design decisions

- **`templates/substrate/` subdirectory** in the main chart rather than a Helm dependency sub-chart under `charts/agent-smith/charts/substrate/`. Sub-chart pattern is heavier — separate Chart.yaml, separate versioning, `helm dependency update` toil. For the spike scope, templates-directory keeps the diff small and the chart layout simple. Sub-chart is a natural follow-up if D3 wins the comparison and we want to publish substrate as an independently versionable artifact.
- **Helm ownership labels** (`app.kubernetes.io/managed-by`, `app.kubernetes.io/instance`) on every substrate resource — makes `kubectl describe` immediately reveal which chart release owns them, prevents SUC-style parallel installs from conflicting.
- **No separate installer SA/RBAC** — Helm's own install-time credentials (whatever ran `helm install/upgrade`) apply the resources. If the operator's Helm is cluster-admin (typical for Flux `HelmRelease`), substrate CRDs install without extra RBAC choreography.

## What this spike does NOT do (yet)

- **Real substrate manifest set** — only the ate-system Namespace lands. Vendoring the full manifest tree (ate-api-server, ate-controller, atelet DaemonSet, atenet-{dns,router}, pod-certificate-controller, sandboxconfig-gvisor) with `ko://` refs replaced by our CI-pushed tags follows on Phase 2 of the spike. This PR proves the plumbing.
- **Substrate CRD ownership decision** — CRDs are typically installed as `crds/` in a Helm chart (installed but never upgraded / owned by Helm's crds directory), or as regular templates (Helm owns them but crd-updates need care). Deferred; Phase 2.
- **`values.schema.json`** for the new keys.

## Tradeoffs (for the D1/D2/D3 comparison)

| Dimension | D3 (this) |
|---|---|
| Image size | agent-smith runtime image unchanged |
| CI build time | Unchanged; substrate images built by shared `substrate` job (PR #120) |
| Substrate version coupling | Loose — `actor.substrateImageTag` bumps independently of the agent-smith release |
| Chart install UX | `helm upgrade ... --set actor.enabled=true --set actor.installMode=helm-native` — two flags |
| Substrate lifecycle | Full Helm ownership: rollback, diff, uninstall all atomic w/ the chart |
| Manifest customization | Standard Helm templating — values.yaml keys override substrate manifest fields directly |
| Drift detection | `helm diff` shows drift; Flux `HelmRelease` reconciles drift automatically |
| Rollback semantics | `helm rollback` rolls substrate back to prior revision atomically |
| Onboarding path for D1 operators | Doesn't help (they already have baked binaries) |
| Onboarding path for D2 operators | Migrating D2→D3 requires deleting the D2 Job first, then re-installing — non-trivial |

## When D3 wins

- Operators running **Flux `HelmRelease`** — reconciliation, drift correction, and rollback all work out of the box.
- Operators who need **`helm diff`** in their CI to review substrate changes before merge.
- Operators who want **atomic uninstall** — deleting the chart deletes substrate.

## When D3 loses

- **Substrate CRD churn**: substrate is pre-1.0 with disclaimed API changes. Helm-owned CRDs make upstream schema changes riskier (Helm may not upgrade CRDs safely without `--force`).
- **Substrate resources leak across releases**: two agent-smith releases in the same cluster with `installMode=helm-native` conflict on the shared `ate-system` namespace + CRDs. Requires `installMode=helm-native` on exactly one release (documented constraint).
- **Slower `helm install`** — Helm serializes CRD install → CR apply, adding seconds to the install path.

## Verification

- [x] `helm template test ./charts/agent-smith --set actor.enabled=true --set actor.installMode=helm-native ...` renders the ate-system Namespace with the ownership labels.
- [x] Default rendering (both gates off) does NOT render any substrate resource.
- [x] `installMode=job` case (D2) does NOT render the D3 templates (the two modes are mutually exclusive per the gate check).
- [ ] Post-merge (chart CI on tag push): renders cleanly against the packaged chart.
- [ ] Phase 2 followup: vendor real substrate manifests, verify substrate control plane comes up Running under Helm ownership + `helm rollback` rolls it back cleanly.
