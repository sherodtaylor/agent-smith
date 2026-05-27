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

### Added

- **Declarative plugin reconciler** —
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
