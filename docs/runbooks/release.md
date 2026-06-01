# Runbook: Cut a release

Use when you're shipping a new version of the image **and** chart. A
maintenance branch / hotfix follows the same flow with a patch bump.

## Workflow: PR → release (agent responsibility)

When an agent opens or merges a PR to this repo, the release is part of the
same task — not a follow-up. The expected flow after a PR merges to `main`:

1. **Check CI** — `gh run list --repo sherodtaylor/agent-smith --limit 3` to
   confirm the post-merge log job finished.
2. **Cut the release** — run steps 1–3 below immediately; don't wait to be
   asked. Use `GH_TOKEN=proxy-token-github SSL_CERT_FILE="${HOME}/iron-proxy.crt"` prefix for all reference scripts.
3. **Wait for CI, then bump homelab** — steps 5–6 below. Flux reconciles
   automatically; no manual cluster intervention needed.
4. **Report in `#infra`** — post the new version and a verify command.

This applies to every merged PR, including patches. If you merged the PR, you
own the release cut.

## Reference scripts

Scripts in [`.claude/references/`](../../.claude/references/README.md) cover
the repeatable steps:

```bash
.claude/references/compare-since-tag.sh           # step 1
.claude/references/cut-release.sh --help          # step 3
.claude/references/check-release.sh --help        # step 5
.claude/references/bump-homelab-chart.sh --help   # step 6
```

## Preconditions

- All PRs intended for this release are merged into `main`.
- Local `main` is up-to-date, or you're working via the GitHub API.
- `CHANGELOG.md` has an `[Unreleased]` section listing the changes (or you'll
  populate one in step 2).
- `GH_TOKEN` set in env or `~/.config/gh/hosts.yml` present (reference scripts
  resolve it automatically).

## Steps

### 1. Pick the version

Semver. Read the merged PRs since the last tag and pick:

- **Patch** (`vX.Y.Z+1`) — bug fix, doc, internal refactor, no behaviour
  change for consumers.
- **Minor** (`vX.Y+1.0`) — new feature, new Helm value, anything additive.
- **Major** (`vX+1.0.0`) — breaking change to values, env vars, or expected
  cluster shape.

```bash
.claude/references/compare-since-tag.sh
```

### 2. Update CHANGELOG.md

Move everything under `[Unreleased]` into a new `[X.Y.Z] - YYYY-MM-DD`
section. Keep `[Unreleased]` as an empty stub. Commit on `main` (or via PR)
**before** tagging — the GitHub Release body is copied from this section.

### 2b. Update the website for user-visible changes

If anything in this release changes what an operator or end user sees —
new chart values, persona shifts, agent roster changes, new flags, runtime
behavior changes — update `website/src/` before tagging:

- `website/src/pages/index.astro` — hero copy, capabilities list, "ls crew".
- `website/src/components/MeetTheCrew.astro` + `website/src/data/crew-status.json`
  — agent roster.
- `website/src/content/docs/*.md` — Starlight docs (getting-started,
  deployment, agents, security, operations, architecture).

The PR-canary GH Pages preview (workflow at
`.github/workflows/website-preview.yml`) builds + publishes the site to
`https://sherodtaylor.github.io/agent-smith/pr-<N>/` on every PR that
touches `website/**`, so reviewers can see drift before merge.

The runbook order is intentional: CHANGELOG and website land together so
the tag, the GitHub Release body, and the public site never drift more
than one PR apart.

### 3. Tag and create the GitHub Release

```bash
.claude/references/cut-release.sh --version vX.Y.Z --message "one-line summary" --dry-run
# Review dry-run output, then:
.claude/references/cut-release.sh --version vX.Y.Z --message "one-line summary"
```

The script creates the annotated tag and GitHub Release in one shot. CI picks
up the tag and publishes the image + chart automatically.

### 5. Wait for CI and verify artifacts

```bash
gh run watch --repo sherodtaylor/agent-smith   # or watch GitHub Actions in browser
.claude/references/check-release.sh --version X.Y.Z
```

`check-release.sh` verifies all four artifacts: git tag, GitHub Release,
container image, and Helm chart OCI artifact.

### 6. Bump the consuming HelmReleases

```bash
.claude/references/bump-homelab-chart.sh --version X.Y.Z --dry-run
# Review, then:
.claude/references/bump-homelab-chart.sh --version X.Y.Z
```

Updates every `*-helmrelease.yaml` that references `chart: agent-smith` in
`sherodtaylor/homelab/k8s/apps/agents/` via the GitHub API. Flux reconciles
on the next poll.

### 7. Verify in the cluster

```bash
flux reconcile helmrelease devbot   -n agents
flux reconcile helmrelease infrabot -n agents

kubectl get helmrelease -n agents
kubectl get pods -n agents -w
```

Both pods should roll, come up Ready, and post the next acknowledged 👀
reaction in Matrix on the next message you send them. Test with a tag in
`#dev`:

```
@devbot @infrabot ping — confirming you're on vX.Y.Z
```

## Rollback

If something is wrong post-tag:

- **Image is broken but `:latest` already moved.** Pin the consumers to the
  previous specific version (`vX.Y.Z-1`) by bumping the HelmReleases to that.
  `:latest` itself can't be unmoved without re-tagging.
- **Chart is broken but image is fine.** Re-pin consumers to the previous
  chart version; the image they already have stays good.
- **Both broken.** Pin consumers to `vX.Y.Z-1` for both, then publish a
  `vX.Y.Z+1` with the fix.

`git tag -d vX.Y.Z` + `git push --delete origin vX.Y.Z` is **possible** but
discouraged — published Helm OCI artifacts at that version are immutable, and
having the tag removed leaves an orphaned chart.

## Verify the release end-to-end

```bash
.claude/references/check-release.sh --version X.Y.Z
kubectl get helmrelease -n agents -o jsonpath='{range .items[*]}{.metadata.name}={.spec.chart.spec.version}{"\n"}{end}'
```

All should report `X.Y.Z`. If one disagrees, that's the layer to fix.

## Why this works

Tags are the **only** trigger for the chart job (see `.github/workflows/docker.yml`,
`if: startsWith(github.ref, 'refs/tags/v')`). Pushes to `main` never publish
a chart and never move `:latest`. The chart version is derived from the tag
name (`GITHUB_REF_NAME#v`), so the chart and image are always at the same
version — you can't release one without the other.

## Staged release (per-agent canary)

For `v0.2.0+` charts using the `agents: [...]` array shape, you can roll
a single agent onto a new image tag while the rest of the fleet stays
on the current tag — useful for surface-area changes (`setup.sh`, new
chart template logic, plugin reconciler edits) where you want one
agent to prove out before the others follow.

### Steps

1. Cut the release as usual (`cut-release.sh --version vX.Y.Z`). CI
   publishes the new image + chart.
2. In `k8s/apps/agents/agent-smith-fleet-helmrelease.yaml`, set
   `agents[i].image.tag` on ONE agent (canonically `devbot` first) to
   the new image tag. Leave the rest of the array entries without an
   image override — they keep using the fleet-wide `.image.tag`.
3. Flux reconciles → only that one agent's StatefulSet template
   changes → only its pod rolls. Other agents stay pinned to the
   previous tag.
4. Observe ~24h. Verify the canary agent's setup completes cleanly,
   the plugin reconciler runs, Matrix sync works, no regressions in
   normal operations.
5. **Promote**: remove the `image.tag` override from the canary
   entry; the agent rolls onto the fleet default (still the previous
   tag at this point).
6. Bump the fleet-wide `.image.tag` to the new version. All remaining
   agents roll. Canary agent stays as-is (already on the new tag).

### Rollback

Delete the `image.tag` override from the canary agent. Its
StatefulSet template changes → pod rolls back to the fleet default
(the previous tag). No data loss; PVCs are preserved across the
roll.

### Persona canary

The same pattern works for persona changes via `configMapRef`:

1. Create a new operator-supplied ConfigMap (e.g. `infrabot-persona-v4`)
   alongside the existing `infrabot-persona-v3`.
2. Set `agents[i].configMapRef: infrabot-persona-v4` on one agent.
3. Observe; promote by pointing the rest of the fleet at v4.

Rollback: re-point at `infrabot-persona-v3`.
