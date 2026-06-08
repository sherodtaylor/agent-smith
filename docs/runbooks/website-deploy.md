# Runbook: Deploy the website

The site at `https://sherodtaylor.github.io/agent-smith/` is built and
published by `.github/workflows/website.yml`. This runbook covers what
triggers a deploy, how to set Pages up the first time, the failure modes
we've seen, and the custom-domain swap when we're ready for it.

Source-of-truth README for the site itself:
[`website/README.md`](../../website/README.md).

## Trigger

`website.yml` runs on push to `main` that touches any of:

- `website/**` — site source (components, content, scripts, config)
- `docs/**` — runbook MDX is pulled into the docs sidebar
- `README.md` — homepage cards link to it
- `.github/workflows/website.yml` — the workflow itself

A push that only changes `agents/` or `charts/` does **not** trigger a
deploy — the site doesn't surface that content.

## First-time setup

One-time, per repo. Skip if Pages is already serving the site.

1. Repo Settings → Pages → **Source = Deploy from a branch**,
   **Branch = `gh-pages` / `/` (root)**. The deploy workflow uses
   `peaceiris/actions-gh-pages` which writes the built site to the
   `gh-pages` branch; Pages needs to be reading from that branch or
   nothing ever publishes.

   **If you see `build_type: workflow` in `GET /repos/.../pages`**, the
   source is wrong — Pages is waiting for `actions/deploy-pages` artifacts
   we don't produce. Fix with:

   ```bash
   curl -X PUT \
     -H "Authorization: token $GH_TOKEN" \
     -H "Accept: application/vnd.github+json" \
     https://api.github.com/repos/sherodtaylor/agent-smith/pages \
     -d '{"build_type":"legacy","source":{"branch":"gh-pages","path":"/"}}'
   curl -X POST \
     -H "Authorization: token $GH_TOKEN" \
     https://api.github.com/repos/sherodtaylor/agent-smith/pages/builds
   ```

   The "Verify production URL is reachable" step in `website.yml` catches
   this misconfig instantly — without it, gh-pages pushes succeed but
   the live URL stays stale and the workflow reports green.

2. Branch protection on `main` is unchanged — the workflow runs after merge,
   not on the PR.
3. First push of `website.yml` will run the workflow and provision the
   `gh-pages` branch. The first deploy takes ~3 min; subsequent
   deploys are ~90 s.

## Pushing the branch the first time

The `website.yml`, `lighthouse.yml`, and `log-pr-merge.yml` workflows must
be pushed from a host whose PAT has the `workflow` scope. The default
DevBot PAT in iron-proxy does **not**. Either push from Sherod's machine
or regrade the bot PAT before any workflow change ships.

If the push is rejected with `refusing to allow a Personal Access Token to
create or update workflow ".github/workflows/website.yml" without "workflow"
scope`, this is the cause — not a branch-protection rule.

## Failure modes

### Build fails on `refresh-crew-status.ts`

Symptom: workflow log shows `GraphQL: Resource not accessible by integration`
or `403` against the GitHub API during the build step.

Cause: the workflow's `GITHUB_TOKEN` doesn't have the scopes the script
needs to read repo metadata and recent activity.

Fix: in `.github/workflows/website.yml`, ensure the build job has:

```yaml
permissions:
  contents: read
  metadata: read
```

If a different repo/org is added as a data source, the token won't span
it — switch that one source to a PAT secret (`CREW_STATUS_TOKEN`) and
reference it explicitly in the step env.

### Lighthouse perf budget fails

Symptom: `lighthouse.yml` red, summary shows performance score below the
threshold in `lighthouserc.json`.

Cause: a new asset (image, font, JS chunk) blew the budget. Most common
offender is a hero image that wasn't run through `astro:assets` and shipped
at its native resolution.

Fix:
- `bun run build && bun run lhci` locally to reproduce.
- Inspect the report — look for largest contentful paint and total blocking
  time. The culprit is usually one specific asset.
- Trim CSS/JS or kill the offending asset. If a Lottie is the cause, see
  the next failure mode.

### Lottie payload over 60 KB

Symptom: a `.lottie` or `.json` animation in `website/public/lotties/`
ships >60 KB compressed; perf budget red.

Fix:
- Re-export from After Effects with the LottieFiles plugin set to "Compact"
  + drop unused layers.
- Or drop one of the three site animations — three is the ceiling we agreed
  on in the spec. If a fourth is genuinely needed, retire one first.

## Custom domain swap

Site-side steps live in
[`website/README.md`](../../website/README.md#custom-domain-swap-when-ready).
This runbook handles the cluster + DNS side when we're ready.

After completing the README's four steps:

- Update any external references (NATS event payloads, audit posts, the
  homelab repo's app catalog) from `sherodtaylor.github.io/agent-smith`
  to the new origin.
- Verify the `og:url` and `canonical` tags in `Layout.astro` resolved to
  the new origin (`curl -s https://<new-domain>/ | grep -E 'og:url|canonical'`).
- If a redirect from the old GitHub Pages URL is desired, add a `_redirects`
  equivalent — Pages doesn't natively support redirects, so the cleanest
  option is a one-page `index.html` with a `<meta http-equiv="refresh">`
  pushed to a `gh-pages-legacy` branch served from the old URL.
