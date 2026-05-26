# agent-smith v1 roadmap

**Status:** draft for review
**Author:** DevBot (with Sherod)
**Last updated:** 2026-05-25

---

## Vision

**agent-smith is an autonomous engineering crew that ships real work
against real infrastructure.** Not a chatbot, not a code-completion
sidecar — a swarm of AI engineers who operate as peers, coordinate with
each other, and learn from what they ship. Humans set direction; agents
execute, coordinate, recover from their own mistakes, and surface what
they couldn't.

The shape we're aiming at: the operator opens Matrix on Monday morning
and the crew has already triaged the weekend's CI failures, opened three
Dependabot PRs, fixed the one with a clean bump, asked for a steer on
the two that weren't, and posted a one-line summary in `#audit`. They
don't relay information between bots; the bots share state. They don't
piece together what happened from three browser tabs; one timeline shows
the whole run. They don't audit token usage by hand; budgets are
enforced at the edge. They trust what the bots changed because they can
inspect what was done, not because they were watching live.

Right now agent-smith is a long way from that. It is two bots that
faithfully complete the tasks they're handed, with no shared memory, no
unified observability, no capability scoping, and no ability to
originate work. Every conversation is the first conversation. v1 closes
that gap.

---

## What v1 must prove

Five promises. Every feature in this roadmap traces back to one of them.
If a feature can't be tied to a promise, it doesn't belong in v1.

| # | Promise | What it means in practice |
|---|---|---|
| **P1** | **Coordination is real** | DevBot and InfraBot share understanding without Sherod as relay. Decisions, incidents, and patterns are durable and queryable across agents. |
| **P2** | **Work is observable** | Any past run can be reconstructed end-to-end from a single timeline — Matrix message → tool calls → file edits → NATS events → log lines → outcome. No three-tab archaeology. |
| **P3** | **Boundaries are enforced** | Each agent has a documented capability scope (what tools, which secrets, which repos). Boundary violations are detected, not just hoped against. |
| **P4** | **Memory compounds** | Agents recall their own past decisions and each other's. Knowledge accumulates over months; agents don't get repeatedly stuck on the same problem. |
| **P5** | **Work originates** | Bots don't only respond to pings — they pick up stale PRs, dep bumps, CI rot, and incident triage on their own cadence. The crew has work even when Sherod is asleep. |

## Future considerations

Items we've thought through, have a position on, and intentionally placed
beyond v1. Each has a clear trigger that would pull it forward.

- **Model portability — a harness-agnostic agent loop.** Today we run on
  Claude Code, and the leverage of CLAUDE.md + MCP + the plugin
  marketplace + the Matrix channel plugin is exactly why the crew works.
  A future agent layer could abstract the LLM so local models (Hermes,
  Llama) can run cheap sub-agent dispatch (classification, embeddings,
  low-stakes tool calls) while Claude stays on the main loop. **Pull
  forward when:** a second model becomes load-bearing for cost or
  latency reasons we can measure.
- **Decentralized agent discovery (DID / registry).** A `team.yaml` is
  enough while a single operator runs all agents. A future where agents
  span trust boundaries — multiple operators, cross-org collaboration,
  agents that join the swarm without being pre-provisioned — wants
  DIDs, a registry, or a federated MCP catalog. **Pull forward when:**
  the crew grows past ~5 agents OR an agent runs outside this trust
  boundary.
- **Syscall-level observability via eBPF.** iron-proxy controls egress
  and VictoriaLogs captures stdout/stderr, which is enough today
  because bots only ingest input from the Matrix allowlist. A future
  posture that accepts untrusted input (third-party MCP servers,
  webhook triggers, user-submitted scripts) wants per-process syscall
  audit, file-write tracking, and fork-chain visibility. **Pull
  forward when:** bots take untrusted input, OR an incident shows
  application-layer logs were not enough to reconstruct what
  happened.

---

## Current state vs. the promises

Honest gap analysis. Where are we against each promise *right now*?

| Promise | Current state | Gap |
|---|---|---|
| P1 — Coordination | NATS event log exists but is opaque (no UI, queried only on request); `#audit` room is unstructured prose. | No typed shared store, no read-on-startup convention. Agents start every conversation from zero. |
| P2 — Observability | Three observability tiers: NATS (structured, no UI), VictoriaLogs (text), Matrix (semantic, unstructured). None talk to each other. | No `run_id` correlation. Diagnosing a misbehaving run means correlating by hand. |
| P3 — Boundaries | Matrix allowlist gates *who* can trigger a bot. Cluster RBAC partially scoped via per-agent ServiceAccounts. | Nothing gates *what* a bot can do once triggered. DevBot can call any tool InfraBot can. No detection of cross-boundary calls. |
| P4 — Memory | Claude Code's per-project auto-memory works for an individual agent. | No cross-agent memory. No KB. Agents repeatedly re-discover the same context. |
| P5 — Origination | Zero. Bots are 100% reactive. | No cron, no event triggers beyond Matrix, no concept of "work the crew has noticed and is doing." |

---

## v1 themes and the features that serve them

Themes are the work. Features are how we deliver each theme. Sequencing is at the bottom.

### Theme A — Make the crew coherent (P1 + P4)

The single biggest leverage point. Today every Matrix conversation starts
from zero because there's nowhere for either agent to look up what they or
their teammate already decided. Fix this and 50% of "wait, what was the
context for…" disappears.

- **Agent Memory: cross-agent typed KV.** NATS-backed records with strict
  schemas (`decision`, `incident`, `pattern`, `runbook`). An `mcp-memory`
  Go binary exposes `write_record`, `read_records(type, agent?, since?)`,
  `find_records(query)`. Both bots wire it into `agents/_shared/mcp.json`.
  Solves P1 directly and is the substrate for P4.
- **Native Knowledge Base (read-only MCP).** Vector DB (qdrant or pgvector)
  over past PRs, `#audit` history, and `docs/`. The KB is what makes memory
  *compound* rather than just accumulate — retrieval, not just storage.
  Ships in v1.1, paired with memory.

### Theme B — Make every run inspectable (P2)

Today an off-the-rails run is undebuggable after the fact. This blocks
ephemeral agents (you can't run short-lived bots if you can't review what
they did) and erodes trust in the crew over time.

- **Orchestration Hub.** A `run_id` UUID is generated per Matrix message
  that wakes an agent and threaded through every NATS event, every log line
  (`echo "[run=$RUN_ID] ..."`), and every Matrix reply (footer). A Grafana
  dashboard joins NATS + VictoriaLogs + Matrix on `run_id` and surfaces a
  single timeline. Days of work on existing infra; mandatory prerequisite
  for Theme D.

### Theme C — Make boundaries real (P3)

The current model is "trust both agents fully." It works because there are
two agents and Sherod operates both. The moment we add ephemeral agents
(Theme D) or take outside input (eventually), it stops working.

- **Per-agent capability scopes.** `agents/<name>/capabilities.yaml`
  enumerating allowed tools, allowed Matrix rooms, and accessible secret
  keys. Enforced at three layers: Claude `permissions.deny`, k8s RBAC, and
  an audit-log event on every boundary check.
- **Cost / budget controls.** Daily token budget per agent enforced at
  iron-proxy; hard-kill when exceeded; alert to `#audit`. Becomes critical
  when Theme D ships — without budgets, a buggy ephemeral job can rack up
  real money before anyone notices.

### Theme D — Make the crew autonomous (P5 + scale via P3)

The end state of v1. Bots that originate work on their own cadence, scale
out via short-lived task-scoped runs, and don't need a human to start them.
Blocked on every prior theme.

- **Ephemeral Agents.** K8s `Job`s (not `StatefulSet`s) triggered by NATS
  events or cron. First implementation: `pr-reviewer`, wakes on
  `swarm.events.pr_opened`, runs the `code-review` skill, posts inline
  comments, exits. Strict dep on Themes A (shared memory because no
  persistence), B (debuggability), and C (scoped credentials per run).
- **Proactive work origination.** Start with one concrete loop — weekly
  stale-PR sweep — and add more once the pattern works. Driven by the
  existing `schedule` skill. Each new loop is a small lift once the
  infrastructure is in place.

---

## Sequencing

```
v1.0  Themes A (memory only) + B + C — the foundation
        - Agent Memory (cross-agent typed KV)
        - Orchestration Hub (run_id correlation + Grafana)
        - Per-agent capability scopes
        - team.yaml replaces hardcoded agent list (cheap drop-in)

v1.1  Theme A complete + Theme D pilot
        - Native KB (read-only MCP) — pairs with memory
        - Cost / budget controls
        - First ephemeral agent: pr-reviewer

v1.2  Theme D scaled
        - First proactive workflow: stale-PR sweep
        - Second ephemeral agent type (TBD with Sherod)

v2.x  Future considerations pulled forward as their triggers fire
        (model portability, federated discovery, syscall observability)
```

---

## Open questions for Sherod

Real decisions where I don't want to commit without you weighing in.

1. **Capability-scope enforcement layers.** Cluster RBAC + Claude
   `permissions.deny` is already two layers. Do we want a third — the bot
   itself rejecting calls before they hit either — for defense in depth? Or
   is two enough?
2. **KB substrate.** Qdrant (own Helm release) vs. pgvector (reuse existing
   Postgres). Preference?
3. **Ephemeral agent egress.** iron-proxy currently issues stable
   credentials per *agent name*. Ephemerals need a credential per *run*.
   Does iron-proxy grow a session-broker, or do we sidecar something new?
4. **NATS stream retention.** The memory stream needs different retention
   from `swarm.events.*`. Comfortable with a new stream + retention policy,
   or want to overload an existing one?
5. **Origination cadence.** How proactive do you actually want the crew?
   "Bot opens a PR every night if it can find a clean dep bump" is a very
   different posture from "bot prepares a list of candidate work for
   Sherod's morning review." This shapes Theme D.

---

## Appendix — items from the original list mapped to themes

For traceability, here's where each of your original v1 candidates landed.

| Original idea | Theme | Verdict |
|---|---|---|
| Agent Memory | A | **In v1.0** — biggest leverage item, ships first |
| Orchestration Hub for debugging | B | **In v1.0** — mandatory prerequisite for ephemerals |
| Native KB integration | A | **In v1.1** — pairs with memory; read-only MCP first |
| Ephemeral Agents | D | **In v1.1** — pilot with `pr-reviewer`, then expand |
| Harness Agnostic (decoupled from Claude) | — | **Future consideration** — pull forward when a second model becomes load-bearing for cost or latency we can measure |
| Decentralized agent discovery (DID / registry) | — | **Future consideration** — pull forward when the crew grows past ~5 agents or spans trust boundaries; `team.yaml` carries us until then |
| Native eBPF for networking/security | — | **Future consideration** — pull forward when bots take untrusted input, or when an incident shows application-layer logs were not enough |

**Net adds** (not on original list, surfaced by promise analysis):
- Per-agent capability scopes (P3)
- Cost/budget controls (P3 + safety for Theme D)
- Proactive work origination as a first-class theme (P5)
