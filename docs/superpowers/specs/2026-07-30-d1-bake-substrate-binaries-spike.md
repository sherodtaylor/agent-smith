# D1 spike — bake substrate binaries into agent-smith runtime image

**Date:** 2026-07-30
**Status:** spike / draft PR
**Owner:** InfraBot
**Scope:** `sherodtaylor/agent-smith` Dockerfile + build story

## What this spike answers

Question the substrate bundling PRD deferred: *how do agent-smith operators actually get substrate onto their cluster?* The tech-spec (#117) originally recommended Path B — "document `install-ate.sh` as a prereq, chart installs into a substrate that's already there." Sherod flagged that onboarding cost pushes us to reconsider. Three bundling shapes surfaced:

- **D1** (this spike): bake all 6 substrate binaries into the agent-smith runtime image. Single image, multi-entrypoint via `command:` overrides in substrate manifests. Simplest onboarding, tightest coupling to substrate release cadence.
- **D2**: separate `agent-smith-substrate-installer` image (go + ko + kubectl + pinned substrate SHA) — chart auto-runs installer Job when `actor.autoInstall: true`.
- **D3**: pre-resolved substrate manifests as an agent-smith sub-chart — HelmRelease-native lifecycle.

Each spike ships a working install path on the target cluster so Phase 1 measurements happen as a byproduct.

## What this PR ships

- **`Dockerfile`** — new `substrate-builder` stage clones `agent-substrate/substrate` at pinned `SUBSTRATE_SHA` (currently `46adcb8017852fa4e322798828f3b2ea361fc4cf`), builds all 6 substrate binaries with `-trimpath -ldflags="-s -w"`, and copies them + the substrate `manifests/` + `hack/` trees into the runtime image.
- Runtime image now has:
  - `/usr/local/bin/ateapi`
  - `/usr/local/bin/atelet`
  - `/usr/local/bin/atecontroller`
  - `/usr/local/bin/atenet`
  - `/usr/local/bin/ateom-gvisor`
  - `/usr/local/bin/podcertcontroller`
  - `/opt/agent-smith/substrate/manifests/` — the upstream `manifests/ate-install/` tree
  - `/opt/agent-smith/substrate/hack/` — install scripts (for reference; not run in-image)
  - `/opt/agent-smith/substrate/SUBSTRATE_SHA` — the exact commit built

- **Chart-side follow-up (out of scope for THIS spike PR)**: a Kustomize overlay that patches every `manifests/ate-install/*.yaml` to replace `image: ko://github.com/agent-substrate/substrate/cmd/<X>` with `image: {{ .Values.image.repository }}:{{ .Chart.AppVersion }}` + `command: ["/usr/local/bin/<X>"]`. The overlay lives in a follow-up PR under `charts/agent-smith/templates/substrate-d1/` and only renders when `actor.autoInstall: true` AND `actor.installMode: baked` (chart-values choice between D1/D2/D3 modes).

## What this spike does NOT do

- No chart change — chart still emits the same `WorkerPool` + `ActorTemplate` as PR #118. Actor mode still assumes substrate is present; D1's job is to make sure "substrate is present" doesn't require operator toil.
- No install automation — the runtime image just carries the artifacts. The chart-side Kustomize overlay (follow-up PR) is what actually applies substrate to a cluster on operator opt-in.
- No CI changes to the release workflow — existing `docker.yml` builds `ghcr.io/sherodtaylor/agent-smith` on every push; the new substrate-builder stage runs as part of that same build.
- No SUC-plan-style automation of the substrate install. That's D2's shape.

## Tradeoffs (for the D1/D2/D3 comparison)

| Dimension | D1 (this) |
|---|---|
| Image size | ~500 MB larger (6 Go binaries + manifests + hack dir) |
| CI build time | +2-4 min for the substrate-builder stage on cold cache |
| Substrate version coupling | Tight — bumping substrate means rebuilding + retagging agent-smith |
| Chart install UX | `helm upgrade agent-smith --set actor.autoInstall=true` — one flag |
| Manifest customization | Requires the chart-side Kustomize patch (follow-up PR); non-trivial to keep in sync |
| Rollback | Roll back agent-smith image → substrate rolls back too. Atomic. |
| Onboarding path for D2/D3 operators | Doesn't help them; they'd bring their own substrate |

## Verification

- [x] `docker build` locally (or in the existing `docker.yml` workflow) produces an image with all 6 substrate binaries under `/usr/local/bin/`.
- [ ] Follow-up PR (chart-side): `helm template … --set actor.autoInstall=true --set actor.installMode=baked` emits the substrate manifests patched to use the agent-smith image + command overrides.
- [ ] On the eval cluster: `helm install` with actor mode enabled brings up atelet + ate-api-server + atecontroller + atenet + podcertcontroller Running in `ate-system`; `demos/claude-code-multiplex` runs successfully against the D1-installed substrate.

The last box is where Phase 1's compat + latency numbers come from. D2 + D3 each produce their own numbers on separate installs so we can compare install-UX side-by-side in the verdict paragraph.
