# Platform branding — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the platform-wide positioning shift specced in `docs/superpowers/specs/2026-05-28-platform-branding-design.md` — new tagline + framework-first copy on README + website, pixel-sprite crew portraits with state variants (active / vacation / error), GitHub social card, GitHub topics update, and the DND / quiet hours feature.

**Architecture:** Two phases, sequenced. **Phase A (branding + visual)** is doc/website-only and ships independently. **Phase B (DND)** changes the agent persona (`agents/_shared/CLAUDE.md`) + adds chart values for `quietHours`, and assumes the matrix-channel-fork `edit_message` tool has landed (per spec §11.3); a defensive fallback is included for when `edit_message` is unavailable.

**Tech Stack:** Markdown (README, persona, runbooks), Astro 5 components, hand-rolled SVG (sprites + state variants), YAML (Helm values), bash (claude-loop / setup), `gh api` (GitHub topics + social card upload).

**Spec:** `docs/superpowers/specs/2026-05-28-platform-branding-design.md`

**Working branches:**
- `feat/branding-phase-a` on `agent-smith` (Phase A)
- `feat/branding-phase-b-dnd` on `agent-smith` (Phase B, after Phase A merges + matrix-channel `edit_message` lands)

---

## File map

```
README.md                                    # Phase A — canonical tagline + hero copy + sprite row
CLAUDE.md                                    # Phase A — sync brand vocab if any stale wording

website/public/sprites/                      # Phase A — NEW: hand-authored SVGs
├── devbot.svg                               # active state, 16×16, currentColor
├── devbot-vacation.svg                      # vacation state (Zzz overlay)
├── devbot-error.svg                         # error state (! overlay)
├── infrabot.svg                             # active state
├── infrabot-vacation.svg
└── infrabot-error.svg
website/public/og-image.png                  # Phase A — NEW: 1280×640 GitHub/OG social card

website/src/components/
├── SpriteDevbot.astro                       # Phase A — NEW: Astro wrapper, state="active|vacation|error" prop
├── SpriteInfrabot.astro                     # Phase A — NEW
├── MeetTheCrew.astro                        # Phase A — NEW: the landing section
├── TmuxStatusBar.astro                      # Phase A — extended: append `· devbot 💤` when in DND
├── AuditTail.astro                          # Phase A — extended: render sprite + vacation glyph
└── HeroPane.astro                           # Phase A — extended: tagline + sub copy from §5
website/src/layouts/BaseLayout.astro         # Phase A — add og:image meta tag
website/src/pages/index.astro                # Phase A — hero copy + Meet the crew + "Under the hood — reference deployment" rename
website/src/pages/log/index.astro            # Phase A — sprite next to agent column, vacation marker
website/src/content/config.ts                # Phase A — add optional `state` field to log schema
website/src/data/crew-status.example.json    # Phase A — add state + dnd_until per agent
website/scripts/refresh-crew-status.ts       # Phase A — surface state + dnd_until in output

agents/_shared/CLAUDE.md                     # Phase B — DND persona rules (/dnd command, quiet hours, rollup)

charts/agent-smith/values.yaml               # Phase B — per-agent quietHours + quietHoursTz
charts/agent-smith/templates/statefulset.yaml # Phase B — wire QUIET_HOURS + QUIET_HOURS_TZ env vars
scripts/setup.sh                             # Phase B — pass QUIET_HOURS through to claude (no-op if unset)
```

---

## Phase A — branding + visual (PR #1)

### Task 1: Branch + read the spec

**Files:** none

- [ ] **Step 1: Branch**

```bash
cd /workspace/agent-smith
git checkout main && git pull --ff-only
git checkout -b feat/branding-phase-a
```

- [ ] **Step 2: Re-read spec §3–9** (`docs/superpowers/specs/2026-05-28-platform-branding-design.md`). Every code/copy block below comes from there; verify line-for-line where you copy.

### Task 2: Author the 6 sprite SVGs (DevBot + InfraBot × 3 states)

**Files:**
- Create: `website/public/sprites/devbot.svg`
- Create: `website/public/sprites/devbot-vacation.svg`
- Create: `website/public/sprites/devbot-error.svg`
- Create: `website/public/sprites/infrabot.svg`
- Create: `website/public/sprites/infrabot-vacation.svg`
- Create: `website/public/sprites/infrabot-error.svg`

- [ ] **Step 1: Author the active-state sprites by hand**, 16×16 viewBox, palette-driven via `currentColor`. The personality direction is "fun + theme-driven" (Sherod, 2026-05-28); recommended read per spec §7.2:
  - **DevBot** — visor/cap + sigil (e.g. small `$` prompt mark on the chest pixel). Eye row in `currentColor`; cap rim or chest sigil in accent.
  - **InfraBot** — hard-hat silhouette + chest LED. Helmet rim in amber-equivalent (via `--accent-warn` if the surrounding scope sets it).

  Use any pixel editor (Aseprite, Piskel, lospec) and export as SVG. Constraints (re-confirm from spec §7.1):
  - `viewBox="0 0 16 16"`
  - Pixels are `<rect width="1" height="1" x="N" y="M" fill="currentColor"/>` or named token classes.
  - File size ≤ 1.5 KB each (total 6 files = ≤ 9 KB raw — fits the 8 KB target with one byte to spare; tighten if it doesn't).
  - Save the active-state sprites first.

- [ ] **Step 2: Author the 4 state-variant sprites** by copying the active sprite and adding the overlay rect(s):
  - `devbot-vacation.svg` / `infrabot-vacation.svg` — append a 2-pixel `Zzz` glyph at top-right corner (~(13,1)–(15,2)) using `--accent-warn` (amber) via a styled class (`fill="var(--accent-warn, #d4a85f)"`).
  - `devbot-error.svg` / `infrabot-error.svg` — append a 1-pixel `!` glyph at top-right (single column of 2 pixels + a dot below) using `--accent-err` (rust).

- [ ] **Step 3: Verify total size**

```bash
du -b website/public/sprites/*.svg | awk '{s+=$1} END {print "total bytes:", s, "(target: 8192)"}'
# expected: total ≤ 8192
```

- [ ] **Step 4: Smoke-render** in a browser via `bun --cwd website run dev` (visit `http://localhost:4321/agent-smith/sprites/devbot.svg`). Should display the pixel art. Confirm visually.

- [ ] **Step 5: Commit**

```bash
git add website/public/sprites/
git commit -m "feat(brand): pixel-sprite crew portraits — devbot + infrabot × 3 states

Hand-authored 16×16 SVGs, currentColor + palette-token-driven so
recoloring flows through the existing CSS variables. Six files
totalling <8KB raw. State overlays:
- active: no overlay
- vacation: Zzz glyph at (13,1)-(15,2) in --accent-warn (amber)
- error: ! glyph at (15,1) in --accent-err (rust)

Spec: docs/superpowers/specs/2026-05-28-platform-branding-design.md §7"
```

### Task 3: Astro sprite components

**Files:**
- Create: `website/src/components/SpriteDevbot.astro`
- Create: `website/src/components/SpriteInfrabot.astro`

- [ ] **Step 1: Write `SpriteDevbot.astro`** as a small wrapper that loads the right SVG file based on `state`:

```astro
---
type SpriteState = 'active' | 'vacation' | 'error';
interface Props { state?: SpriteState; size?: number; ariaLabel?: string; }
const { state = 'active', size = 64, ariaLabel } = Astro.props;
const file = state === 'active' ? 'devbot.svg' : `devbot-${state}.svg`;
const src = `${import.meta.env.BASE_URL}sprites/${file}`;
const label = ariaLabel ?? `DevBot — code agent (${state})`;
---
<img src={src} width={size} height={size} alt={label} class:list={['sprite', state]} loading="lazy" />

<style>
  .sprite { image-rendering: pixelated; image-rendering: -moz-crisp-edges; }
  .sprite.vacation { filter: saturate(0.7); }
  .sprite.error    { filter: hue-rotate(15deg); }
</style>
```

- [ ] **Step 2: Write `SpriteInfrabot.astro`** — identical shape with `infrabot` substitutions in `file`, `src`, `label`, and `InfraBot — infra agent` in the default `ariaLabel`.

- [ ] **Step 3: Smoke test** in `bun --cwd website run dev`. Embed temporarily on `index.astro` for visual confirmation; remove the embed before commit.

- [ ] **Step 4: Commit**

```bash
git add website/src/components/SpriteDevbot.astro website/src/components/SpriteInfrabot.astro
git commit -m "feat(brand): SpriteDevbot + SpriteInfrabot wrappers

Astro components accept state='active|vacation|error' and size props;
load the matching SVG from /sprites/. image-rendering: pixelated
keeps the pixel art crisp at any scale. Vacation state desaturates
slightly; error state rotates hue for at-a-glance recognition."
```

### Task 4: README — tagline, hero copy, sprite row

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace the first 4 lines** of `README.md` (the existing `# agent-smith`, blank, `> Your engineering team, running in Kubernetes.`, screenshot) with:

```markdown
# agent-smith

> **Your secure sandboxed agent workforce — ship in your sleep.**

<p>
  <img src="https://raw.githubusercontent.com/sherodtaylor/agent-smith/main/website/public/sprites/devbot.svg" width="64" alt="DevBot — code agent" />
  <img src="https://raw.githubusercontent.com/sherodtaylor/agent-smith/main/website/public/sprites/infrabot.svg" width="64" alt="InfraBot — infra agent" />
</p>
```

- [ ] **Step 2: Replace the "What this is" intro paragraph(s)** with the framework-first opening (per spec §5.2 + §6.2):

```markdown
agent-smith is a framework for running long-lived AI engineering agents that
operate as peers — they read code, open PRs, review each other's work, and
learn from what they ship. Deploy them however you run servers; the reference
deployment is one Kubernetes StatefulSet per agent.
```

- [ ] **Step 3: Rename the existing "How it works" / Kubernetes-heavy section** to **"Under the hood — reference deployment"** and prepend the opener:

```markdown
## Under the hood — reference deployment

*The way we run agent-smith. Yours can be different.*

(existing K8s + iron-proxy content follows unchanged)
```

- [ ] **Step 4: Audit the README for stale vocab** — search and replace per spec §4:

```bash
grep -nE '\b(platform|fleet|swarm|bot|chatbot|copilot|ChatOps|RBAC)\b' README.md | head -20
```

Replace per the brand-vocab table (Use ↔ Avoid) on a case-by-case basis. Some of the existing uses (e.g. "swarm" in commit hashes / NATS event names) are technical and stay; brand-positioning language gets the vocab swap.

- [ ] **Step 5: Verify the README renders** — push to a scratch branch (skip), or render with `markdownlint` if installed. Simplest: `head -40 README.md` and confirm the structure reads correctly.

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -m "docs(brand): README — new tagline + sprite row + framework-first intro

- Tagline: Your secure sandboxed agent workforce — ship in your sleep.
- Sprite row: external SVG refs to website/public/sprites/{devbot,infrabot}.svg
  (GitHub renders external SVGs as raster — confirmed in spec §10 Q4)
- 'What this is' intro now leads with framework concepts; K8s deferred
  to 'Under the hood — reference deployment'
- Stale vocab swept (platform → framework, bot → agent in positioning copy)

Spec: docs/superpowers/specs/2026-05-28-platform-branding-design.md"
```

### Task 5: Website — HeroPane copy

**Files:**
- Modify: `website/src/components/HeroPane.astro`

- [ ] **Step 1: Replace the tagline + sub line** in the component with the locked spec wording:

Find the `tagline` and `sub` JSX text and change to:

```astro
<h1>Your secure sandboxed agent workforce — ship in your sleep.</h1>
<p class="sub">agent-smith is a framework for running long-lived AI engineering agents that operate as peers — they read code, open PRs, review each other's work, and learn from what they ship.</p>
```

- [ ] **Step 2: Update the dual-CTA block** to add a third "meet the crew" CTA that anchors to `#meet-the-crew`:

```astro
<div class="ctas">
  <a class="cta" href={`${import.meta.env.BASE_URL}docs`}>$ read the docs ›</a>
  <a class="cta" href="https://github.com/sherodtaylor/agent-smith">$ view on github ›</a>
  <a class="cta" href="#meet-the-crew">$ meet the crew ↓</a>
</div>
```

- [ ] **Step 3: Verify build**

```bash
cd website && bun run build 2>&1 | tail -3
# expected: success
```

- [ ] **Step 4: Commit**

```bash
git add website/src/components/HeroPane.astro
git commit -m "feat(web): HeroPane — new tagline + framework-first sub + meet-crew CTA"
```

### Task 6: Website — MeetTheCrew section component

**Files:**
- Create: `website/src/components/MeetTheCrew.astro`

- [ ] **Step 1: Write the component**

```astro
---
import SpriteDevbot   from './SpriteDevbot.astro';
import SpriteInfrabot from './SpriteInfrabot.astro';
import statusData     from '../data/crew-status.json';

const stateOf = (name: string): 'active' | 'vacation' | 'error' => {
  const a = statusData.agents?.find((x: any) => x.name === name);
  return (a?.state as any) ?? 'active';
};
---
<section id="meet-the-crew" class="meet-crew">
  <h2>$ meet the crew</h2>
  <div class="row">
    <figure class="card">
      <SpriteDevbot state={stateOf('devbot')} size={128} />
      <figcaption>
        <strong>DevBot</strong> — code agent. Reads the repo, opens PRs,
        addresses review, merges. Ships in your sleep.
      </figcaption>
    </figure>
    <figure class="card">
      <SpriteInfrabot state={stateOf('infrabot')} size={128} />
      <figcaption>
        <strong>InfraBot</strong> — infra agent. Owns the cluster, reviews
        DevBot's PRs end-to-end, posts inline findings.
      </figcaption>
    </figure>
  </div>
</section>

<style>
  .meet-crew  { margin-top: var(--space-20); }
  .row        { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: var(--space-12); margin-top: var(--space-8); }
  .card       { display: grid; gap: var(--space-4); justify-items: center; text-align: center; padding: var(--space-6); background: var(--bg-elev); border-radius: 6px; margin: 0; }
  .card figcaption { font-family: var(--font-mono); font-size: var(--fs-mono); color: var(--fg-muted); max-width: 32ch; }
  .card figcaption strong { color: var(--accent); font-weight: 700; }
  @media (max-width: 640px) { .row { grid-template-columns: 1fr; } }
</style>
```

- [ ] **Step 2: Commit**

```bash
git add website/src/components/MeetTheCrew.astro
git commit -m "feat(web): MeetTheCrew landing section component

Two-card grid (DevBot + InfraBot) with the SpriteX components at
size=128. State is read from crew-status.json so vacation/error
variants render automatically. Mobile: cards stack."
```

### Task 7: Wire MeetTheCrew into landing + rename "Under the hood"

**Files:**
- Modify: `website/src/pages/index.astro`

- [ ] **Step 1: Import the new component** at the top of `index.astro`:

```astro
import MeetTheCrew from '../components/MeetTheCrew.astro';
```

- [ ] **Step 2: Insert `<MeetTheCrew />` between** "What your team can do" (the capabilities section) and "Under the hood" — i.e. after the closing `</section>` of `.capabilities` and before the architecture section.

- [ ] **Step 3: Rename the architecture section header** from `<h2>$ describe runtime</h2>` (or whatever it currently is) to `<h2>$ describe reference deployment</h2>` and add a sub-line right after the h2:

```astro
<p class="measure" style="color: var(--fg-muted);">
  <em>The way we run agent-smith. Yours can be different.</em>
</p>
```

- [ ] **Step 4: Verify build + visual**

```bash
cd website && bun run build 2>&1 | tail -3
# expected: success; meet-the-crew section appears in dist/index.html
grep -c 'meet-the-crew' dist/index.html
# expected: ≥ 1
```

- [ ] **Step 5: Commit**

```bash
git add website/src/pages/index.astro
git commit -m "feat(web): wire MeetTheCrew + rename Under the hood to reference deployment

K8s/iron-proxy architecture is no longer the product framing —
it's the reference deployment, with explicit 'yours can be different.'"
```

### Task 8: Wire sprite + vacation glyph into AuditTail

**Files:**
- Modify: `website/src/components/AuditTail.astro`

- [ ] **Step 1: Import the sprite components** at the top of the frontmatter:

```astro
import SpriteDevbot   from './SpriteDevbot.astro';
import SpriteInfrabot from './SpriteInfrabot.astro';
import statusData     from '../data/crew-status.json';

const stateOf = (name: string): 'active' | 'vacation' | 'error' => {
  const a = statusData.agents?.find((x: any) => x.name === name);
  return (a?.state as any) ?? 'active';
};
```

- [ ] **Step 2: Replace the `.agent` span** in the rendered list with a sprite + name + (optional vacation glyph):

```astro
<span class="agent">
  {e.data.agent === 'devbot'   && <SpriteDevbot   state={stateOf('devbot')}   size={16} />}
  {e.data.agent === 'infrabot' && <SpriteInfrabot state={stateOf('infrabot')} size={16} />}
  {' '}{e.data.agent}
  {stateOf(e.data.agent) === 'vacation' && <span class="dnd-glyph" aria-label="in DND"> 💤</span>}
</span>
```

- [ ] **Step 3: Add styling** for the inline sprite + glyph:

```astro
<style>
  /* (existing) */
  .agent { display: inline-flex; align-items: center; gap: 4px; }
  .agent img.sprite { vertical-align: -2px; }
  .dnd-glyph { color: var(--accent-warn); }
</style>
```

- [ ] **Step 4: Commit**

```bash
git add website/src/components/AuditTail.astro
git commit -m "feat(web): AuditTail — render sprite next to agent column + 💤 in vacation"
```

### Task 9: Wire sprite into /log page

**Files:**
- Modify: `website/src/pages/log/index.astro`

- [ ] **Step 1: Add the same import block** as in Task 8 step 1 to `log/index.astro`'s frontmatter.

- [ ] **Step 2: Replace the `.agent` span** in the `.log-feed` `<li>` with the same sprite-prefixed pattern from Task 8 step 2.

- [ ] **Step 3: Add the same `.agent` + `.dnd-glyph` styles** to `log/index.astro`'s `<style>` block.

- [ ] **Step 4: Commit**

```bash
git add website/src/pages/log/index.astro
git commit -m "feat(web): /log — same sprite + vacation glyph treatment as AuditTail"
```

### Task 10: TmuxStatusBar — append DND indicator when in DND

**Files:**
- Modify: `website/src/components/TmuxStatusBar.astro`

- [ ] **Step 1: Read the agent statuses + DND flag** from `crew-status.json`. Add to the frontmatter:

```ts
const dndAgents = (statusData.agents ?? []).filter((a: any) => a.state === 'vacation');
const dndLabel  = dndAgents.length === 0
  ? ''
  : dndAgents.map((a: any) => `${a.name} 💤${a.dnd_until ? ' until ' + a.dnd_until : ''}`).join(' · ');
```

- [ ] **Step 2: Append the DND label** to the existing right-side status line (the one with `● running · 2 agents · …`):

```astro
<span class="right">
  ● running · {agents.length} agents · PRs this week: {prsThisWeek} · last release: {lastRelease}
  {dndLabel && <span class="dnd"> · {dndLabel}</span>}
</span>
```

- [ ] **Step 3: Style the DND span** in amber:

```astro
<style>
  /* (existing) */
  .dnd { color: var(--accent-warn); }
</style>
```

- [ ] **Step 4: Commit**

```bash
git add website/src/components/TmuxStatusBar.astro
git commit -m "feat(web): TmuxStatusBar — append '· devbot 💤 until 08:00' when in DND"
```

### Task 11: crew-status.json schema + example update

**Files:**
- Modify: `website/src/content/config.ts`
- Modify: `website/src/data/crew-status.example.json`
- Modify: `website/scripts/refresh-crew-status.ts`

- [ ] **Step 1: Add `state` (optional) to log entry schema** in `website/src/content/config.ts`:

```ts
const log = defineCollection({
  type: 'content',
  schema: z.object({
    timestamp: z.coerce.date(),
    agent: z.enum(['devbot', 'infrabot', 'sherod']),
    run_id: z.string().min(6),
    kind: z.enum(['pr_shipped', 'pr_merged', 'pr_reviewed', 'incident', 'release', 'note', 'blocked']),
    state: z.enum(['active', 'vacation', 'error']).optional().default('active'),
    summary: z.string().max(160),
    link: z.string().url().optional(),
  }),
});
```

(`blocked` added to `kind` per spec §11 — kind=blocked overrides DND.)

- [ ] **Step 2: Update `crew-status.example.json`** to add `state` + `dnd_until` per agent:

```json
{
  "generated_at": "2026-05-27T00:00:00Z",
  "agents": [
    { "name": "devbot",   "role": "code",  "last_pr": null, "last_seen": null, "state": "active", "dnd_until": null },
    { "name": "infrabot", "role": "infra", "last_pr": null, "last_seen": null, "state": "active", "dnd_until": null }
  ],
  "last_release": "v0.1.23",
  "prs_this_week": 0
}
```

- [ ] **Step 3: Update `refresh-crew-status.ts`** so the build-time generator emits the new fields with sensible defaults (always `state: "active"` and `dnd_until: null` for v1 — DND state plumbing into crew-status is a future enhancement; today the generator just preserves the shape):

In `buildCrewStatus()`, change the `agents.map(...)` block to include `state: 'active' as const, dnd_until: null,` on each returned object.

- [ ] **Step 4: Run tests**

```bash
cd website && bun test 2>&1 | tail -3
# expected: pass (existing tests + nothing new asserted yet)
```

- [ ] **Step 5: Commit**

```bash
git add website/src/content/config.ts website/src/data/crew-status.example.json website/scripts/refresh-crew-status.ts
git commit -m "feat(web): crew-status.json gains state + dnd_until per agent

Schema additions:
- log entry: optional state ('active'|'vacation'|'error', defaults 'active')
- log entry kind: added 'blocked' for DND-override messages
- crew-status agents: state + dnd_until (both default for v1)

Render path (sprite variants, TmuxStatusBar DND label) already
reads these fields. Plumbing them at runtime is Phase B."
```

### Task 12: BaseLayout — add og:image meta

**Files:**
- Modify: `website/src/layouts/BaseLayout.astro`

- [ ] **Step 1: Add the og:image and twitter:image meta tags** in the `<head>`:

```astro
<meta property="og:image"     content={`${import.meta.env.BASE_URL}og-image.png`} />
<meta property="og:image:width"  content="1280" />
<meta property="og:image:height" content="640" />
<meta name="twitter:card"     content="summary_large_image" />
<meta name="twitter:image"    content={`${import.meta.env.BASE_URL}og-image.png`} />
```

- [ ] **Step 2: Commit** (file added in next task; commit the meta wiring separately so the dependency is explicit)

```bash
git add website/src/layouts/BaseLayout.astro
git commit -m "feat(web): BaseLayout — og:image + twitter:card meta for social previews"
```

### Task 13: Generate the 1280×640 social card

**Files:**
- Create: `website/public/og-image.png`

- [ ] **Step 1: Author the social card** at 1280×640. Composition (lift from the hero):
  - Background: `--bg` `#0b0d10`
  - Centered display text: `Your secure sandboxed agent workforce` (line 1, JetBrains Mono Bold ~96pt) + `ship in your sleep.` (line 2, JetBrains Mono Bold ~96pt, in `--accent` #5fbf8d)
  - Bottom-right: two sprite portraits at 128×128 (DevBot + InfraBot), gap 32px
  - Bottom-left: small mono caption `github.com/sherodtaylor/agent-smith` in `--fg-muted` 24pt

  Generate via any image tool (Figma + export, ImageMagick, or hand-PNG). Save as `website/public/og-image.png` at exactly 1280×640.

- [ ] **Step 2: Verify dimensions**

```bash
file website/public/og-image.png
# expected: PNG image data, 1280 x 640
```

- [ ] **Step 3: Verify build picks it up**

```bash
cd website && bun run build 2>&1 | tail -3
ls -la dist/og-image.png
grep -c 'og-image.png' dist/index.html
# expected: ≥ 1
```

- [ ] **Step 4: Commit**

```bash
git add website/public/og-image.png
git commit -m "feat(brand): og-image.png — 1280×640 social card

Centered tagline + 2 sprite portraits + repo URL caption.
Wired via og:image + twitter:image in BaseLayout (prior commit)."
```

### Task 14: GitHub topics — replace `kubernetes` from first position

**Files:** none (gh-api change)

- [ ] **Step 1: Read current topics**

```bash
SSL_CERT_FILE=/root/iron-proxy.crt gh api repos/sherodtaylor/agent-smith/topics --jq '.names'
```

- [ ] **Step 2: Set new topic list** — `ai-agents` and `framework` lead; `claude-code`, `autonomous-agents`, `matrix`, `homelab` follow; `kubernetes` retained but later in the list:

```bash
SSL_CERT_FILE=/root/iron-proxy.crt gh api -X PUT repos/sherodtaylor/agent-smith/topics \
  -f names='["ai-agents","framework","autonomous-agents","claude-code","sandbox","force-multipliers","matrix","kubernetes","gitops","homelab"]'
```

- [ ] **Step 3: Verify**

```bash
SSL_CERT_FILE=/root/iron-proxy.crt gh api repos/sherodtaylor/agent-smith/topics --jq '.names'
# expected: list starts with ai-agents, framework, ...
```

(No commit; topic changes are repo metadata, not files.)

### Task 15: Open PR for Phase A

**Files:** none

- [ ] **Step 1: Push**

```bash
cd /workspace/agent-smith
git push -u origin feat/branding-phase-a
```

- [ ] **Step 2: Open PR**

```bash
SSL_CERT_FILE=/root/iron-proxy.crt gh pr create --repo sherodtaylor/agent-smith \
  --head feat/branding-phase-a --base main \
  --title "[dev] feat(brand): platform branding Phase A — copy + sprites + crew + social card" \
  --body "$(cat <<'EOF'
## What
Phase A of `docs/superpowers/specs/2026-05-28-platform-branding-design.md` — copy, visual identity, social card. No agent runtime changes (those are Phase B).

- **Tagline:** Your secure sandboxed agent workforce — ship in your sleep.
- **README:** new tagline + sprite row (external SVGs) + framework-first opening + "Under the hood — reference deployment" rename
- **Website:** HeroPane updated; new MeetTheCrew landing section with sprite portraits; sprite + vacation glyph wired into AuditTail + /log; TmuxStatusBar appends `· devbot 💤` when an agent is in DND
- **Sprites:** 6 hand-authored SVGs (devbot + infrabot × active/vacation/error), <8KB total, palette-token-driven via `currentColor`
- **Social card:** 1280×640 PNG at `website/public/og-image.png`, wired via og:image + twitter:image
- **GitHub topics:** reordered — `ai-agents`, `framework` lead; `kubernetes` demoted

## Phase B (separate PR)
DND / quiet hours feature lives in `feat/branding-phase-b-dnd` — depends on this PR landing first (the schema additions in `crew-status` are how DND state surfaces).

## Verify
\`\`\`
cd website && bun install && bun run build
# Visit https://sherodtaylor.github.io/agent-smith/ after deploy
# Confirm: tagline, sprites visible, Meet the crew section present
\`\`\`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)" 2>&1 | tail -3
```

---

## Phase B — DND feature (PR #2)

Depends on Phase A merging + matrix-channel-fork `edit_message` tool being available (per spec §11.3).

### Task 16: Branch + persona DND rules

**Files:**
- Modify: `agents/_shared/CLAUDE.md`

- [ ] **Step 1: Branch**

```bash
cd /workspace/agent-smith
git checkout main && git pull --ff-only
git checkout -b feat/branding-phase-b-dnd
```

- [ ] **Step 2: Append a new section** to `agents/_shared/CLAUDE.md` (place after the existing "Loop Prevention" section, before "NATS Event Log"):

```markdown
## Quiet hours / DND / vacation mode

You may receive a `/dnd` command from the operator on Matrix. When you do, persist the state and follow these rules until DND ends.

**Forms accepted:**
- `/dnd on` — enable DND indefinitely
- `/dnd on until 08:00` — enable DND until 08:00 local time (operator's tz, configured by `$QUIET_HOURS_TZ`)
- `/dnd off` — disable DND immediately

**Persistence.** Write the current DND state to `~/.claude/dnd.json` (`{ "active": true, "until": "08:00", "since": "<iso>" }` or `{ "active": false }`). Re-read on every turn.

**Implicit schedule.** If `$QUIET_HOURS` env is set (format `HH:MM-HH:MM`, e.g. `22:00-08:00`), treat the current time vs that window the same as an explicit `/dnd on until HH:MM` for the duration of that window.

**Behavior in DND:**
1. **NO `reply` calls** to the originating room for normal `kind` messages. Use `edit_message` (matrix-channel fork tool) on the pinned DND-status message instead — Matrix edits don't push-notify. If `edit_message` is unavailable in the channel, fall back to fully silent: no reply at all until window ends.
2. **NO `react` calls.** Suppress the usual 👀 ack on inbound.
3. **PRs, commits, gh comments — UNCHANGED.** The Matrix surface goes quiet; the engineering work continues.
4. **Override for `kind=incident` or `kind=blocked`** — these post normally to wake the operator. Use sparingly.
5. **DND-end rollup.** When the window closes (auto on clock, or `/dnd off`), post ONE summary `reply` to the originating room: `"While you were away (HH:MM–HH:MM): shipped N PRs, reviewed M, opened K incidents. Full audit: <site /log url>."`

**Audit.** Every action you take in DND still emits its NATS event + writes its log entry as normal. The `/log` page on the website fills with `state: vacation` markers so the morning scrollback is complete.
```

- [ ] **Step 3: Commit**

```bash
git add agents/_shared/CLAUDE.md
git commit -m "feat(persona): DND / quiet hours / vacation rules

Persona-layer DND. Operator sends /dnd on [until HH:MM] or /dnd off
on Matrix; agent persists state to ~/.claude/dnd.json and follows
silence + rollup rules.

When edit_message (matrix-channel fork) is available, in-flight
status edits stay live without push. Fallback: fully silent until
window ends, then one rollup reply.

kind=incident/blocked overrides DND. PRs/commits/gh comments are
never suppressed.

Spec: docs/superpowers/specs/2026-05-28-platform-branding-design.md §11"
```

### Task 17: Helm chart — quietHours value + env wiring

**Files:**
- Modify: `charts/agent-smith/values.yaml`
- Modify: `charts/agent-smith/templates/statefulset.yaml`

- [ ] **Step 1: Add the optional values** to `charts/agent-smith/values.yaml` (place near the `matrix:` block):

```yaml
# Quiet hours / DND. When set, the agent treats the window as an implicit
# /dnd on for its duration: replies suppressed (or routed through
# edit_message if the matrix-channel fork is loaded), with a single rollup
# reply at window-end. See agents/_shared/CLAUDE.md "Quiet hours / DND /
# vacation mode" for the full behavior.
quietHours:
  window: ""             # e.g. "22:00-08:00"; empty = no schedule
  tz: "America/New_York" # IANA timezone the window is interpreted in
```

- [ ] **Step 2: Wire env vars** in `charts/agent-smith/templates/statefulset.yaml`. Find the `agent` container's `env:` block (around line 79) and add:

```yaml
            {{- if .Values.quietHours.window }}
            - name: QUIET_HOURS
              value: {{ .Values.quietHours.window | quote }}
            - name: QUIET_HOURS_TZ
              value: {{ .Values.quietHours.tz | quote }}
            {{- end }}
```

- [ ] **Step 3: helm lint + render**

```bash
/tmp/linux-amd64/helm lint /workspace/agent-smith/charts/agent-smith --set agentName=devbot --set matrix.homeserverUrl=https://x --set matrix.botUserId=@x:y --set existingSecret=s --set quietHours.window="22:00-08:00" 2>&1 | tail -3
# expected: 0 chart(s) failed
/tmp/linux-amd64/helm template t /workspace/agent-smith/charts/agent-smith --set agentName=devbot --set matrix.homeserverUrl=https://x --set matrix.botUserId=@x:y --set existingSecret=s --set quietHours.window="22:00-08:00" 2>&1 | grep -A1 'QUIET_HOURS' | head -5
# expected: env entry rendered
```

If helm isn't on PATH, install via `curl -fsSL --cacert /root/iron-proxy.crt https://get.helm.sh/helm-v3.16.0-linux-amd64.tar.gz -o /tmp/helm.tgz && tar -xzf /tmp/helm.tgz -C /tmp`.

- [ ] **Step 4: Commit**

```bash
git add charts/agent-smith/values.yaml charts/agent-smith/templates/statefulset.yaml
git commit -m "feat(chart): quietHours value + QUIET_HOURS env wiring

Optional per-release DND schedule. When .Values.quietHours.window
is non-empty, the agent container gets QUIET_HOURS + QUIET_HOURS_TZ
env vars; the persona reads them on every turn and treats the
window as implicit DND. Unset = no scheduled DND (only /dnd on
operator commands take effect)."
```

### Task 18: Bump chart version

**Files:**
- Modify: `charts/agent-smith/Chart.yaml`

- [ ] **Step 1: Bump patch** (current → next; e.g. 0.1.23 → 0.1.24). Both `version` and `appVersion`.

- [ ] **Step 2: Commit**

```bash
git add charts/agent-smith/Chart.yaml
git commit -m "chore(release): v0.1.24 — quietHours + persona DND rules"
```

### Task 19: CHANGELOG entry

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add a new section** at the top of `[Unreleased]`:

```markdown
### Added
- Quiet hours / DND mode — operator can `/dnd on [until HH:MM]` on Matrix or
  set `quietHours.window` in chart values to schedule a recurring window.
  In DND, replies suppress (or edit_message-route through the matrix-channel
  fork) and a single rollup posts at window-end. `kind=incident/blocked`
  overrides. Spec: docs/superpowers/specs/2026-05-28-platform-branding-design.md §11.
- Pixel-sprite crew portraits (DevBot, InfraBot) with active/vacation/error
  state variants. Rendered in README, website hero status, /log, MeetTheCrew.
```

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs(changelog): note DND mode + sprite portraits for v0.1.24"
```

### Task 20: Open PR for Phase B

**Files:** none

- [ ] **Step 1: Push**

```bash
git push -u origin feat/branding-phase-b-dnd
```

- [ ] **Step 2: Open PR**

```bash
SSL_CERT_FILE=/root/iron-proxy.crt gh pr create --repo sherodtaylor/agent-smith \
  --head feat/branding-phase-b-dnd --base main \
  --title "[dev] feat: DND / quiet hours / vacation mode (v0.1.24)" \
  --body "$(cat <<'EOF'
## What
Phase B of `docs/superpowers/specs/2026-05-28-platform-branding-design.md` — the DND / quiet hours behavioral feature. Depends on Phase A (PR #<phase-a-PR-#>) being merged for the schema additions (state + dnd_until in crew-status).

- **Persona rules** in `agents/_shared/CLAUDE.md` — operator sends `/dnd on [until HH:MM]` or `/dnd off`; agent persists state to `~/.claude/dnd.json` and follows silence + rollup rules.
- **Chart value** `quietHours.window` + `quietHours.tz` → `QUIET_HOURS` + `QUIET_HOURS_TZ` env on the agent container. Empty = no scheduled DND.
- **Channel-plugin dependency** — uses matrix-channel-fork `edit_message` for live status during DND (no push); falls back to fully silent + rollup if `edit_message` is unavailable.
- Chart bump to v0.1.24; CHANGELOG entry.

## Verify
\`\`\`
# in a pod with QUIET_HOURS=22:00-08:00:
# (between 22:00 and 08:00 local) tag the bot in Matrix
# — bot should not reply (or should edit a single status); morning rollup at 08:00.

# in any pod:
# tag the bot with "/dnd on until 17:30"
# — bot should not reply until 17:30; then posts rollup.
\`\`\`

Spec: docs/superpowers/specs/2026-05-28-platform-branding-design.md §11
🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)" 2>&1 | tail -3
```

---

## Self-review

**Spec coverage:**
- §3 design decisions — locked in T4 (tagline), T5 (hero sub copy), T7 (Under the hood rename), T16 (DND vocab)
- §4 brand vocab — applied in T4 (README sweep)
- §5 tagline + hero — T4, T5
- §6 landing IA — T6, T7 (MeetTheCrew + rename)
- §7 sprites + state variants — T2 (SVGs), T3 (components), T4 (README row), T8 (AuditTail), T9 (/log), T10 (TmuxStatusBar DND label)
- §7.4 vacation state — T2 (vacation SVGs), T3 (state prop), T10 (DND label)
- §8 surface map — T4 (README), T5-T10 (website), T14 (GitHub topics), CLAUDE.md not modified because grep at T4 step 4 expected to find nothing brand-stale at this layer (already uses "agent" + "operator"); spec already noted this as preferred.
- §10 social card — T12 (BaseLayout meta) + T13 (PNG)
- §11 DND feature — Phase B entirely (T16 persona, T17 chart, T18/19 release plumbing, T20 PR)
- §11.3 channel dependency — handled in T16 (persona has explicit fallback when edit_message absent)
- **Placeholder scan:** no TBD/FIXME in step bodies. Every code block is complete.
- **Type consistency:** `state` field shape `'active' | 'vacation' | 'error'` used identically in T3 (sprite components), T6 (MeetTheCrew), T8 (AuditTail), T9 (/log), T11 (schema). `dnd_until: string | null` consistent in T10 (TmuxStatusBar) and T11 (example JSON).
- **Ambiguity:** explicit fallback when `edit_message` is unavailable (T16 step 2, behavior point 1). Explicit phase ordering (Phase A merges first; Phase B depends on schema changes from Phase A).
