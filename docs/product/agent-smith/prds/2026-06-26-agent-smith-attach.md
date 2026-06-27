# agent-smith attach — PRD

**Date:** 2026-06-26 (revised 2026-06-27 after DevBot review)
**Product:** agent-smith
**Scope:** new `agent-smith` CLI binary + an in-pod semantic-state sidecar
**Status:** in-review (PMBot, brainstormed with Sherod over Matrix 2026-06-25/26)
**Owner:** PMBot (product/positioning, this doc); DevBot (implementation spec, to follow)

---

## Problem

Today the operator has one way to actually *watch and steer* the agent
fleet doing focused coding work: Matrix. Matrix is chat-shaped — every
message is a discrete envelope, threaded under another envelope. Two
things break:

1. **Reasoning is hidden.** The operator sees an agent's *outputs*
   (final messages, PR links, "done" notes) but not the live trail of
   tool calls, file reads, decisions, and self-corrections that
   produced them. The "thinking" lives inside the pod, not in the
   chat. When something goes wrong, the only way to see what the
   agent was actually doing is to SSH-style attach with
   `kubectl exec -it -n agents <bot>-0 -- tmux attach -t main` —
   one pod at a time, one terminal at a time.
2. **There is no fleet view.** The operator cannot see all four
   agents working in parallel at a glance. Switching between
   devbot's PR work, infrabot's Flux reconcile, pmbot's PRD drafting,
   and brandbot's social draft means cycling through four terminal
   tabs of raw `kubectl exec`, each disconnected from the others.

The operator wants Matrix to *stay* — it's the right surface for
family/observer/audit traffic, and brandbot/pmbot updates land there
correctly. What's missing is the *cockpit*: a focused, side-by-side
view of the fleet for the operator doing deep work, with the agents'
reasoning surfaced as structured state instead of being buried in
terminal scrollback.

## Goal

Ship a single binary, `agent-smith`, with a first subcommand `attach`
that gives the operator a multi-agent cockpit on their laptop, plus
an in-cluster sidecar that publishes structured agent state to a
Matrix audit channel for human and programmatic observers.

When the operator runs `agent-smith attach --fleet`:

- They get a side-by-side view of all four agents in their terminal.
- Each pane shows the live tmux session inside that agent's pod.
- The view survives laptop sleep, network blips, and pod restarts —
  the agents are stateful StatefulSets and the panes reattach.
- If the operator has [herdr](https://herdr.dev) installed, the
  view is rendered through herdr (multi-pane, semantic per-pane
  status indicators, structured event subscriptions). If herdr is
  not installed, the view degrades cleanly to a single-stream
  tmux attach — the same UX an operator has today, but launched
  by one command instead of four.

When agents transition between **working / idle / blocked / done**,
the in-cluster sidecar publishes those transitions to a Matrix
audit channel using a transport-agnostic JSON schema:

```json
{ "agent": "devbot", "prev_state": "working", "next_state": "blocked",
  "ts": "2026-06-27T18:42:11Z", "evidence": "permission_prompt" }
```

(NATS publishing is deliberately out of scope for v1 — see Non-goals.
The schema is transport-agnostic so swap is cheap when a programmatic
consumer arrives.)

State surfacing is **operator-UX-independent**: an operator who
never installs the CLI still gets a richer audit room than today.

Success at one month: Sherod's day-to-day deep-coding sessions
happen through `agent-smith attach`, Matrix becomes a quieter room
of summary-shaped messages (not "I'm-thinking-about" tool-call
spam), and the `#audit` room shows structured agent-state lines
useful for downstream consumers (brandbot's `release_worthy` flow
being the first named one, on its own follow-up PR).

## Intended state (the cockpit, in one picture)

```
operator's laptop                           k3s cluster (agents ns)
┌──────────────────────────────────┐        ┌──────────────────────┐
│  $ agent-smith attach --fleet    │        │  devbot-0    pod     │
│                                  │        │  ├─ tmux main        │
│  ┌────────┬────────┐             │   ┌───►│  └─ claude (PTY)     │
│  │ devbot │ infrab │             │   │    │  └─ state-reporter   │
│  │ ●work  │ ●idle  │             │   │    │     (sidecar)        │
│  ├────────┼────────┤             │   │    │      │                │
│  │ pmbot  │ brandbt│             │   │    │      ▼                │
│  │ ●blkd  │ ●done  │             │   │    │   Matrix #audit       │
│  └────────┴────────┘             │   │    │   (v1; NATS later)    │
│   (panes = live tmux attach)     │   │    │                       │
│                                  │   │    │  …same for the other 3 pods
│   herdr (if installed) drives   ◄┼───┘    │                       │
│   the layout + manifest rules    │        │                       │
│                                  │        │                       │
│   no herdr → single-pane attach  │        │                       │
│   to the first/named bot         │        │                       │
└──────────────────────────────────┘        └──────────────────────┘
```

Three components ship in this work:

1. **`agent-smith` CLI** (operator-side, new binary in this repo)
   with the `attach` subcommand. Auto-detects whether herdr is on
   `$PATH`; uses herdr when present, falls back to a single-pane
   `kubectl exec … tmux attach` when not. Reads kubeconfig from
   the operator's environment (no new auth surface — the operator
   already has cluster access via Tailscale + kubeconfig).
2. **Herdr agent manifest** (data, shipped in this repo) that
   teaches a local herdr instance how to recognize our panes as
   Claude Code agents and how to detect `working / idle / blocked
   / done` state transitions inside them. Manifest is a data file,
   not code — no AGPL coupling. Versioned with the agent personas.
3. **In-pod semantic-state sidecar** (new container in each agent
   pod via the chart) that watches the pane and publishes the same
   four states to a Matrix audit channel using **our own
   transport-agnostic JSON schema** — independent of herdr's event
   format. The sidecar runs whether or not any operator ever opens
   herdr. NATS publishing is deferred until the first programmatic
   consumer ships (see Non-goals); the schema does not change when
   that consumer arrives.

The operator's cockpit (component 1+2) and the audit/observer feed
(component 3) are deliberately decoupled. The operator can stop
running herdr tomorrow and the audit room keeps working.

## User-visible acceptance criteria

The operator can:

- [ ] Run `agent-smith attach --fleet` on a freshly cloned repo with
      no extra setup (kubeconfig + Tailscale connectivity to the
      cluster assumed present) and see a live attach to all four
      agents, side-by-side if herdr is on `$PATH`, single-pane
      otherwise.
- [ ] Run `agent-smith attach devbot` (or any single agent name) and
      see only that agent's tmux session, regardless of herdr
      presence. This is the "I just want to look at one bot" path.
- [ ] Close the terminal, reopen it the next day, run
      `agent-smith attach --fleet` again, and pick up where they
      left off (panes reattach to the same long-lived tmux sessions
      inside the pods — no work is lost).
- [ ] Pass `--no-herdr` to force the fallback path even when herdr
      is installed (escape hatch for debugging).
- [ ] Run `agent-smith --help` and see `attach` documented as the
      first subcommand. Each flag is documented inline.

The operator and any observer can:

- [ ] Watch the Matrix audit channel and see lines matching the
      locked schema — `{agent, prev_state, next_state, ts,
      evidence?}` JSON — within **~30s** of an agent hitting a
      permission prompt (looser bound chosen for v1 to fit a
      polling capture-pane detector; tightens to ~5s if/when the
      sidecar moves to Claude Code hook registration — see Open Q #2).
- [ ] Trust those events whether or not the operator is currently
      attached. The sidecar runs in the pod; it does not depend on
      herdr or the operator's CLI.

Brandbot (downstream consumer) is out of scope for this PR. The
producer side (sidecar + wire schema) lands here; brandbot's
consumer change — including any persona-file wire-schema reference —
ships in brandbot's own follow-up PR.

The fleet maintainer (Sherod, again) can:

- [ ] Re-run a fresh agent-smith install and have the sidecar come
      up alongside each agent without any manual chart edits — the
      sidecar is part of the agents StatefulSet definition.
- [ ] Toggle the sidecar off via a single Helm value if it ever
      misbehaves, without taking the agents themselves down. The
      sidecar is additive; agent liveness is independent of it.

## Non-goals (v1)

- **Bundling herdr in the agent-smith image.** Herdr is AGPL-3.0
  and stays on the operator's laptop only. The chart does not
  install herdr in pods; the manifest is data, not code. Crossing
  into AGPL bundling is explicitly out of scope and will not be
  done without a separate license decision from Sherod.
- **A web/browser/TUI dashboard.** This work is terminal-first.
  Anything graphical is later, if ever.
- **Custom agent state vocabulary.** v1 ships
  `working / idle / blocked / done` only. Finer-grained states
  (`tool_call`, `thinking`, `awaiting_permission`, etc.) are
  v1.1 once the four-state model is exercised.
- **Multi-operator shared sessions.** The cockpit is single-user
  on a single laptop. A future "share my pane to a teammate's
  herdr" is a 2027 question.
- **The `init` subcommand.** A second PRD will cover
  `agent-smith init` (chart bootstrap, persona scaffolding). Same
  binary, separate concerns, separate acceptance criteria. Tracking
  in a sibling spec.
- **Replacing tmux inside the pod.** The pod entrypoint stays
  tmux-based. Herdr, when used, runs on the operator's laptop and
  wraps `kubectl exec … tmux attach` per pane.
- **Auto-installing herdr for the operator.** If the operator
  wants herdr, they install it themselves (the cockpit degrades
  gracefully to single-pane mode when herdr is absent). v1 does
  not bundle herdr's binary or offer to download it.
- **NATS publishing.** Deferred to the first programmatic consumer
  that genuinely needs it. The wire schema is transport-agnostic
  so dropping it onto a `swarm.state.agent` NATS subject later is
  a small additive change. Bundling NATS now is YAGNI: brandbot —
  the only named downstream — is on its own follow-up PR, and the
  Matrix audit channel is enough for v1's observers.
- **Per-tool-call telemetry.** v1 publishes only the four state
  transitions, not the underlying tool calls / file edits / token
  counts. That's a different consumer (observability dashboards)
  and a different volume profile.

## Decisions settled (lock unless new info)

| # | Decision | Source |
|---|---|---|
| D1 | **Single canonical binary, `agent-smith`, with subcommands.** `attach` is the first; `init` is the next (separate PRD). | Sherod 2026-06-26 |
| D2 | **Agent-smith is an external product with its own product-area home.** Product specs for agent-smith — PRDs for fleet members (brandbot, etc.) and PRDs for fleet-level capabilities (this one, `init`, …) — live in `docs/product/agent-smith/prds/` inside this repo. | Sherod 2026-06-26/27 (`$HUJ4GJYqQO4chcAg7e8GU6VgOwVf10vZ48Ky5448SZQ`) |
| D3 | **Herdr is operator-installed only, never bundled.** Manifest TOML in this repo is the only herdr artifact we ship. | Sherod 2026-06-26 + license posture |
| D4 | **Default = auto-use herdr when present, `--no-herdr` opt-out.** Onboarding gradient: works without herdr; deepens with it. | Sherod 2026-06-26 |
| D5 | **Semantic state is operator-UX-independent.** Sidecar publishes to a Matrix audit channel regardless of whether anyone is attached. NATS publishing deferred; the schema is transport-agnostic so adding NATS later is additive. | PMBot recommendation, Sherod ✅ 2026-06-26; DevBot YAGNI input 2026-06-27 |
| D6 | **State vocabulary v1 = `working / idle / blocked / done`** — four states only. The schema is ours (Matrix-published JSON), but the *vocabulary* deliberately matches herdr's own four-label model so a herdr-equipped operator sees the same labels in their cockpit and in the audit room. Future readers should not "improve" by renaming. | PMBot recommendation, Sherod ✅ 2026-06-26 |
| D7 | **Manifest format = data only (TOML/YAML), no code.** Versioned with personas in this repo. | PMBot 2026-06-26 |
| D8 | **Matrix coexists.** This is the *operator's cockpit*; Matrix stays for family/audit/brandbot. Herdr is not a Matrix replacement. | Sherod 2026-06-13/26 |
| D9 | **PR review path:** PMBot opens this PR, DevBot reviews, Sherod ✅s. DevBot then opens an implementation-detail spec + the implementation PR(s). | Sherod 2026-06-26 |
| D10 | **Wire schema locked in this PRD.** `{agent, prev_state, next_state, ts, evidence?}` JSON, published to a Matrix audit channel. Field semantics: `agent` = matrix display name; `ts` = RFC 3339; `evidence` = free-form short string the detector populates when available (e.g. `permission_prompt`, `stop_hook`). Schema is transport-agnostic — same fields drop onto NATS/SQS/anything else when added. | PMBot 2026-06-27 in response to DevBot review finding #2 |

## Open questions for the implementation spec (devbot's lane)

These are not product questions — PMBot has closed those. They are
technical questions that DevBot's implementation spec needs to nail
before code is written. Five Qs remain after DevBot's 2026-06-27
review (sidecar-transport was answered: Matrix-only for v1, dropped
from this list).

1. **Herdr manifest detection mechanism.** What signals does herdr's
   `agent_manifests` feature actually consume to fire
   `pane.agent_status_changed`? PTY pattern matching, process
   inspection, exit codes, prompt-text rules, all of the above?
   DevBot's spike noted the event exists but did not pin the
   detection schema. The shape of our manifest file depends on this.
2. **Sidecar detection mechanism — which Claude Code hook do we
   register?** Claude Code emits hook events (`Stop`, tool-call
   lifecycle, etc.) that the sidecar can subscribe to for
   sub-second, lossless state-transition detection. The realistic
   v1 options are: (a) polling capture-pane + pattern match —
   simple, but lossy and bound by the ~30s AC; (b) state file
   written by `claude-loop.sh` — clean separation but extra moving
   piece; (c) Claude Code hook registration — emits events at the
   source. (c) is almost certainly the right answer; the open
   question is *which hooks* we register and what payload they
   need. (Earlier draft mentioned `claude --output-format=json` —
   that's for structured response output, not state events; struck.)
3. **Binary language.** Go (matches Anthropic/Kubernetes ecosystem)
   vs. Rust (matches herdr's own implementation) vs. shell (lowest
   effort, painful at scale). DevBot's call — guidance: pick the
   language whose ecosystem already has a clean `kubectl exec` /
   PTY-handling library, not the language we're nostalgic about.
4. **Chart wiring.** New container in each StatefulSet pod template,
   or a DaemonSet, or a per-agent init container that establishes
   the watch? StatefulSet sidecar is the obvious answer; if
   something pushes back, flag here.
5. **CLI distribution.** `go install`-able for v1? Homebrew tap
   eventually? GitHub Release binaries on every chart tag?
   Operator's laptop is the only install target for v1 (Sherod's
   laptop), so v1 distribution can be `go install` or a single
   `make build`. Distribution UX gets polished when there's a
   second operator.

## Process

- This PR (PMBot) lands the PRD and the decisions table. DevBot's
  first review pass landed 2026-06-27 (6 findings + nits, all
  addressed in this revision). Sherod ✅s the product framing to
  close the spec PR gate.
- After merge, DevBot opens an implementation spec resolving the
  five remaining open questions above, and then the implementation
  PRs follow.
- A sibling PR will follow with the `agent-smith init` PRD
  (separate interview, separate decisions table, separate ACs).

## Revision history

- 2026-06-26 — initial draft (PMBot)
- 2026-06-27 — DevBot review pass addressed:
  - Moved file from `docs/superpowers/specs/` to
    `docs/product/agent-smith/prds/` (finding #5).
  - Reworded D2 per Sherod's 2026-06-27 clarification: agent-smith
    is an external product with its own product-area home; the
    overreach in v1's D2 was struck (finding #1).
  - Locked wire schema in D10 + the AC body (finding #2).
  - Fixed Open Q #2 to point at Claude Code hooks instead of
    `--output-format=json` (finding #3).
  - Relaxed latency AC to ~30s for v1 polling, ~5s when hooks
    land (finding #4).
  - Added herdr-vocabulary-interop note to D6 (finding #6).
  - Added Tailscale prereq to AC #1 (nit).
  - Clarified brandbot consumer is out of scope here, including
    its persona wire-format reference (nit).
  - Dropped NATS from D5, AC, and diagram per DevBot's YAGNI
    consult; added explicit non-goal + transport-agnostic schema
    note.
