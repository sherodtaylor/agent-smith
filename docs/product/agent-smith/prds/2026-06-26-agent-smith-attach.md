# agent-smith attach — PRD

**Date:** 2026-06-26 (revised 2026-06-27 — round 3, scope reduction)
**Product:** agent-smith
**Scope:** new `agent-smith` CLI binary (operator-side only)
**Status:** in-review (PMBot, brainstormed with Sherod over Matrix 2026-06-25/27)
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
   agent was actually doing is to attach with
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
reasoning surfaced as structured per-pane state instead of being
buried in terminal scrollback.

## Goal

Ship a single binary, `agent-smith`, with a first subcommand `attach`
that gives the operator a multi-agent cockpit on their laptop.

When the operator runs `agent-smith attach --fleet`:

- They get a side-by-side view of all four agents in their terminal.
- Each pane shows the live tmux session inside that agent's pod.
- The view survives laptop sleep, network blips, and pod restarts —
  the agents are stateful StatefulSets and the panes reattach.
- If the operator has [herdr](https://herdr.dev) installed, the
  view is rendered through herdr (multi-pane, semantic per-pane
  status indicators driven by the agent manifest we ship as data).
  Agent state — `working / idle / blocked / done` — surfaces *to
  the operator's cockpit only*, via herdr's own
  `pane.agent_status_changed` events.
- If herdr is not installed, the view degrades cleanly to a
  single-stream `kubectl exec … tmux attach` — the same UX an
  operator has today, but launched by one command instead of four.
  No structured state in the fallback path; the cockpit reverts to
  raw PTY scrollback.

Success at one month: Sherod's day-to-day deep-coding sessions
happen through `agent-smith attach`. Matrix stays the way it is —
this PRD does not change what Matrix sees.

## Intended state (the cockpit, in one picture)

```
operator's laptop                           k3s cluster (agents ns)
┌──────────────────────────────────┐        ┌──────────────────────┐
│  $ agent-smith attach --fleet    │        │  devbot-0    pod     │
│                                  │        │  ├─ tmux main        │
│  ┌────────┬────────┐             │   ┌───►│  └─ claude (PTY)     │
│  │ devbot │ infrab │             │   │    │                       │
│  │ ●work  │ ●idle  │             │   │    │  (no in-pod changes  │
│  ├────────┼────────┤             │   │    │   in this PRD)        │
│  │ pmbot  │ brandbt│             │   │    │                       │
│  │ ●blkd  │ ●done  │             │   │    │  …same for the other 3 pods
│  └────────┴────────┘             │   │    │                       │
│   (panes = live tmux attach,    ◄┼───┘    │                       │
│    status icons sourced from     │        │                       │
│    herdr's manifest events       │        │                       │
│    when herdr is installed)      │        │                       │
│                                  │        │                       │
│   no herdr → single-pane attach  │        │                       │
│   to the first/named bot, no     │        │                       │
│   status icons                   │        │                       │
└──────────────────────────────────┘        └──────────────────────┘
```

Two components ship in this work, both operator-side:

1. **`agent-smith` CLI** (new binary in this repo) with the
   `attach` subcommand. Auto-detects whether herdr is on `$PATH`;
   uses herdr when present, falls back to single-pane
   `kubectl exec … tmux attach` when not. Reads kubeconfig from
   the operator's environment (no new auth surface — the operator
   already has cluster access via Tailscale + kubeconfig).
2. **Herdr agent manifest** (data, shipped in this repo) that
   teaches a local herdr instance how to recognize our panes as
   Claude Code agents and how to detect `working / idle / blocked
   / done` state transitions inside them. The manifest is a data
   file, not code — no AGPL coupling. Versioned with the agent
   personas.

There is no in-pod component, no chart change, no audit channel
publishing, and no sidecar. Agent state surfaces *only* to the
operator who has herdr installed and is attached.

## User-visible acceptance criteria

The operator can:

- [ ] Run `agent-smith attach --fleet` on a freshly cloned repo with
      no extra setup (kubeconfig + Tailscale connectivity to the
      cluster assumed present) and see a live attach to all four
      agents, side-by-side if herdr is on `$PATH`, single-pane
      otherwise.
- [ ] With herdr installed, see per-pane status icons or labels
      reflecting `working / idle / blocked / done` within whatever
      latency herdr's manifest mechanism delivers (~seconds for
      pattern-based detectors; faster if hook-based). The exact
      latency is a property of herdr's detection mechanism, not
      something we own — see Open Q #1.
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

## Non-goals (v1)

- **Audit-channel publishing of agent state.** No Matrix audit
  lines, no NATS subjects, no wire schema in this PRD. State
  surfaces *only* to the operator who has herdr installed and is
  attached. Downstream consumers (e.g. brandbot's `release_worthy`
  flow) stay on their existing triggers. Re-evaluate if/when a
  programmatic consumer genuinely needs state telemetry.
- **In-pod sidecar / chart changes.** No new container in the agents
  StatefulSet, no new init container, no new ConfigMap, no new
  Helm value. The pod entrypoint is untouched.
- **Bundling herdr in the agent-smith image.** Herdr is AGPL-3.0 and
  stays on the operator's laptop only. The chart does not install
  herdr in pods; the manifest is data, not code. Crossing into AGPL
  bundling is explicitly out of scope and will not be done without
  a separate license decision from Sherod.
- **A web/browser/TUI dashboard.** This work is terminal-first.
  Anything graphical is later, if ever.
- **Custom agent state vocabulary.** v1 uses
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

## Decisions settled (lock unless new info)

| # | Decision | Source |
|---|---|---|
| D1 | **Single canonical binary, `agent-smith`, with subcommands.** `attach` is the first; `init` is the next (separate PRD). | Sherod 2026-06-26 |
| D2 | **Agent-smith is an external product with its own product-area home.** Product specs for agent-smith — PRDs for fleet members (brandbot, etc.) and PRDs for fleet-level capabilities (this one, `init`, …) — live in `docs/product/agent-smith/prds/` inside this repo. | Sherod 2026-06-26/27 (`$HUJ4GJYqQO4chcAg7e8GU6VgOwVf10vZ48Ky5448SZQ`) |
| D3 | **Herdr is operator-installed only, never bundled.** The agent manifest in this repo is the only herdr artifact we ship. | Sherod 2026-06-26 + license posture |
| D4 | **Default = auto-use herdr when present, `--no-herdr` opt-out.** Onboarding gradient: works without herdr; deepens with it. | Sherod 2026-06-26 |
| D5 | **State surfacing is operator-only.** Agent state (`working / idle / blocked / done`) flows from herdr's manifest events to the operator's attached cockpit. There is no audit channel, no NATS subject, no in-pod publisher. Re-evaluate if a programmatic consumer ever appears. | Sherod 2026-06-27 (`$whDyJgK0KRgkQPWC3lPG52Kov2tkDC7V_xnjNL9In3k`) |
| D6 | **State vocabulary v1 = `working / idle / blocked / done`** — four states only, deliberately matching herdr's own four-label model so the cockpit and any future audit-shaped surface line up if/when added. Future readers should not "improve" by renaming. | PMBot recommendation, Sherod ✅ 2026-06-26 |
| D7 | **Manifest format = data only (TOML/YAML), no code.** Versioned with personas in this repo. | PMBot 2026-06-26 |
| D8 | **Matrix coexists.** This is the *operator's cockpit*; Matrix stays for family/audit/brandbot. Herdr is not a Matrix replacement. | Sherod 2026-06-13/26 |
| D9 | **No sidecar.** v2's draft included an in-pod state-reporter sidecar publishing to a Matrix audit channel. Cut on 2026-06-27 — no named consumer, YAGNI, additional chart surface for no near-term gain. | Sherod 2026-06-27 (`$whDyJgK0KRgkQPWC3lPG52Kov2tkDC7V_xnjNL9In3k`) |
| D10 | **PR review path:** PMBot opens this PR, DevBot reviews, Sherod ✅s. DevBot then opens an implementation-detail spec + the implementation PR(s). | Sherod 2026-06-26 |

## Open questions for the implementation spec (devbot's lane)

Three remain after rounds 2 + 3:

1. **Herdr manifest detection mechanism.** What signals does herdr's
   `agent_manifests` feature actually consume to fire
   `pane.agent_status_changed`? PTY pattern matching, process
   inspection, exit codes, prompt-text rules, all of the above?
   The shape of our manifest file depends on this. (DevBot's spike
   noted the event exists but did not pin the detection schema.)
2. **Binary language.** Go (matches Anthropic/Kubernetes ecosystem)
   vs. Rust (matches herdr's own implementation) vs. shell (lowest
   effort, painful at scale). DevBot's call — guidance: pick the
   language whose ecosystem already has a clean `kubectl exec`
   helper / PTY-handling library, not the language we're nostalgic
   about.
3. **CLI distribution.** `go install`-able for v1? Homebrew tap
   eventually? GitHub Release binaries on every chart tag?
   Operator's laptop is the only install target for v1 (Sherod's
   laptop), so v1 distribution can be `go install` or a single
   `make build`. Distribution UX gets polished when there's a
   second operator.

## Process

- This PR (PMBot) lands the PRD and the decisions table. DevBot's
  first review landed 2026-06-27; Sherod's scope-reduction landed
  the same day. Both addressed in this revision. Sherod ✅s the
  product framing to close the spec PR gate.
- After merge, DevBot opens an implementation spec resolving the
  three remaining open questions, and then the implementation PRs
  follow.
- A sibling PR will follow with the `agent-smith init` PRD
  (separate interview, separate decisions table, separate ACs).

## Revision history

- **2026-06-26 — initial draft (PMBot).** Three components (CLI +
  manifest + sidecar), Matrix-audit + NATS publishing for the
  sidecar's emitted state.
- **2026-06-27 round 2 — DevBot review pass addressed:**
  - Moved file from `docs/superpowers/specs/` to
    `docs/product/agent-smith/prds/` (finding #5).
  - Reworded D2 per Sherod's 2026-06-27 clarification: agent-smith
    is an external product with its own product-area home; the
    overreach in round 1's D2 was struck (finding #1).
  - Locked wire schema in D10 + the AC body (finding #2 — later
    dropped in round 3 along with publishing).
  - Fixed Open Q #2 to point at Claude Code hooks instead of
    `--output-format=json` (finding #3 — later moot in round 3).
  - Relaxed latency AC to ~30s for v1 polling (finding #4 — later
    moot in round 3).
  - Added herdr-vocabulary-interop note to D6 (finding #6).
  - Added Tailscale prereq to AC #1 (nit).
  - Clarified brandbot consumer is out of scope here (nit).
  - Dropped NATS from sidecar transport per DevBot's YAGNI
    consult; added explicit non-goal.
- **2026-06-27 round 3 — Sherod scope reduction:**
  - **Cut the sidecar entirely.** No in-pod component, no chart
    change, no audit channel publishing.
  - State surfacing is now operator-only, via herdr's own manifest
    events; nothing is published anywhere else.
  - Locked wire schema (D10 v2) removed — no wire to schema.
  - "Per-tool-call telemetry" non-goal removed (no publisher to
    exclude from).
  - "NATS publishing" non-goal collapsed into the broader
    "audit-channel publishing of agent state" non-goal.
  - Diagram simplified — no sidecar, no audit arrow, no NATS
    annotation.
  - Open Qs trimmed from 5 to 3 (sidecar detection + chart wiring
    dropped — no sidecar, no chart change).
  - D5 reversed (was operator-UX-independent; now explicitly
    operator-only); D9 added to lock the sidecar cut.
