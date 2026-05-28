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
