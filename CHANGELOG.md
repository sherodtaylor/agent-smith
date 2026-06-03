# Changelog

All notable changes to `agent-smith` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Every release publishes:

- Container image: `ghcr.io/sherodtaylor/agent-smith:vX.Y.Z` (and `:vX.Y`,
  `:vX`, `:latest`)
- Helm chart: `oci://ghcr.io/sherodtaylor/charts/agent-smith:X.Y.Z` plus the
  `.tgz` attached to the GitHub Release.

See [`docs/runbooks/release.md`](docs/runbooks/release.md) for the
cut-a-release procedure.

---

## [Unreleased]

---

## [0.2.17] - 2026-06-03

### Fixed

- **`scripts/entrypoint.sh`: iron-proxy CA was not installed in the
  main container's system trust store.** `setup.sh` runs
  `update-ca-certificates` in the init container, but that filesystem
  doesn't carry over to the agent main container — so anything in the
  main container that depends on `/etc/ssl/certs/ca-certificates.crt`
  (Go's `http.DefaultClient`, curl, wget, Python) failed TLS
  verification against `matrix.lab.sherodtaylor.dev`. Concrete impact:
  `cmd/claude-reauth/main.go`'s `matrixDM()` / `ensureDMRoom()` died
  with `x509: certificate signed by unknown authority` whenever a bot
  hit expired tokens, leaving the reauth web UI running but with no
  operator DM — bots silently waited for someone to notice. The
  Bun/Node matrix-channel plugin was unaffected because it reads
  `NODE_EXTRA_CA_CERTS`. `entrypoint.sh` now writes
  `IRON_PROXY_CA_CRT` to `/usr/local/share/ca-certificates/` and runs
  `update-ca-certificates` again at main-container startup.

---

## [0.2.16] - 2026-06-02

### Fixed

- **Chart: agent main container was missing `MATRIX_HOMESERVER_URL`,
  `MATRIX_BOT_USER_ID`, `MATRIX_ALLOWED_USERS`.** These env vars were
  set on the `setup` init container only (statefulset.yaml:53-67), not
  on the `agent` main container — so `claude-reauth`'s `matrixDM()`
  (which reads `os.Getenv` directly) hit "Matrix not configured — DM
  skipped" even when Matrix was fully working. The matrix-channel
  plugin itself didn't notice because it reads from
  `~/.claude/channels/matrix/.env` (which `setup.sh` writes from the
  init container's env), so typing indicators + replies in rooms kept
  working, masking the chart bug. claude-reauth's "wake the operator
  with a DM" path was the only thing that needed the env vars
  directly — and it didn't have them.

  Fix: mirror the same MATRIX_* env block onto the `agent` container.
  No new chart value; same sourcing logic as the setup container
  (per-agent `matrix.*` override over the fleet-wide `matrix.*`
  default).

---

## [0.2.15] - 2026-06-02

### Fixed

- **`claude-loop.sh` `_ensure_auth` no longer short-circuits on
  `claude auth status` before reaching `claude-reauth`.** Previous
  shape: check stub token → check `claude auth status` exit code →
  only run `claude-reauth` if status non-zero. But `claude auth
  status` exits 0 for any well-formed local credentials file, including
  ones Anthropic has expired and is 401-ing on the wire. So an agent
  whose token had gone stale (typical for infrabot in this fleet) hit
  401s in every API call but `_ensure_auth` returned happy without
  calling `claude-reauth` — meaning the API-probe gate (added in
  v0.2.14) inside `claude-reauth` never ran, so the reauth + Matrix DM
  flow never fired. Now `_ensure_auth` always invokes `claude-reauth`;
  `claude-reauth`'s own three-gate check (isLoggedIn + credsAreReal +
  credsAreActive) is authoritative. Probe cost on the happy path is
  one HTTP request (~200ms).

---

## [0.2.14] - 2026-06-01

### Changed

- **`claude-reauth` human-fallback timeout is now configurable and the
  default is 30m (was 10m).** The 10m window was inherited from the
  ttyd era where the operator was expected to already have the tab
  open. With the web-UI fallback the operator typically navigates to
  the URL from a DM / Matrix link, so a tighter window made the form
  go HTTP 502 (claude-reauth had exited, http server shut down) by
  the time the operator reached it. Set via the new
  `REAUTH_HUMAN_TIMEOUT` env var (Go duration: `"15m"`, `"1h"`).
  Invalid values log a warning and fall back to 30m.
  **`REAUTH_HUMAN_TIMEOUT=0`** disables the timeout entirely — the
  web form stays up until creds arrive or the process is killed.
  Useful for fresh agents whose own Matrix DM path isn't yet
  configured (chicken-and-egg: bot can't DM the operator the auth URL
  because it doesn't yet have working Matrix credentials).

---

## [0.2.13] - 2026-05-31

### Changed

- **`claude-reauth` human fallback is now a single-purpose web form, not
  a shell.** When SSO cookies are cold and a human is needed, the binary
  serves a one-page HTML form on port 7681. The form shows the OAuth
  authorize URL and accepts one input — the callback code — which is
  piped to `claude auth login --claudeai`'s stdin. No shell access is
  exposed; even on an unauthenticated ingress the attack surface is "one
  form field that takes an OAuth code." The legacy ttyd shell remains
  available behind `REAUTH_MODE=ttyd` for emergency recovery.

### Fixed

- **`claude-reauth` stdin pipe set up post-Start was silently nil.**
  `cmd.StdinPipe()` returns an error after `cmd.Start()`, so the
  headless-success path's stdin-write was writing to nil (would have
  panicked if reached). `spawnAuthLogin` now wires `StdinPipe`
  before `Start` and returns the writer alongside the cmd. The
  headless path and the new web UI fallback both reuse it.

---

## [0.2.12] - 2026-05-31

### Fixed

- **`claude-reauth` ttyd readonly mode** — ttyd was started without `--writable`,
  making the browser terminal read-only and preventing the user from pasting
  the OAuth code to complete `claude auth login`.

---

## [0.2.11] - 2026-05-31

### Fixed

- **`claude-reauth` stub credential gate** — `claude auth status` (used by
  `isLoggedIn()`) exits 0 for well-formed stub credentials, so the binary
  would exit early with "already authenticated" even on a fresh pod. Now
  requires both `isLoggedIn()` and `credsAreReal()` before skipping reauth.
  `credsAreReal()` already existed and checked for stub tokens but was only
  used in the human-fallback polling loop.

---

## [0.2.10] - 2026-05-31

### Fixed

- **`claude-loop.sh` stub detection** — `claude auth status` returns exit 0
  for well-formed stub credentials, so `_ensure_auth` never called
  `claude-reauth` on new pods. Now checks `accessToken` directly; if it equals
  `"access-token-stub"` it triggers `claude-reauth` immediately, so bots
  bootstrapped without real tokens on their PVC authenticate automatically
  instead of hitting the iron-proxy shared-token swap path.

---

## [0.2.9] - 2026-05-30

### Added

- **`matrix.autoJoinRooms`** chart value (global or per-agent list of room
  aliases/IDs). `setup.sh` now joins each listed room at pod start via
  `POST /_matrix/client/v3/join/{alias}`. Idempotent; failures are logged and
  do not block boot. Eliminates the manual `/invite` step for new bot accounts.

---

## [0.2.8] - 2026-05-30

Patch release. Image-only change — chart templates unchanged from 0.2.7.

### Fixed

- **`scripts/setup.sh`: `mkdir -p ~/.claude` before credential copy on
  fresh PVC.** On a brand-new home PVC (e.g. a freshly-deployed agent
  like pmbot-0), the `cp` of `agents/_shared/.credentials.json` into
  `~/.claude/.credentials.json` failed because the parent directory
  didn't exist yet. Existing pods (devbot, infrabot) survived because
  their PVCs already had the directory from prior runs. Added an
  idempotent `mkdir -p "${CLAUDE_DIR}"` after the iron-proxy CA
  install and before any reads/writes into `~/.claude/`.
  ([#80](https://github.com/sherodtaylor/agent-smith/pull/80))

### Deploy story

Tagging the release pre-emptively (CHANGELOG entry landed
post-tag); the tag was cut to unblock pmbot bootstrap. The
`v0.2.8` tag's GitHub Release body does not include this section
because the runbook's "CHANGELOG-before-tag" order was reversed —
follow-up cleanup, no functional impact.

---

## [0.2.7] - 2026-05-29

Minor release. Chart-only change — adds pmbot (product manager agent)
as a bundled example persona and extends the shared agent base with
"Working with pmbot" guidance + the mandatory-response rule.

### Added

- **`charts/agent-smith/agents/example-pmbot/`** — bundled example
  persona for a product-manager agent, mirroring the
  `example-devbot` / `example-infrabot` pattern. Operators override
  with their own pmbot persona via `configMapRef` in HelmRelease
  values. ([#78](https://github.com/sherodtaylor/agent-smith/pull/78))
- **`charts/agent-smith/agents/_shared/CLAUDE.md` "Working with
  pmbot" section** — teaches implementation agents
  (devbot/infrabot/etc.) how to coordinate with a product-manager
  agent. Captures who owns what (PRDs/roadmap/vision = pmbot;
  implementation = the other agents; adjudication = operator), when
  to summon pmbot, when NOT to summon, mention forms, and the
  cross-agent PR-review extension. Generic across PM-agent
  personas; operators may override per their own variant.
- **Mandatory-response rule** — when pmbot leaves a finding on a PR
  or addresses an implementation agent in `#dev` / `#infra`, the
  agent must respond before the next merge/escalation point. Three
  valid responses: push a fix, reply with rationale, or escalate to
  the operator. **Silent ignore is not allowed.** This is the
  social contract that makes pmbot's authority real without a
  GH-level veto.

### Deploy story

This release is the chart-side surface from homelab spec
`docs/superpowers/specs/2026-05-28-pmbot-agent-design.md`. After
tagging v0.2.7 and CI publishing the new chart, homelab Phase B
(plan #47) lands the cluster manifests — ExternalSecret, persona
ConfigMap, RBAC, fleet HR `agents[]` entry pinning chart to 0.2.7.
Phase C (Sherod-manual) creates the `@pmbot:lab.sherodtaylor.dev`
Matrix account and stores its token in Infisical at
`SWARM_MATRIX_BOT_TOKEN_PMBOT`.

---

## [0.2.6] - 2026-05-28

Patch release. Image-only change — chart templates unchanged from 0.2.5.

### Changed

- **`scripts/reconcile-plugins.sh` now always uninstalls + reinstalls every
  enabled plugin on each invocation.** Claude Code's `enabledPlugins`
  schema only accepts `true`/`false` — there is no settings-level way
  to pin GitHub-source plugins to a specific version, so an install of
  e.g. `matrix@claude-code-channel-matrix` would stick at the cached
  version forever, even after the marketplace published a fix. With
  this change a pod bounce becomes the deploy mechanism for upstream
  plugin updates: each bounce wipes the cached install and pulls
  whatever's at HEAD of the marketplace.

  Safety: if a marketplace's `add` or `update` call fails in Phase 1
  (network blip), Phase 2 skips reinstall for any plugin sourced from
  that marketplace, preserving the cached install. The pod never
  boots with no plugin at all due to a transient registry outage.

  Trade-off: every enabled plugin (including `superpowers`) reinstalls
  on every bounce. The extra round-trip is the cost of avoiding a
  parallel pin schema Claude Code doesn't honor. Per-plugin opt-out
  can be added later if startup time grows uncomfortably.

  ([#75](https://github.com/sherodtaylor/agent-smith/pull/75))

### Deploy story

This release unblocks rollout of `matrix@claude-code-channel-matrix`
v0.7.1, which carries three upstream fixes that pods on v0.2.5 cannot
pick up:

- `reply` / `react` tools now echo the message body / event_id in their
  MCP result (so Claude Code mobile renders the sent content instead of
  bare `"sent"` /  `"reacted"`).
- Typing indicator only fires when the inbound message targets this
  bot — silent on messages aimed at other agents in the room.
- Outbound bot replies use `msgtype: m.text` (was `m.notice`), which
  client-side notice filters in some Matrix clients had been
  suppressing. Bot loop prevention is already handled by the existing
  `shouldForwardEvent` gate, so the spec rationale for `m.notice`
  doesn't apply here.

After upgrading the HelmRelease to 0.2.6, the next pod bounce will
reinstall the matrix plugin from the marketplace and pick up 0.7.1
automatically.

---

## [0.2.5] - 2026-05-28

Patch release. Image-only change — chart templates unchanged from 0.2.4.

### Fixed

- **`agents/_shared/settings.json` `enabledPlugins` schema**: values used
  `{ "version": "x.y.z" }` form which Claude CLI rejects as "Invalid
  input" — agent refuses to start with the file in place. Changed to
  plain boolean `true`, matching Claude CLI's own generated format.
  `reconcile-plugins.sh` already handled both shapes; with `true` it
  falls into the "install-if-missing, skip drift" branch (versions
  float to latest at install time, persist on the home PVC across
  restarts). ([#72](https://github.com/sherodtaylor/agent-smith/pull/72))

---

## [0.2.4] - 2026-05-28

Republish of 0.2.3 — no source changes. The 0.2.3 OCI tag was force-moved
to roll the chart `MATRIX_HOMESERVER_URL` fix into the same release; Flux
source-controller with `reconcileStrategy: ChartVersion` cached the
pre-force-move 0.2.3 artifact and never re-pulled the new digest, so the
fleet HR still rendered the broken chart. Cutting 0.2.4 sidesteps that
cache by changing the version string. No code or template changes from
0.2.3 (post force-move) — consult the [0.2.3] entry for the actual
fixes.

---

## [0.2.3] - 2026-05-28

Patch release. Unblocks every v0.2.x fleet deployment by fixing two init
regressions introduced by the 0.2.0 chart refactor, and ships the
previously-prepped 0.2.2 features in the same cut.

### Fixed

- **`scripts/setup.sh` guard**: the upfront FATAL check required the legacy
  baked `${APP_DIR}/agents/${AGENT_NAME}` directory and crashed before the
  v0.2.0 ConfigMap-fallback ever ran. Every v0.2.x deploy using the persona
  CM hit `[setup] FATAL: no AgentConfig at /opt/agent-smith/agents/<name>`
  even when the persona CM was mounted correctly. Guard now passes when
  **either** `${PERSONA_DIR}/CLAUDE.md` is mounted or the legacy `AGENT_DIR`
  exists. `mcp.json` legacy fallback also guarded with `-f` so persona CMs
  that omit `mcp.json` don't crash. ([#67](https://github.com/sherodtaylor/agent-smith/pull/67))
- **Chart `MATRIX_HOMESERVER_URL` env wiring**: the v0.2.0 refactor lost the
  StatefulSet env entry for `MATRIX_HOMESERVER_URL`, so `setup.sh` crashed
  past the previous fix at line 107 with `MATRIX_HOMESERVER_URL: unbound
  variable`. Chart now emits the env from per-agent
  `agents[].matrix.homeserverUrl` with fallback to the top-level
  `.Values.matrix.homeserverUrl` (one fleet = one homeserver). Block is
  skipped entirely when neither is set so legacy envFrom-only installs keep
  working. ([#69](https://github.com/sherodtaylor/agent-smith/pull/69))

### Added

- Quiet hours / DND mode — operator can `/dnd on [until HH:MM]` on Matrix or
  set `quietHours.window` in chart values to schedule a recurring window.
  In DND, replies suppress (or edit_message-route through the matrix-channel
  fork) and a single rollup posts at window-end. `kind=incident/blocked`
  overrides. Spec: docs/superpowers/specs/2026-05-28-platform-branding-design.md §11.
- Pixel-sprite crew portraits (DevBot, InfraBot) with active/vacation/error
  state variants. Rendered in README, website hero status, /log, MeetTheCrew.
- **`serviceAccount.create` value** — when `false`, the chart skips
  per-agent ServiceAccount emission. Required for consumers (homelab)
  that manage their own ServiceAccounts via a separate Kustomize
  manifest. Default `true` for stand-alone installs. Pairs with the
  existing `rbac.create: false` to fully delegate SA + RBAC to an
  external system; the StatefulSet still references the externally-
  owned SA by name (`serviceAccountName: {{ .agent.name }}`).

### Test coverage

- `tests/test-chart-render.sh`: new case "serviceAccount.create=false"
  pins the contract (zero SAs/CRs/CRBs emitted; StatefulSet still
  references the named SA). Suite at 33 passes.

---

## [0.2.0] - 2026-05-28

Major chart refactor ([#59](https://github.com/sherodtaylor/agent-smith/pull/59)).
One Helm release can now deploy N agents from a values-side array;
persona content moves from baked-into-image to mounted ConfigMaps;
each agent has independent staging knobs for canary rolls.

### Added

- **Chart `agents: [...]` array shape** — one HelmRelease can now
  deploy N agents from a values-side array. Replaces the prior
  one-HelmRelease-per-agent model. Adding an agent goes from
  duplicating a HelmRelease + editing 4 fields, to appending one
  array entry.
- **Per-agent persona via mounted ConfigMaps** — `CLAUDE.md` +
  `mcp.json` no longer need to be baked into the image. Hybrid
  sourcing: the chart renders a default ConfigMap from bundled
  `charts/agent-smith/agents/<name>/` content; agents set
  `configMapRef: <name>` to override with an operator-supplied
  ConfigMap. Persona iteration drops from ~5–10 min (image rebuild
  + chart release + Flux reconcile + pod roll) to ~90 s
  (ConfigMap edit + Flux reconcile + pod restart).
- **Per-agent staging knobs** — each agent entry accepts an optional
  `image.tag` (defaults to fleet-wide `.image.tag`) and
  `configMapRef` (defaults to chart-rendered persona CM). Canary
  one agent on a new image or persona without splitting the fleet
  across HelmReleases. See `docs/runbooks/release.md` —
  "Staged release (per-agent canary)" section.
- **Shared `agent-smith-shared` ConfigMap** — one instance regardless
  of agent count; carries cross-cutting `_shared/CLAUDE.md` content
  that `setup.sh` concatenates with the per-agent persona.
- **Bundled example personas** — `charts/agent-smith/agents/example-infrabot/`
  and `charts/agent-smith/agents/example-devbot/` ship as
  cluster-agnostic templates for users adopting the chart. Production
  operators replace via per-agent `configMapRef` pointing at their
  own ConfigMaps; the bundled examples are documentation, not
  deployable content.
- **`tests/test-chart-render.sh`** — bash + helm + grep smoke harness
  covering 11 cases (29 assertions): single-agent, two-agent fan-out,
  RBAC fan-out, reauth on/off, persona CM rendering, configMapRef
  override, checksum annotations, legacy shim, both-set error,
  empty error, image.tag override + fallback. Runs offline.

### Changed

- **`charts/agent-smith/values.yaml`** — top-level `agentName`,
  `existingSecret`, `matrix`, `agentRepos`, `primaryRepo`,
  `serviceAccount` removed. Per-agent equivalents move into
  `agents[].*`. Top-level still has `image`, `persistence`,
  `resources`, `ironProxy`, `rbac`, `setup`, `reauth`, `extraEnv`,
  scheduling knobs.
- **`scripts/setup.sh`** — reads `CLAUDE.md` + `mcp.json` from
  `/etc/agent-smith/{shared,persona}/` mount paths when present;
  falls back to baked-in `/opt/agent-smith/agents/<name>/` paths
  when the volumes aren't mounted (older chart versions).
- **Chart templates** — `statefulset.yaml`, `serviceaccount.yaml`,
  `rbac.yaml`, `service-reauth.yaml`, `ingress-reauth.yaml` all wrap
  their resources in `{{- range .Values.agents }}`. ClusterRole
  becomes a singleton (`agent-smith-base`); N per-agent
  ClusterRoleBindings.
- **`docs/architecture.md`** — new "Helm chart shape (v0.2.0+)"
  section describing the fan-out + shared resources + staging knobs.
- **`docs/runbooks/adding-agent.md`** — rewritten for the array
  shape: six-step procedure (Infisical secret → ExternalSecret →
  persona (bundled or operator-supplied) → append to fleet HelmRelease
  → PR → verify).
- **`docs/runbooks/release.md`** — new "Staged release (per-agent
  canary)" section: image.tag override for binary canary,
  `configMapRef` override for persona canary, rollback by removing
  the override.

### Removed

- **Top-level `agents/infrabot/` and `agents/devbot/`** — Sherod's
  operator-specific persona content stripped from the public chart
  repo. Production personas now live in operator-side ConfigMap
  manifests referenced via `configMapRef`. The chart ships only
  generic `example-*` personas.

### Deprecated

- **Top-level single-agent shape** (`agentName: foo` + sibling
  fields). The chart accepts it during `v0.2.x` and `v0.3.x` via a
  synthetic one-element array constructed by
  `agent-smith.agentList`. Removed in `v0.4.0`. Migrate to
  `agents: [{name: foo, ...}]`.

### Migration

Consumer-side migration (homelab) ships in a follow-up PR. Two-phase
rollout preserves PVC identity because the StatefulSet
`metadata.name` stays `<agent-name>` (no release-name prefix), so
existing `home-<agent>-0` + `workspace-<agent>-0` PVCs transfer
transparently between the per-HR-per-agent shape and the new fleet
HelmRelease.

1. **Phase 1 (canary)**: new fleet HelmRelease with `agents: [{name: devbot, ...}]`;
   suspend old `devbot-helmrelease.yaml`. Observe ~24 h.
2. **Phase 2 (full)**: append `infrabot` to the fleet array; suspend
   old `infrabot-helmrelease.yaml`. Observe.
3. **Cleanup**: delete both suspended legacy HelmReleases after the
   fleet is stable.

**Rollback at either phase**: re-enable the suspended legacy
HelmRelease.

---

## [0.1.24] - 2026-05-28

### Added

- **Declarative plugin reconciler** ([#54](https://github.com/sherodtaylor/agent-smith/pull/54)) —
  `agents/_shared/settings.json.enabledPlugins` is now the source of
  truth for plugin versions (value shape: `{ "version": "X.Y.Z" }`,
  with plain `true` still accepted as "install-if-missing, no version
  pin"). A new `scripts/reconcile-plugins.sh` runs on every pod boot,
  refreshes marketplaces, and converges installed plugins via
  `claude plugin marketplace update` + `uninstall` + `install` on drift.
  Replaces the prior imperative `claude plugin marketplace add` +
  `claude plugin install` lines in `setup.sh`, which were
  idempotent-no-upgrade and pinned pods to whatever version was first
  installed.
- **`tests/test-reconcile.sh`** — six smoke cases (13 assertions)
  against a PATH-shimmed `claude` mock; runs offline.

### Changed

- **`agents/_shared/settings.json`** — `enabledPlugins` values upgraded
  from `true` to `{ "version": "X.Y.Z" }` for both `matrix@…` (0.7.0)
  and `superpowers@…` (5.1.0). Lets the reconciler enforce drift checks
  against the declared pins.
- **`scripts/setup.sh`** — the marketplace-add + plugin-install block
  (formerly lines 73-80) is now a single
  `bash "${APP_DIR}/scripts/reconcile-plugins.sh"` invocation.

---

## [0.1.23] - 2026-05-27

### Changed

- **Matrix channel plugin source temporarily flipped to `sherodtaylor` fork** ([#47](https://github.com/sherodtaylor/agent-smith/pull/47)):
  `scripts/setup.sh` and `agents/_shared/settings.json` now install
  `claude-code-channel-matrix` from `sherodtaylor/claude-code-channel-matrix`
  instead of upstream `zekker6`. The fork carries new tools shipped in
  [sherodtaylor/claude-code-channel-matrix#1](https://github.com/sherodtaylor/claude-code-channel-matrix/pull/1):
  per-call threading via `reply_to_event_id`, an `edit_message` tool
  for in-place progress updates that don't push-notify, and auto-typing
  on inbound (default on, set `MATRIX_TYPING=false` to disable).
  Reverts to upstream after the three additive PRs land in `zekker6`
  and a tagged release ships.

---

## [0.1.22] - 2026-05-27

### Added

- **`cmd/claude-reauth/` (Go binary → `/usr/local/bin/claude-reauth`)** —
  Claude auth self-healing as a static Go binary. Uses `chromedp` (native Go
  CDP library) to drive Chromium headlessly with a persistent user-data-dir
  (`~/.chrome-profile` on the home PVC). If the SSO session completes
  automatically (cookies warm) it scrapes the OAuth callback code and feeds it
  to the `claude auth login` subprocess stdin. If SSO is cold, it starts a
  `ttyd` browser terminal at `<agentName>-shell.<hostSuffix>` and DMs the
  Matrix owner. Auth check uses `claude auth status` exit code (0 = logged in,
  1 = not) — no JSON parsing. `REAUTH_EMAIL` pre-fills the email field to skip
  that step in the browser. No Python, no Playwright.
- **`charts/agent-smith/templates/service-reauth.yaml`** — ClusterIP Service
  for the ttyd tunnel port (7681), conditional on `reauth.tunnel.enabled`.
- **`charts/agent-smith/templates/ingress-reauth.yaml`** — Traefik Ingress at
  `<agentName>-shell<hostSuffix>` with wildcard TLS, conditional on
  `reauth.tunnel.enabled`.
- **`charts/agent-smith/values.yaml`** — new `reauth.tunnel` section
  (`enabled`, `hostSuffix`, `tlsSecretName`); `REAUTH_TUNNEL_HOST` wired into
  the agent container env.
- **Apache License 2.0** — repo now ships under Apache-2.0 with `LICENSE`
  (full Apache-2.0 text) and `NOTICE` (attribution) at the root, plus a
  `license: Apache-2.0` field in `charts/agent-smith/Chart.yaml` (visible
  via `helm show chart`). The OCI image label
  (`org.opencontainers.image.licenses=MIT` in `.github/workflows/docker.yml`)
  still needs a one-line correction to `Apache-2.0` and requires a
  `workflow`-scoped push to land — tracked separately.

### Changed

- **`scripts/setup.sh`** — credentials write is now skipped when the home PVC
  already holds real (non-stub) tokens, preserving credentials across pod
  restarts. Previously the init container always overwrote from env vars.
- **`scripts/claude-loop.sh`** — runs `_ensure_auth` (calls `claude-reauth`
  if `claude auth status` reports not logged in) before starting Claude and
  after any exit with uptime < 60s.
- **`Dockerfile`** — adds a second Go build stage for `claude-reauth`, installs
  `chromium` + `ttyd` from apt in the runtime stage. Drops Python, pip, and
  Playwright entirely.

---

## [0.1.21] - 2026-05-27

### Changed

- **`entrypoint.sh` + `Dockerfile` — decouple shell from image** — removed `zsh` from the Dockerfile and explicit shell from tmux pane starts. Panes now use `$SHELL` (bash by default); set `SHELL=/bin/zsh` in `extraEnv` or let dotfiles configure it. The image is no longer opinionated about the user's shell environment.

---

## [0.1.20] - 2026-05-26

### Fixed

- **`entrypoint.sh` crash when dotfiles set `base-index 1`** — names the first tmux window `claude` (`-n claude`) and targets all panes as `main:claude.0` / `main:claude.1` instead of numeric `main:0.0`. User dotfiles that set `base-index 1` no longer cause "can't find window: 0" / "no server running" failures at startup.

---

## [0.1.19] - 2026-05-26

### Fixed

- **`entrypoint.sh` crash when dotfiles set `base-index 1`** — attempted to force `base-index 0` via `tmux set-option -g` before session creation. Broken: `set-option` requires a running server and fails with "no server running" before `new-session` is called. Superseded by [0.1.20].

---

## [0.1.18] - 2026-05-26

### Changed

- `setup.sh` — writes real OAuth tokens from env (`CLAUDE_ACCESS_TOKEN`, `CLAUDE_REFRESH_TOKEN`, `CLAUDE_EXPIRES_AT`) when available, enabling Claude to self-refresh before token expiry. Falls back to stub credentials if env vars are absent.
- `claude-loop.sh` — preserves `expiresAt` alongside `accessToken`/`refreshToken` when carrying real tokens forward across `claude` restarts.
- **Dockerfile** — replaces `python3` with `jq`; all JSON manipulation in `setup.sh` and `claude-loop.sh` now uses `jq`.

---

## [0.1.17] - 2026-05-26

### Added

- **`scripts/attach-agent.sh`** — convenience wrapper to `kubectl exec` into a
  running agent pod's tmux session. Pane 0 is the claude-loop (use `/login`
  here to refresh OAuth credentials); pane 1 is a plain shell. Detach with
  `Ctrl-b d`.

### Fixed

- **Agents no longer hang on "Resume from summary" dialog** — `entrypoint.sh`
  now auto-accepts the session-resume prompt (selects option 1, "Resume from
  summary") in both the startup `dispatch()` loop and the ongoing watch loop.
  Previously, agents with long-running sessions (large token counts) would
  silently stall after a pod restart, waiting for interactive input that was
  never sent.

---

## [0.1.16] - 2026-05-26

### Added

- **Agent runbooks + architecture docs** ([#30](https://github.com/sherodtaylor/agent-smith/pull/30)):
  `docs/architecture.md` (system overview, control + data planes), seven
  runbooks under `docs/runbooks/` (cut-a-release, agent-down, adding-agent,
  ci-failure, oauth-401, secret-rotation), root `CLAUDE.md` for the
  progressive-disclosure entry point, and ten reference scripts under
  `.claude/references/` (release cutting, homelab chart bumping, agent
  restart, ESO force-sync, ironproxy restart, stub-cred restore, since-tag
  compare).
- **TaskCreate-to-room surfacing** — agents must post their task list to the
  originating Matrix room for any task with 3+ distinct steps, then update as
  each step completes. ([#29](https://github.com/sherodtaylor/agent-smith/pull/29))
- **v1 roadmap** ([#32](https://github.com/sherodtaylor/agent-smith/pull/32)):
  `docs/roadmap-v1.md` enumerates the five promises v1 must prove (release,
  fleet management, observability, recovery, contribution) and parks larger
  ideas — multi-channel (Slack/Discord/IRC/WhatsApp), harness-agnosticism,
  agent memory, DID-based discovery, eBPF monitoring, KB integration,
  ephemeral agents — as triggered future considerations rather than promises.

### Fixed

- **Cross-agent Matrix mention detection** — agents now match the display-name
  link format Element/web clients actually send
  (`[devbot 💕](https://matrix.to/#/@devbot:lab.sherodtaylor.dev)`), in
  addition to plain text and full Matrix IDs. Previously, plain-text matchers
  missed mentions from web/mobile clients. ([#29](https://github.com/sherodtaylor/agent-smith/pull/29))
- **Matrix `reply` tool parameters** ([#31](https://github.com/sherodtaylor/agent-smith/pull/31)):
  agents now call the plugin's `reply` tool with the correct argument shape
  derived from the plugin source — reasoning routed to thread, plan/result to
  the room, user-input prompts to native reply.
- **Self-healing OAuth token persistence** ([#34](https://github.com/sherodtaylor/agent-smith/pull/34)):
  `claude-loop.sh` no longer overwrites real tokens with the stub on restart.
  After a successful OAuth refresh, the real access/refresh tokens are merged
  into the template (preserving `subscriptionType`/`rateLimitTier`) and carried
  forward. iron-proxy's existing `require:false` config passes them through
  transparently. This eliminates the recurring 401 cycle caused by iron-proxy
  holding a stale env-var token after the pod's built-in refresh cycle ran.

### Changed

- **Mandatory narration pattern** — base agent rules now require a 3-step
  cadence: opening plan → one-line transition per significant step → final
  result with verification command. ([#29](https://github.com/sherodtaylor/agent-smith/pull/29))
- **Cross-agent acknowledgment** — when a teammate mentions you in any room,
  acknowledge in the same thread within one message. ([#29](https://github.com/sherodtaylor/agent-smith/pull/29))
- **Public posture in README** ([#32](https://github.com/sherodtaylor/agent-smith/pull/32)):
  README leads with the production-crew framing the project has earned;
  meta-arguments about positioning removed in favour of letting the substance
  read for itself.

---

## [0.1.15] - 2026-05-25

### Added

- **`setup.command` Helm value** — runs an arbitrary init hook in the setup
  container before the agent starts. Primary use case: dotfiles bootstrap,
  custom environment initialization. See `charts/agent-smith/values.yaml` for
  the example. ([#28](https://github.com/sherodtaylor/agent-smith/pull/28))

---

## [0.1.14] - 2026-05-25

### Fixed

- **Agent liveness across pod restarts** ([#26](https://github.com/sherodtaylor/agent-smith/pull/26)):
  - `claude-loop.sh` restores stub credentials before every `claude` start,
    preventing the OAuth refresh path from leaving `.credentials.json`
    without `subscriptionType: "max"` after a token refresh.
  - Exponential backoff with jitter on crash (15 s → 30 s → 60 s → 120 s)
    prevents tight restart loops.
  - 0–45 s startup jitter desynchronises devbot/infrabot restarts so they
    don't hammer upstreams in lockstep.
  - Keepalive prompt injector — 1–3 h cadence, idle-gated — prevents
    flat-activity signatures during long Matrix lulls.
  - Smoke tests for credential restore and loop restart behaviour (`tests/test-loops.sh`).

---

## [0.1.13] - 2026-05-25

### Added

- **Helm chart** ([#23](https://github.com/sherodtaylor/agent-smith/pull/23)):
  one-release-per-agent Helm chart at `charts/agent-smith/`. Renders
  `ServiceAccount`, `ClusterRole`, `StatefulSet`, and two PVCs (`/root` for
  `~/.claude/`, `/workspace/` for cloned repos). Published to
  `oci://ghcr.io/sherodtaylor/charts/agent-smith` on each `vX.Y.Z` tag.

### Changed

- **`agent-swarm` → `agent-smith`** ([#25](https://github.com/sherodtaylor/agent-smith/pull/25)):
  repo and image rename to reflect the project's public-facing identity. All
  references in `agents/_shared/CLAUDE.md`, scripts, and chart values now use
  the new name.

### Fixed

- **Resume Claude session across pod restarts** ([#24](https://github.com/sherodtaylor/agent-smith/pull/24)):
  `claude-loop.sh` checks `~/.claude/projects/-workspace-${PRIMARY_REPO}` and
  passes `--continue` when prior session state exists, so a pod restart
  doesn't drop in-progress conversations.

---

## [0.1.0] - 2026-05-24 — initial public release

### Added

- **Multi-stage Dockerfile**: Go-built `mcp-nats` + Debian runtime with `gh`,
  `kubectl`, Node + Claude Code CLI, Bun (for the Matrix channel plugin).
- **`agents/_shared/` base rules** + persona files for `devbot` and
  `infrabot` (`agents/devbot/`, `agents/infrabot/`).
- **Init + main scripts**: `scripts/setup.sh` (assembles `~/.claude`, clones
  repos), `scripts/entrypoint.sh` (tmux orchestration),
  `scripts/check-pr-comments.sh` (Stop hook for unaddressed PR comments).
- **Single `claude` process per pod with `--remote-control`** ([#19](https://github.com/sherodtaylor/agent-smith/pull/19)):
  pane 0 runs one `claude` with both the Matrix channel plugin and
  `--remote-control <agent>`; pane 1 is a plain bash shell.
- **Cross-agent PR review + autonomous comment monitoring** ([#10](https://github.com/sherodtaylor/agent-smith/pull/10),
  [#14](https://github.com/sherodtaylor/agent-smith/pull/14)).
- **`defaultMode: auto` in shared agent settings** ([#11](https://github.com/sherodtaylor/agent-smith/pull/11)).
- **Iron-proxy integration**: stub credentials committed to the repo
  ([#16](https://github.com/sherodtaylor/agent-smith/pull/16),
  [#17](https://github.com/sherodtaylor/agent-smith/pull/17)) and DNS routing
  (`dnsPolicy: None` → `iron-proxy.clusterIp`).
- **GIT_GITHUB_TOKEN / GITHUB_TOKEN split** ([#13](https://github.com/sherodtaylor/agent-smith/pull/13)):
  real PAT for git HTTPS Basic Auth (iron-proxy can't swap), proxy token for
  `gh`/REST (iron-proxy swaps).
- **GitHub Actions workflow** (`docker.yml`) with proper semver image
  tagging ([#22](https://github.com/sherodtaylor/agent-smith/pull/22)):
  - Push to `main` → `:main`, `:sha-<short>` (no `:latest` movement).
  - Tag `vX.Y.Z` → `:vX.Y.Z`, `:vX.Y`, `:vX`, `:latest`.
  - OCI labels (`org.opencontainers.image.source`, `description`, `title`,
    `licenses`) for proper GHCR package page rendering.
- **README overhaul** ([#20](https://github.com/sherodtaylor/agent-smith/pull/20),
  [#21](https://github.com/sherodtaylor/agent-smith/pull/21)): single-claude
  + stub-credentials runtime model documented; rationale for Claude Code CLI
  over the Agent SDK / `claude -p` / opencode.

### Fixed

- **Don't quiet-exit dispatch before bypass prompt is accepted** ([#18](https://github.com/sherodtaylor/agent-smith/pull/18)):
  `entrypoint.sh`'s `dispatch()` waits for the Bypass Permissions warning
  before counting quiet ticks toward early exit. Cold-pull pods that take
  20–30 s to render the prompt no longer fall through prematurely.
- **Restore `--remote-control` to pane 1** ([#15](https://github.com/sherodtaylor/agent-smith/pull/15)).

---

[Unreleased]: https://github.com/sherodtaylor/agent-smith/compare/v0.1.22...HEAD
[0.1.22]: https://github.com/sherodtaylor/agent-smith/compare/v0.1.21...v0.1.22
[0.1.21]: https://github.com/sherodtaylor/agent-smith/compare/v0.1.20...v0.1.21
[0.1.20]: https://github.com/sherodtaylor/agent-smith/compare/v0.1.19...v0.1.20
[0.1.19]: https://github.com/sherodtaylor/agent-smith/compare/v0.1.18...v0.1.19
[0.1.18]: https://github.com/sherodtaylor/agent-smith/compare/v0.1.17...v0.1.18
[0.1.17]: https://github.com/sherodtaylor/agent-smith/compare/v0.1.16...v0.1.17
[0.1.16]: https://github.com/sherodtaylor/agent-smith/compare/v0.1.15...v0.1.16
[0.1.15]: https://github.com/sherodtaylor/agent-smith/compare/v0.1.14...v0.1.15
[0.1.14]: https://github.com/sherodtaylor/agent-smith/compare/v0.1.13...v0.1.14
[0.1.13]: https://github.com/sherodtaylor/agent-smith/compare/v0.1.0...v0.1.13
[0.1.0]: https://github.com/sherodtaylor/agent-smith/releases/tag/v0.1.0
