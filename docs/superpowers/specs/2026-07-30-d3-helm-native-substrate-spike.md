# D3 spike — helm-native substrate install

**Date:** 2026-07-30
**Status:** spike / draft PR
**Owner:** InfraBot
**Scope:** `sherodtaylor/agent-smith` chart

## What this spike answers

Third of three parallel spikes on substrate install-UX bundling (D1 baked-binaries → D2 installer-Job → **D3 helm-native**). Each ships an actual working install path.

**D3's shape**: when `actor.enabled=true` AND `actor.installMode=helm-native`, chart emits substrate resources directly as first-class Helm templates. Helm owns them — `helm rollback` rolls substrate back, `helm diff` shows drift, `helm uninstall` tears them down atomically. Substrate images come from the pinned `ghcr.io/sherodtaylor/substrate/<binary>:sha-<8char>` tags built by our `docker.yml` `substrate` job (PR #120).

## What this PR ships

- **`charts/agent-smith/templates/substrate/`** — full first-pass vendoring of the upstream `manifests/ate-install/` core (see "Vendored components" below). Every file is wrapped in the D3 opt-in gate; `ko://…/cmd/<binary>` refs are rewritten to `ghcr.io/sherodtaylor/substrate/<binary>:{{ .Values.actor.substrateImageTag }}`; CRDs carry `helm.sh/resource-policy: keep` so `helm uninstall` doesn't drop schemas out from under existing CRs.
- **`charts/agent-smith/values.yaml`** — same `actor.installMode` (`bring-your-own` | `job` | `helm-native`) + `actor.substrateImageTag` additions as D2. The gate values are shared across D2/D3; only the templates differ.
- **Spike doc** (this file).

### Vendored components (Task #12 promotion)

Landed under `templates/substrate/`:

| File | Upstream source | Notes |
|---|---|---|
| `namespace.yaml` | *(chart-authored)* | ate-system Namespace, Helm ownership labels. |
| `crds/actortemplates-crd.yaml` | `manifests/ate-install/generated/ate.dev_actortemplates.yaml` | resource-policy: keep. |
| `crds/sandboxconfigs-crd.yaml` | `manifests/ate-install/generated/ate.dev_sandboxconfigs.yaml` | resource-policy: keep. |
| `crds/workerpools-crd.yaml` | `manifests/ate-install/generated/ate.dev_workerpools.yaml` | resource-policy: keep. |
| `ate-api-server.yaml` | `manifests/ate-install/ate-api-server.yaml` | Deployment + PDB + Service + RBAC. `ateapi` image rewritten. |
| `ate-controller.yaml` | `manifests/ate-install/ate-controller.yaml` | Deployment + Service + RBAC. `atecontroller` image rewritten. Upstream declares the ate-system Namespace inline; that block is removed (our `namespace.yaml` owns it). |
| `atelet.yaml` | `manifests/ate-install/atelet.yaml` | DaemonSet + RBAC. `atelet` image rewritten. |
| `atenet-router.yaml` | `manifests/ate-install/atenet-router.yaml` | Deployment + Service + ConfigMap + RBAC. `atenet` image rewritten. |
| `atenet-dns.yaml` | `manifests/ate-install/atenet-dns.yaml` | Deployment (`dns`) + Service + Role/RoleBinding in ate-system AND kube-system. `atenet` image rewritten (dns-controller sidecar). |
| `pod-certificate-controller.yaml` | `manifests/ate-install/pod-certificate-controller.yaml` | Namespace (`podcertificate-controller-system`) + Deployment + ClusterRole/Binding + Role/RoleBinding. `podcertcontroller` image rewritten. Consumed Secrets (`service-dns-ca-pool`, `pod-identity-ca-pool`) are operator-provisioned — see "Operator-provisioned Secrets" below. |
| `valkey.yaml` | `manifests/ate-install/valkey.yaml` | ConfigMap + 2 Services (`valkey-cluster`, `valkey-cluster-service`) + StatefulSet (6 replicas) + init Job. Upstream `valkey/valkey:9.1` image (no ko:// rewrite). Consumed Secret (`valkey-ca-certs`) is operator-provisioned. |

### Phase 1 blocker fix (deferral rationale corrected)

An earlier draft of this table listed `pod-certificate-controller.yaml` and `valkey.yaml` as deferred. That was wrong on both counts and blocked the `v0.3.0-rc1` HelmRelease boot in the homelab:

- `ate-api-server` FailedMount on `podidentity` / `servicedns` projected volumes — the PodCertificate credentials come from **substrate's own `podcertcontroller`**, not from the upstream `certificates.k8s.io/v1beta1` API. The deferral note ("requires v1beta1 feature gate") conflated the two — the K8s v1beta1 signer types are only involved insofar as `podcertcontroller` implements them; the controller ships as one of substrate's six binaries and is load-bearing for boot.
- `ate-api-server` FailedMount on `valkey-ca-certs`, `session-id-ca-pool`, `session-id-jwt-pool` — the apiserver's Redis client cannot init without valkey being reachable; valkey is not optional for the substrate control plane.

Both are now vendored above.

### Operator-provisioned Secrets

Substrate's `install-ate.sh` creates several Secrets at install time via `kubectl-ate admin make-{ca,jwt}-pool` and openssl-derived concatenation. These cannot be helm-rendered (they need real crypto ops on generated CA / JWT signing material) and are NOT included in `templates/substrate/`. Operator must provision them before the HelmRelease rolls out (or install substrate's `kubectl-ate` CLI and run the corresponding create-step against the cluster):

| Secret | Namespace | Created by | Contents |
|---|---|---|---|
| `service-dns-ca-pool` | `podcertificate-controller-system` | `create_podcertificate_controller_cas` (`kubectl-ate admin make-ca-pool --ca-id=1 --name=service-dns-ca-pool`) | CA-pool JSON that `podcertcontroller` uses to sign `servicedns.podcert.ate.dev/*` PodCertificateRequests. |
| `pod-identity-ca-pool` | `podcertificate-controller-system` | `create_podcertificate_controller_cas` (`kubectl-ate admin make-ca-pool --ca-id=1 --name=pod-identity-ca-pool`) | CA-pool JSON for `podidentity.podcert.ate.dev/*` requests. |
| `session-id-ca-pool` | `ate-system` | `create_session_id_ca_pool_secret` (`kubectl-ate admin make-ca-pool --ca-id=1 --name=session-id-ca-pool`) | Session-ID CA pool consumed by `ate-api-server`. |
| `session-id-jwt-pool` | `ate-system` | `create_jwt_authority_pool_secret` (`kubectl-ate admin make-jwt-pool --key-id=1 --name=session-id-jwt-pool`) | JWT signing keys for session-ID issuance. |
| `valkey-ca-certs` | `ate-system` | `create_valkey_ca_certs_secret` (derived — concatenates `RootCertificateDER` PEMs from the two CA pools above) | `ca.crt` — trust bundle for valkey mTLS. Order-dependent: must be created **after** the two CA-pool secrets exist. |

Phase 2 follow-up: package these as an optional install-time Job (D2-style) that runs `kubectl-ate admin` behind the same `actor.installMode=helm-native` gate, or emit them as chart-owned Secrets from a values-supplied CA / signing bundle. Neither is in-scope for this spike.

Deferred (documented follow-ups):

- **`sandboxconfig-gvisor.yaml` + `sandboxconfig-validation.yaml`** — SandboxConfig CRs (not the CRD schema). Better modeled as chart values that emit a chart-owned SandboxConfig than as raw-vendored manifests.
- **`atenet-router-monitoring.yaml`** — Prometheus PodMonitor. Requires `monitoring.coreos.com` CRDs, which we may or may not have depending on the operator's Prometheus stack. Ship separately behind a `.Values.actor.monitoring.enabled` toggle.
- **`kind/` + `token-client/`** — dev-cluster helpers, not production substrate.
- **Per-resource Helm ownership labels** (`app.kubernetes.io/managed-by`, `app.kubernetes.io/instance` on every substrate resource) — skipped for the spike because upstream resources carry their own `labels:` blocks and drive-by relabelling risks breaking `matchLabels` selectors. Do this via a chart post-render pass in Phase 3.

No manifests were skipped due to unsupported YAML tags — upstream only uses `@env` as plain string content (substrate-runtime substitution), which passes through helm cleanly.

## Design decisions

- **`templates/substrate/` subdirectory** in the main chart rather than a Helm dependency sub-chart under `charts/agent-smith/charts/substrate/`. Sub-chart pattern is heavier — separate Chart.yaml, separate versioning, `helm dependency update` toil. For the spike scope, templates-directory keeps the diff small and the chart layout simple. Sub-chart is a natural follow-up if D3 wins the comparison and we want to publish substrate as an independently versionable artifact.
- **Helm ownership labels** (`app.kubernetes.io/managed-by`, `app.kubernetes.io/instance`) on every substrate resource — makes `kubectl describe` immediately reveal which chart release owns them, prevents SUC-style parallel installs from conflicting.
- **No separate installer SA/RBAC** — Helm's own install-time credentials (whatever ran `helm install/upgrade`) apply the resources. If the operator's Helm is cluster-admin (typical for Flux `HelmRelease`), substrate CRDs install without extra RBAC choreography.

## What this spike does NOT do (yet)

- **SandboxConfig CRs, PodMonitor** — see "Vendored components → Deferred" above.
- **Runtime-crypto Secrets** (`service-dns-ca-pool`, `pod-identity-ca-pool`, `session-id-ca-pool`, `session-id-jwt-pool`, `valkey-ca-certs`) — see "Operator-provisioned Secrets" above. Operator must run substrate's `kubectl-ate admin make-{ca,jwt}-pool` before the HelmRelease reconciles healthy.
- **Substrate CRD ownership decision — final call** — Phase 2 lands them as regular templates with `helm.sh/resource-policy: keep`, which preserves CRs across `helm uninstall`. Alternative (Helm's special `crds/` directory, which never upgrades) is worse for our use case: substrate schemas change pre-1.0 and we want `helm upgrade` to bump them. Revisit if we hit CR-loss scenarios.
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

- [x] `helm template test ./charts/agent-smith --set actor.enabled=true --set actor.installMode=helm-native ...` renders the full substrate control plane. Kind counts (Phase 1 blocker fix — podcertcontroller + valkey vendored): 3 CustomResourceDefinition, 2 Namespace (ate-system + podcertificate-controller-system), 5 Deployment (+ podcertcontroller), 1 DaemonSet, 7 Service (+ valkey-cluster, valkey-cluster-service), 7 ServiceAccount, 5 ClusterRole, 6 ClusterRoleBinding, 3 Role, 3 RoleBinding, 4 ConfigMap (+ valkey-config), 1 PodDisruptionBudget, 2 StatefulSet (+ valkey-cluster), 1 Job (valkey-cluster-init).
- [x] Default rendering (both gates off) does NOT render any substrate resource.
- [x] `installMode=job` case (D2) does NOT render the D3 templates (the two modes are mutually exclusive per the gate check).
- [x] All `ko://…/cmd/<binary>` refs replaced with `ghcr.io/sherodtaylor/substrate/<binary>:{{ .Values.actor.substrateImageTag }}` (verified: `ateapi`, `atecontroller`, `atelet`, `atenet` all present in rendered output).
- [x] All 3 CRDs carry `helm.sh/resource-policy: keep`.
- [ ] Post-merge (chart CI on tag push): renders cleanly against the packaged chart.
- [ ] Phase 3 followup: apply against a live cluster, verify substrate control plane comes up Running under Helm ownership + `helm rollback` rolls it back cleanly. Vendor the deferred components (valkey, pod-certificate-controller, atenet-router-monitoring).
