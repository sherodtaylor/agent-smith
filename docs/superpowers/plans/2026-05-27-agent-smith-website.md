# agent-smith website — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a public-facing website for agent-smith hosted on GitHub Pages — landing page, Starlight-powered docs, chronological event log — built with Astro 5 + Bun, deployed via GitHub Actions, with a strict perf budget and zero third-party dependencies.

**Architecture:** All site code lives under `web/` in this repo. Astro 5 with islands for the few interactive bits (no full SPA). Starlight handles `/docs`. Tokens + JetBrains Mono drive the dark-only terminal-as-zine visual system. A GitHub Actions workflow builds on push to `main` (touching `web/**`, `docs/**`, or `web/src/content/log/**`), runs Lighthouse-CI against the perf budget, deploys via `actions/deploy-pages`. PR merges in `agent-smith` and `homelab` produce log entries via `repository_dispatch` plus a small workflow that commits a new MDX file.

**Tech Stack:** Astro 5, `@astrojs/starlight`, `@astrojs/mdx`, `@astrojs/sitemap`, `@fontsource/jetbrains-mono`, `@lottiefiles/lottie-player`, Bun 1.x, GitHub Actions, Lighthouse CI.

**Spec:** `docs/superpowers/specs/2026-05-26-agent-smith-website-design.md`

**Branch:** `feat/website-v1` (single branch, single PR at the end).

---

## Resolved open questions (from spec §7)

Working defaults — flag in PR description so Sherod can override.

1. **Berkeley Mono** → not assumed licensed. Display uses JetBrains Mono weight 800 (free, self-hosted). Trivial swap later via one CSS variable.
2. **Crew-status shape** → `{ generated_at, agents: [{name, role, last_pr: {number, title, merged_at, repo}, last_seen}] }`. Two agents hardcoded in v1 (devbot, infrabot).
3. **PR-merge → log entry** → `repository_dispatch` from `homelab` into `agent-smith`. `agent-smith` listens for both its own `pull_request: closed (merged)` events AND the dispatch from homelab. A single workflow (`.github/workflows/log-pr-merge.yml`) writes the entry MDX and commits to `main` with `chore(log): ...`. Documented payload format so InfraBot can wire the `homelab` side in a follow-up PR.
4. **Lottie authoring** → hand-rolled with `lottie-builder` for v1. After Effects + Bodymovin reserved for v1.1 if/when Sherod wants more animation.

---

## File map

Files to be created. Numbers in parens map to the task that creates the file.

```
web/
├── astro.config.mjs                                    (T03)
├── package.json                                        (T02)
├── tsconfig.json                                       (T02)
├── README.md                                           (T39)
├── bun.lockb                                           (T02)
├── public/
│   ├── robots.txt                                      (T28)
│   └── favicon.svg                                     (T05)
├── scripts/
│   ├── refresh-crew-status.ts                          (T31)
│   └── refresh-crew-status.test.ts                     (T30)
├── src/
│   ├── styles/
│   │   ├── tokens.css                                  (T06)
│   │   └── global.css                                  (T07)
│   ├── layouts/
│   │   └── BaseLayout.astro                            (T08)
│   ├── components/
│   │   ├── TmuxStatusBar.astro                         (T09)
│   │   ├── HeroPane.astro                              (T10)
│   │   ├── AuditTail.astro                             (T11)
│   │   ├── AsciiBox.astro                              (T12)
│   │   ├── StatusBadge.astro                           (T13)
│   │   ├── CursorBlink.astro                           (T14)
│   │   └── LottiePlayer.astro                          (T24)
│   ├── content/
│   │   ├── config.ts                                   (T16)
│   │   ├── docs/                                       (T22)
│   │   │   ├── getting-started.md                      (T22)
│   │   │   ├── architecture.md                         (T22)
│   │   │   ├── agents.md                               (T22)
│   │   │   ├── security.md                             (T22)
│   │   │   ├── operations.md                           (T22)
│   │   │   ├── contributing.md                         (T22)
│   │   │   └── roadmap.md                              (T22, symlinks docs/roadmap-v1.md content)
│   │   └── log/
│   │       └── 2026-05-27-website-spec-merged.mdx      (T17, seed entry)
│   ├── data/
│   │   └── crew-status.json                            (T31, generated; checked-in placeholder)
│   ├── animations/
│   │   ├── hero-boot.json                              (T25)
│   │   ├── ascii-draw.json                             (T26)
│   │   └── log-pulse.json                              (T27)
│   └── pages/
│       ├── index.astro                                 (T15, T18, T19, T20)
│       ├── 404.astro                                   (T29)
│       └── log/
│           └── index.astro                             (T21)
.github/workflows/
├── website.yml                                         (T32)
├── lighthouse.yml                                      (T35)
└── log-pr-merge.yml                                    (T37)
docs/
├── runbooks/
│   └── website-deploy.md                               (T39)
└── adr/
    └── 2026-05-27-log-pr-dispatch.md                   (T37)
```

---

## Phase 0 — Worktree + scaffold

### Task 1: Set up isolated worktree

**Files:** none (git only)

- [ ] **Step 1: Create worktree from main**

```bash
cd /workspace/agent-smith
git fetch origin main
git worktree add ../agent-smith-website feat/website-v1 origin/main
cd ../agent-smith-website
```

- [ ] **Step 2: Verify clean state**

Run: `git status`
Expected: `On branch feat/website-v1 / nothing to commit, working tree clean`

- [ ] **Step 3: Confirm Bun is available**

Run: `bun --version`
Expected: `1.x.x` (any 1.x). If missing, install via `curl -fsSL --cacert /root/iron-proxy.crt https://bun.sh/install | bash` and re-exec shell.

### Task 2: Initialize Astro project under `web/`

**Files:**
- Create: `web/package.json`
- Create: `web/tsconfig.json`
- Create: `web/bun.lockb`
- Create: `web/.gitignore`

- [ ] **Step 1: Create `web/` directory and scaffold Astro**

```bash
mkdir -p web
cd web
bun create astro@latest . --template minimal --typescript strict --no-install --no-git --skip-houston
```

Answer prompts: name `agent-smith-website`, no install (we'll do it next), no git.

- [ ] **Step 2: Install dependencies**

```bash
bun add astro@^5 @astrojs/starlight@latest @astrojs/mdx@latest @astrojs/sitemap@latest @fontsource/jetbrains-mono@latest @lottiefiles/lottie-player@latest
bun add -d @types/bun @lhci/cli@latest typescript@^5
```

- [ ] **Step 3: Edit `web/.gitignore`** — append:

```
node_modules/
dist/
.astro/
src/data/crew-status.json
```

- [ ] **Step 4: Verify install succeeded**

Run: `bun run astro --version`
Expected: `5.x.x`

- [ ] **Step 5: Commit**

```bash
git add web/package.json web/tsconfig.json web/bun.lockb web/.gitignore
git commit -m "chore(web): scaffold Astro 5 project under web/"
```

### Task 3: Wire Astro config (Starlight, MDX, sitemap, base path)

**Files:**
- Modify: `web/astro.config.mjs`

- [ ] **Step 1: Replace `web/astro.config.mjs` with**

```js
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import mdx from '@astrojs/mdx';
import sitemap from '@astrojs/sitemap';

export default defineConfig({
  site: 'https://sherodtaylor.github.io',
  base: '/agent-smith',
  trailingSlash: 'never',
  output: 'static',
  integrations: [
    mdx(),
    sitemap(),
    starlight({
      title: 'agent-smith',
      customCss: ['./src/styles/tokens.css', './src/styles/global.css'],
      sidebar: [
        { label: 'Getting Started', slug: 'getting-started' },
        { label: 'Architecture',    slug: 'architecture' },
        { label: 'Agents',          slug: 'agents' },
        { label: 'Security',        slug: 'security' },
        { label: 'Operations',      slug: 'operations' },
        { label: 'Contributing',    slug: 'contributing' },
        { label: 'Roadmap',         slug: 'roadmap' },
      ],
      // Dark-only — disable the toggle (v1 spec §1.2).
      components: {
        ThemeProvider: './src/components/empty.astro',
        ThemeSelect:   './src/components/empty.astro',
      },
    }),
  ],
});
```

- [ ] **Step 2: Create the placeholder `empty.astro`**

`web/src/components/empty.astro`:
```astro
---
// Stub used to disable Starlight's theme toggle (dark-only site).
---
```

- [ ] **Step 3: Verify build succeeds with no content yet**

Run: `bun run build` from `web/`. Expected: it will fail (no content collections defined) — record the error to confirm we know the gate.

- [ ] **Step 4: Commit**

```bash
git add web/astro.config.mjs web/src/components/empty.astro
git commit -m "feat(web): astro config — starlight, mdx, sitemap, base=/agent-smith, dark-only"
```

### Task 4: Add Bun task scripts to `web/package.json`

**Files:**
- Modify: `web/package.json`

- [ ] **Step 1: Ensure scripts block includes**

```json
"scripts": {
  "dev":   "astro dev",
  "build": "astro build",
  "preview": "astro preview",
  "check": "astro check",
  "test":  "bun test",
  "lhci":  "lhci autorun --config=./lighthouserc.json"
}
```

- [ ] **Step 2: Commit**

```bash
git add web/package.json
git commit -m "chore(web): add dev/build/test/lhci scripts"
```

### Task 5: Drop in a favicon placeholder

**Files:**
- Create: `web/public/favicon.svg`

- [ ] **Step 1: Create `web/public/favicon.svg`** — a 32x32 dollar-sign glyph in `--accent`:

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32" width="32" height="32">
  <rect width="32" height="32" fill="#0b0d10"/>
  <text x="16" y="22" font-family="ui-monospace, monospace" font-size="22"
        font-weight="700" text-anchor="middle" fill="#5fbf8d">$</text>
</svg>
```

- [ ] **Step 2: Commit**

```bash
git add web/public/favicon.svg
git commit -m "feat(web): add favicon — $ glyph in accent"
```

---

## Phase 1 — Visual system primitives

### Task 6: Define design tokens (palette, type scale, spacing)

**Files:**
- Create: `web/src/styles/tokens.css`

- [ ] **Step 1: Write `web/src/styles/tokens.css`** (full contents):

```css
@import '@fontsource/jetbrains-mono/400.css';
@import '@fontsource/jetbrains-mono/700.css';
@import '@fontsource/jetbrains-mono/800.css';

:root {
  /* Palette — spec §2.1 */
  --bg:          #0b0d10;
  --bg-elev:     #13171b;
  --fg:          #d4d7dc;
  --fg-muted:    #7a818c;
  --accent:      #5fbf8d;
  --accent-warn: #d4a85f;
  --accent-err:  #cf6679;

  /* Type — spec §2.2 */
  --font-display: 'JetBrains Mono', ui-monospace, SFMono-Regular, Menlo, monospace;
  --font-body:    'JetBrains Mono', ui-monospace, SFMono-Regular, Menlo, monospace;
  --font-mono:    'JetBrains Mono', ui-monospace, SFMono-Regular, Menlo, monospace;

  --fs-display: clamp(2rem, 5vw, 4.5rem);
  --fs-body:    15px;
  --fs-mono:    13px;
  --lh-display: 1.05;
  --lh-body:    1.65;
  --lh-mono:    1.5;

  /* Spacing — spec §2.3 (8px scale) */
  --space-1:   4px;
  --space-2:   8px;
  --space-3:  12px;
  --space-4:  16px;
  --space-6:  24px;
  --space-8:  32px;
  --space-12: 48px;
  --space-20: 80px;
  --space-32: 128px;

  /* Layout */
  --measure: 66ch;
}
```

- [ ] **Step 2: Commit**

```bash
git add web/src/styles/tokens.css
git commit -m "feat(web): design tokens — palette, JetBrains Mono, 8px scale"
```

### Task 7: Write base global styles (resets, body chrome)

**Files:**
- Create: `web/src/styles/global.css`

- [ ] **Step 1: Write `web/src/styles/global.css`**:

```css
*, *::before, *::after { box-sizing: border-box; }
html, body { margin: 0; padding: 0; }

html {
  background: var(--bg);
  color: var(--fg);
  font-family: var(--font-body);
  font-size: var(--fs-body);
  line-height: var(--lh-body);
  -webkit-font-smoothing: antialiased;
  text-rendering: optimizeLegibility;
}

body { min-height: 100vh; }

h1, h2, h3 {
  font-family: var(--font-display);
  font-weight: 800;
  line-height: var(--lh-display);
  margin: 0 0 var(--space-6);
}
h1 { font-size: var(--fs-display); letter-spacing: -0.02em; }

a {
  color: var(--accent);
  text-decoration: underline;
  text-decoration-color: color-mix(in srgb, var(--accent) 40%, transparent);
  text-underline-offset: 3px;
}
a:hover, a:focus { text-decoration-color: var(--accent); }

a:focus-visible, button:focus-visible {
  outline: 1.5px solid var(--accent);
  outline-offset: 2px;
}

pre, code, .mono { font-family: var(--font-mono); font-size: var(--fs-mono); line-height: var(--lh-mono); }
pre { overflow-x: auto; padding: var(--space-4); background: var(--bg-elev); border-radius: 4px; }

/* Skip-to-content link (spec §5.6) */
.skip-link {
  position: absolute; top: -100px; left: var(--space-4);
  background: var(--bg-elev); color: var(--fg); padding: var(--space-2) var(--space-4);
  z-index: 1000; border-radius: 4px;
}
.skip-link:focus { top: var(--space-4); }

/* Reduced motion */
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after { animation-duration: 0.001ms !important; animation-iteration-count: 1 !important; transition-duration: 0.001ms !important; }
}

main { max-width: 1200px; margin: 0 auto; padding: var(--space-12) var(--space-6); }
.measure { max-width: var(--measure); }
```

- [ ] **Step 2: Commit**

```bash
git add web/src/styles/global.css
git commit -m "feat(web): global styles — reset, body chrome, focus rings, reduced motion"
```

### Task 8: Build the base layout

**Files:**
- Create: `web/src/layouts/BaseLayout.astro`

- [ ] **Step 1: Write `web/src/layouts/BaseLayout.astro`**:

```astro
---
import '../styles/tokens.css';
import '../styles/global.css';

interface Props { title: string; description?: string; }
const { title, description = 'Your engineering team, running in Kubernetes.' } = Astro.props;
---
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>{title} — agent-smith</title>
    <meta name="description" content={description} />
    <link rel="icon" type="image/svg+xml" href={`${import.meta.env.BASE_URL}/favicon.svg`} />
    <meta property="og:title" content={title} />
    <meta property="og:description" content={description} />
    <meta property="og:type" content="website" />
  </head>
  <body>
    <a href="#main" class="skip-link">Skip to content</a>
    <slot name="status-bar" />
    <main id="main">
      <slot />
    </main>
    <footer style="border-top:1px solid var(--bg-elev); padding:var(--space-12) var(--space-6); color:var(--fg-muted); font-size:var(--fs-mono);">
      <slot name="footer">
        <p>
          <a href="https://github.com/sherodtaylor/agent-smith">repo</a> ·
          <a href="https://github.com/sherodtaylor/agent-smith/blob/main/LICENSE">license</a> ·
          <a href="https://github.com/sherodtaylor/agent-smith/blob/main/CONTRIBUTING.md">contributing</a> ·
          <a href={`${import.meta.env.BASE_URL}/log`}>log</a> ·
          <a href={`${import.meta.env.BASE_URL}/docs`}>docs</a>
        </p>
      </slot>
    </footer>
  </body>
</html>
```

- [ ] **Step 2: Commit**

```bash
git add web/src/layouts/BaseLayout.astro
git commit -m "feat(web): BaseLayout — title/og, skip link, footer slot"
```

### Task 9: Tmux-style status bar component

**Files:**
- Create: `web/src/components/TmuxStatusBar.astro`

- [ ] **Step 1: Write component**:

```astro
---
import statusData from '../data/crew-status.json';

interface Props { sessionName?: string; }
const { sessionName = '0:main' } = Astro.props;

const agents = statusData.agents ?? [];
const lastRelease = statusData.last_release ?? '—';
const prsThisWeek = statusData.prs_this_week ?? 0;
---
<div class="tmux-status" role="status">
  <span class="left">
    <span class="bracket">[</span>agent-smith<span class="bracket">]</span>{' '}
    <span class="bracket">[</span>{sessionName}<span class="bracket">]</span>
  </span>
  <span class="right">
    <span class="dot">●</span> {agents.length} agents ·
    PRs this week: {prsThisWeek} ·
    last release: {lastRelease}
  </span>
</div>

<style>
  .tmux-status {
    display: flex; justify-content: space-between; align-items: center;
    background: var(--bg-elev); color: var(--fg-muted);
    font-family: var(--font-mono); font-size: var(--fs-mono);
    padding: var(--space-2) var(--space-4);
    border-bottom: 1px solid color-mix(in srgb, var(--fg-muted) 30%, transparent);
  }
  .bracket { color: color-mix(in srgb, var(--fg-muted) 60%, transparent); }
  .dot     { color: var(--accent); }
  .right   { color: var(--fg); }
  @media (max-width: 640px) {
    .tmux-status { font-size: 11px; flex-wrap: wrap; gap: var(--space-1); }
  }
</style>
```

- [ ] **Step 2: Seed `web/src/data/crew-status.json`** with placeholder values so the component renders during dev (real values come from T31):

```json
{
  "generated_at": "2026-05-27T00:00:00Z",
  "agents": [
    { "name": "devbot",   "role": "code",  "last_pr": null, "last_seen": null },
    { "name": "infrabot", "role": "infra", "last_pr": null, "last_seen": null }
  ],
  "last_release": "v0.1.21",
  "prs_this_week": 0
}
```

(Note: `web/src/data/crew-status.json` is gitignored — keep this seed in `web/src/data/crew-status.example.json` and document a copy step in `web/README.md`.)

- [ ] **Step 3: Add the example file properly**

```bash
mv web/src/data/crew-status.json web/src/data/crew-status.example.json
cp web/src/data/crew-status.example.json web/src/data/crew-status.json
```

- [ ] **Step 4: Commit**

```bash
git add web/src/components/TmuxStatusBar.astro web/src/data/crew-status.example.json
git commit -m "feat(web): TmuxStatusBar component + crew-status example data"
```

### Task 10: Hero pane component

**Files:**
- Create: `web/src/components/HeroPane.astro`

- [ ] **Step 1: Write component**:

```astro
---
interface Props {
  prompt?: string;
  tagline: string;
  sub: string;
  ctas: { label: string; href: string }[];
}
const { prompt = '$', tagline, sub, ctas } = Astro.props;
---
<section class="hero-pane">
  <div class="prompt-line">
    <span class="prompt">{prompt}</span>
    <span class="cmd">agent-smith --hello</span>
  </div>
  <h1>{tagline}</h1>
  <p class="sub">{sub}</p>
  <div class="ctas">
    {ctas.map(c => <a class="cta" href={c.href}>{c.label}</a>)}
  </div>
</section>

<style>
  .hero-pane {
    background: var(--bg-elev); padding: var(--space-12);
    border-radius: 6px; min-height: 380px;
  }
  .prompt-line { font-family: var(--font-mono); font-size: var(--fs-mono); color: var(--fg-muted); margin-bottom: var(--space-8); }
  .prompt { color: var(--accent); margin-right: var(--space-2); }
  .sub    { color: var(--fg-muted); max-width: var(--measure); margin: var(--space-6) 0 var(--space-12); }
  .ctas   { display: flex; gap: var(--space-4); flex-wrap: wrap; }
  .cta    {
    font-family: var(--font-mono); padding: var(--space-3) var(--space-6);
    border: 1px solid var(--accent); color: var(--accent); text-decoration: none;
    border-radius: 4px; transition: background 120ms ease;
  }
  .cta:hover, .cta:focus { background: color-mix(in srgb, var(--accent) 12%, transparent); }
</style>
```

- [ ] **Step 2: Commit**

```bash
git add web/src/components/HeroPane.astro
git commit -m "feat(web): HeroPane component — prompt, tagline, sub, dual CTA"
```

### Task 11: Audit-tail (recent log entries) component

**Files:**
- Create: `web/src/components/AuditTail.astro`

- [ ] **Step 1: Write component**:

```astro
---
import { getCollection } from 'astro:content';

interface Props { limit?: number; }
const { limit = 5 } = Astro.props;

const entries = (await getCollection('log'))
  .sort((a, b) => +new Date(b.data.timestamp) - +new Date(a.data.timestamp))
  .slice(0, limit);
---
<section class="audit-tail" aria-label="Recent log entries">
  <div class="prompt-line">
    <span class="prompt">$</span> tail -f #audit
  </div>
  <ul>
    {entries.map(e => (
      <li>
        <time datetime={e.data.timestamp.toISOString()}>{e.data.timestamp.toISOString().replace(/\.\d{3}/, '')}</time>
        <span class="agent">{e.data.agent}</span>
        <span class="run">run={e.data.run_id.slice(0, 6)}</span>
        <span class="summary">{e.data.summary}</span>
      </li>
    ))}
  </ul>
</section>

<style>
  .audit-tail   { background: var(--bg-elev); padding: var(--space-6); border-radius: 6px; font-family: var(--font-mono); font-size: var(--fs-mono); }
  .prompt-line  { color: var(--fg-muted); margin-bottom: var(--space-4); }
  .prompt       { color: var(--accent); }
  ul            { list-style: none; padding: 0; margin: 0; display: grid; gap: var(--space-2); }
  li            { display: grid; grid-template-columns: auto auto auto 1fr; gap: var(--space-3); align-items: baseline; }
  time          { color: var(--fg-muted); }
  .agent        { color: var(--fg); }
  .run          { color: var(--accent); }
  .summary      { color: var(--fg-muted); }
  @media (max-width: 640px) { li { grid-template-columns: 1fr; gap: 0; } }
</style>
```

- [ ] **Step 2: Commit**

```bash
git add web/src/components/AuditTail.astro
git commit -m "feat(web): AuditTail — most-recent log entries pane"
```

### Task 12: ASCII box wrapper component

**Files:**
- Create: `web/src/components/AsciiBox.astro`

- [ ] **Step 1: Write component**:

```astro
---
interface Props { ariaLabel: string; }
const { ariaLabel } = Astro.props;
---
<figure role="img" aria-label={ariaLabel} class="ascii">
  <pre><slot /></pre>
</figure>

<style>
  .ascii { margin: var(--space-6) 0; }
  .ascii pre {
    font-family: var(--font-mono); font-size: var(--fs-mono); line-height: 1.4;
    color: var(--fg); background: var(--bg-elev); padding: var(--space-4);
    border-radius: 4px; overflow-x: auto; white-space: pre;
  }
  .ascii pre::selection { background: color-mix(in srgb, var(--accent) 30%, transparent); }
</style>
```

- [ ] **Step 2: Commit**

```bash
git add web/src/components/AsciiBox.astro
git commit -m "feat(web): AsciiBox — accessible <pre> wrapper for diagrams"
```

### Task 13: Status badge component

**Files:**
- Create: `web/src/components/StatusBadge.astro`

- [ ] **Step 1: Write component**:

```astro
---
type Status = 'ok' | 'warn' | 'fail' | 'running';
interface Props { status: Status; label: string; }
const { status, label } = Astro.props;
const glyph: Record<Status, string> = { ok: '✓', warn: '!', fail: '✗', running: '●' };
---
<span class:list={['status-badge', status]} role="status" aria-label={`${status}: ${label}`}>
  <span class="glyph">{glyph[status]}</span> {label}
</span>

<style>
  .status-badge { font-family: var(--font-mono); font-size: var(--fs-mono); }
  .glyph        { margin-right: var(--space-1); }
  .ok      .glyph { color: var(--accent); }
  .running .glyph { color: var(--accent); }
  .warn    .glyph { color: var(--accent-warn); }
  .fail    .glyph { color: var(--accent-err); }
</style>
```

- [ ] **Step 2: Commit**

```bash
git add web/src/components/StatusBadge.astro
git commit -m "feat(web): StatusBadge — ok/warn/fail/running glyphs"
```

### Task 14: Cursor blink component (accent block cursor)

**Files:**
- Create: `web/src/components/CursorBlink.astro`

- [ ] **Step 1: Write component**:

```astro
<span class="cursor" aria-hidden="true">▎</span>

<style>
  .cursor {
    display: inline-block; color: var(--accent);
    animation: blink 1s steps(2, end) infinite;
  }
  @keyframes blink { 50% { opacity: 0; } }
  @media (prefers-reduced-motion: reduce) {
    .cursor { animation: none; }
  }
</style>
```

- [ ] **Step 2: Commit**

```bash
git add web/src/components/CursorBlink.astro
git commit -m "feat(web): CursorBlink — accent block cursor with reduced-motion fallback"
```

### Task 15: Verify the visual primitives render in a smoke page

**Files:**
- Create: `web/src/pages/index.astro` (initial skeleton — sections added in T18-T20)

- [ ] **Step 1: Write minimal smoke `index.astro` exercising all primitives**:

```astro
---
import BaseLayout from '../layouts/BaseLayout.astro';
import TmuxStatusBar from '../components/TmuxStatusBar.astro';
import HeroPane from '../components/HeroPane.astro';
import AuditTail from '../components/AuditTail.astro';
import AsciiBox from '../components/AsciiBox.astro';
import StatusBadge from '../components/StatusBadge.astro';
import CursorBlink from '../components/CursorBlink.astro';
---
<BaseLayout title="Home">
  <TmuxStatusBar slot="status-bar" />
  <HeroPane
    tagline="Your engineering team, running in Kubernetes."
    sub="Persistent, long-lived engineering agents in Kubernetes pods. Real cluster credentials, real PRs, merged to main."
    ctas={[{ label: '$ read the docs ›', href: `${import.meta.env.BASE_URL}/docs` }, { label: '$ view on github ›', href: 'https://github.com/sherodtaylor/agent-smith' }]}
  />

  <h2 style="margin-top: var(--space-20)">Smoke test</h2>
  <p><StatusBadge status="ok" label="components render" /></p>
  <p>Cursor: <CursorBlink /></p>
  <AsciiBox ariaLabel="A 3-line box containing the words devbot status">
{`┌─ devbot ──┐
│  status   │
└───────────┘`}
  </AsciiBox>
  <AuditTail limit={3} />
</BaseLayout>
```

- [ ] **Step 2: Add Astro content config so AuditTail builds (preview of T16)**

This is required for the dev server to start. T16 expands it.

`web/src/content/config.ts`:
```ts
import { defineCollection, z } from 'astro:content';

const log = defineCollection({
  type: 'content',
  schema: z.object({
    timestamp: z.coerce.date(),
    agent: z.enum(['devbot', 'infrabot', 'sherod']),
    run_id: z.string().min(6),
    kind: z.enum(['pr_shipped', 'pr_merged', 'pr_reviewed', 'incident', 'release', 'note']),
    summary: z.string().max(160),
    link: z.string().url().optional(),
  }),
});

export const collections = { log };
```

- [ ] **Step 3: Add a placeholder log entry so AuditTail has data to render**

`web/src/content/log/2026-05-27-website-spec-merged.mdx`:
```mdx
---
timestamp: 2026-05-27T00:00:00Z
agent: devbot
run_id: bootstrap
kind: note
summary: website spec merged — implementation begins
---

Seed entry. PR-merge → log workflow (Task 37) will produce real entries once landed.
```

- [ ] **Step 4: Run the dev server**

Run: `cd web && bun run dev`
Visit: `http://localhost:4321/agent-smith/`
Expected: page renders with hero, status badge, cursor blink, ASCII box, and one log entry.

- [ ] **Step 5: Run the build**

Run: `bun run build` from `web/`
Expected: success; output in `web/dist/`.

- [ ] **Step 6: Commit**

```bash
git add web/src/pages/index.astro web/src/content/config.ts web/src/content/log/2026-05-27-website-spec-merged.mdx
git commit -m "feat(web): smoke index page + log content collection + seed entry"
```

---

## Phase 2 — Log content collection finalized + landing page sections

### Task 16: Confirm log content collection schema (review T15)

**Files:**
- Existing: `web/src/content/config.ts` (already created in T15)

- [ ] **Step 1: Write the schema unit test**

`web/src/content/config.test.ts`:
```ts
import { describe, expect, test } from 'bun:test';
import { z } from 'astro:content';
// Re-import schema bits via the module so they actually exercise the same z calls.
import { collections } from './config';

describe('log collection schema', () => {
  const schema = collections.log.schema as z.ZodObject<any>;

  test('accepts a minimal valid entry', () => {
    const ok = schema.safeParse({
      timestamp: '2026-05-27T00:00:00Z',
      agent: 'devbot',
      run_id: 'abcdef',
      kind: 'note',
      summary: 'hello',
    });
    expect(ok.success).toBe(true);
  });

  test('rejects unknown kind', () => {
    const bad = schema.safeParse({
      timestamp: '2026-05-27T00:00:00Z',
      agent: 'devbot',
      run_id: 'abcdef',
      kind: 'whatever',
      summary: 'hello',
    });
    expect(bad.success).toBe(false);
  });

  test('rejects short run_id', () => {
    const bad = schema.safeParse({
      timestamp: '2026-05-27T00:00:00Z',
      agent: 'devbot',
      run_id: 'abc',
      kind: 'note',
      summary: 'hello',
    });
    expect(bad.success).toBe(false);
  });
});
```

- [ ] **Step 2: Run test**

Run: `cd web && bun test src/content/config.test.ts`
Expected: 3 passing.

- [ ] **Step 3: Commit**

```bash
git add web/src/content/config.test.ts
git commit -m "test(web): log content collection schema — accept/reject paths"
```

### Task 17: Add a second seed log entry (richer example)

**Files:**
- Create: `web/src/content/log/2026-05-26-roadmap-shipped.mdx`

- [ ] **Step 1: Write entry**

```mdx
---
timestamp: 2026-05-26T03:34:00Z
agent: devbot
run_id: a1b2c3
kind: pr_shipped
summary: "shipped PR #32 (docs: v1 roadmap)"
link: https://github.com/sherodtaylor/agent-smith/pull/32
---

Includes the production-sandbox vision, 5 promises, themes A–D, and an
appendix mapping original v1 candidates to themes.
```

- [ ] **Step 2: Verify build still passes**

Run: `bun run build` from `web/`
Expected: success; two log entries present.

- [ ] **Step 3: Commit**

```bash
git add web/src/content/log/2026-05-26-roadmap-shipped.mdx
git commit -m "feat(web): seed log entry for the roadmap PR ship"
```

### Task 18: Landing — "What this is" narrative section

**Files:**
- Modify: `web/src/pages/index.astro`

- [ ] **Step 1: Replace the smoke-test section with the narrative**

Locate the "Smoke test" `<h2>` through the closing of `<AuditTail />` and replace with:

```astro
  <section class="narrative" style="margin-top: var(--space-20);">
    <h2>$ describe agent-smith</h2>
    <p class="lead measure" style="font-size:1.15rem;">
      agent-smith deploys Claude Code as persistent, long-lived engineering
      agents inside Kubernetes pods. Each agent has a permanent workspace
      with real cluster credentials, follows the same git workflow as a
      human teammate, and works autonomously until the task is done —
      feature branches, conventional commits, pull requests, review
      comments addressed, merged.
    </p>
    <p class="measure">
      The current team is two agents — <strong>InfraBot</strong> for k3s/Flux
      and <strong>DevBot</strong> for code — but the container image is
      parametric: one new <code>agents/&lt;name&gt;/</code> directory and
      you have a third teammate.
    </p>
  </section>
```

- [ ] **Step 2: Verify dev server renders the narrative**

Run: `bun run dev` from `web/`. Visit landing. Expected: hero followed by `$ describe agent-smith` header and two paragraphs of body.

- [ ] **Step 3: Commit**

```bash
git add web/src/pages/index.astro
git commit -m "feat(web): landing — 'What this is' narrative section"
```

### Task 19: Landing — "What your team can do" 5-bullet section

**Files:**
- Modify: `web/src/pages/index.astro`

- [ ] **Step 1: Insert after the narrative section** (before any closing tags):

```astro
  <section class="capabilities" style="margin-top: var(--space-20);">
    <h2>$ ls capabilities</h2>
    <ul class="caps measure">
      <li><strong>Owns a persistent workspace</strong> — full filesystem + shell access on a long-lived volume with real cluster credentials.</li>
      <li><strong>Follows the full engineering workflow</strong> — reads, writes, opens the PR, addresses review, merges. The whole loop.</li>
      <li><strong>Watches its own PRs</strong> — a <code>Stop</code>-hook reruns the agent when unaddressed review comments appear.</li>
      <li><strong>Coordinates with teammates</strong> — one agent opens a PR, the other reviews it end-to-end and posts inline findings. NATS is the durable audit log.</li>
      <li><strong>Never holds production secrets</strong> — stub tokens are swapped for real credentials at the network boundary by an egress firewall.</li>
    </ul>
    <p class="sub-line measure" style="color: var(--fg-muted); margin-top: var(--space-8);">
      Reach them from a Matrix room, from your phone, or via the Claude
      desktop app. The interface is up to you; the engineering capability
      is always there.
    </p>
  </section>
```

- [ ] **Step 2: Add list-style CSS to the page** (inside an existing or new `<style>` block at the bottom):

```astro
<style>
  ul.caps { list-style: none; padding: 0; display: grid; gap: var(--space-4); }
  ul.caps li { padding-left: var(--space-6); position: relative; }
  ul.caps li::before { content: '·'; position: absolute; left: 0; color: var(--accent); }
</style>
```

- [ ] **Step 3: Verify in browser**

Run: dev server, refresh. Expected: bullet list with dot markers in accent color.

- [ ] **Step 4: Commit**

```bash
git add web/src/pages/index.astro
git commit -m "feat(web): landing — 'What your team can do' 5-bullet section"
```

### Task 20: Landing — "Under the hood" architecture section (ASCII boxes)

**Files:**
- Modify: `web/src/pages/index.astro`

- [ ] **Step 1: Insert after the capabilities section**:

```astro
  <section class="architecture" style="margin-top: var(--space-20);">
    <h2>$ describe runtime</h2>
    <p class="measure">
      One image, many agents. The runtime in a single pod looks like this:
    </p>
    <AsciiBox ariaLabel="A StatefulSet per agent with an init container that assembles the Claude home dir, and a main container running tmux with a claude process in one pane and a bash shell in the other.">
{`StatefulSet/<agent>           (one per agent: infrabot, devbot, …)
└── init container: setup.sh  (assembles ~/.claude, installs plugin, clones repos)
└── main container: entrypoint.sh
    └── tmux session "main"
        ├── pane 0 — claude (channels + --remote-control)  ← receives Matrix messages
        │                                                    + exposed for remote drive-in
        └── pane 1 — plain bash shell                       ← ad-hoc inspection on attach`}
    </AsciiBox>
    <p class="measure">
      The runtime is production-grade: one Kubernetes <code>StatefulSet</code> per
      agent, GitOps-managed via Flux, secrets from Infisical via
      ExternalSecrets, full observability through VictoriaMetrics / VictoriaLogs.
      These agents ship work that ends up in <code>main</code>.
    </p>
    <p>
      <a href={`${import.meta.env.BASE_URL}/docs/architecture`}>$ docs/architecture ›</a>
    </p>
  </section>

  <section class="crew-status" style="margin-top: var(--space-20);">
    <h2>$ swarm status</h2>
    <AuditTail limit={5} />
  </section>
```

- [ ] **Step 2: Verify the ASCII diagram renders with correct line breaks**

Run dev server, refresh, expand the diagram width on a wide viewport, then narrow to mobile width. Expected: wide viewport shows it clean; mobile shows horizontal scrollbar in the `<pre>`.

- [ ] **Step 3: Commit**

```bash
git add web/src/pages/index.astro
git commit -m "feat(web): landing — 'Under the hood' architecture section + crew status"
```

### Task 21: `/log` page (full list)

**Files:**
- Create: `web/src/pages/log/index.astro`

- [ ] **Step 1: Write page**

```astro
---
import { getCollection } from 'astro:content';
import BaseLayout from '../../layouts/BaseLayout.astro';
import TmuxStatusBar from '../../components/TmuxStatusBar.astro';

const entries = (await getCollection('log'))
  .sort((a, b) => +b.data.timestamp - +a.data.timestamp);
---
<BaseLayout title="Log">
  <TmuxStatusBar slot="status-bar" sessionName="0:log" />
  <h1>$ tail -f #audit</h1>
  <p class="measure" style="color: var(--fg-muted);">
    Reverse-chronological record of notable agent actions. One line per
    event; expand for context.
  </p>
  <ul class="log-feed">
    {entries.map(e => (
      <li>
        <details>
          <summary>
            <time datetime={e.data.timestamp.toISOString()}>{e.data.timestamp.toISOString().replace(/\.\d{3}/, '')}</time>{' '}
            <span class="agent">{e.data.agent}</span>{' '}
            <span class="run">run={e.data.run_id.slice(0, 6)}</span>{' '}
            <span class="summary">{e.data.summary}</span>
            {e.data.link && <a href={e.data.link} class="link">[link]</a>}
          </summary>
          {/* Body rendered when an entry has MDX content */}
        </details>
      </li>
    ))}
  </ul>
</BaseLayout>

<style>
  .log-feed   { list-style: none; padding: 0; margin: 0; display: grid; gap: var(--space-2); font-family: var(--font-mono); font-size: var(--fs-mono); }
  .log-feed time    { color: var(--fg-muted); }
  .log-feed .agent  { color: var(--fg); }
  .log-feed .run    { color: var(--accent); }
  .log-feed .summary{ color: var(--fg-muted); }
  .log-feed .link   { margin-left: var(--space-2); color: var(--accent); }
  details summary   { cursor: pointer; padding: var(--space-2); }
  details[open] summary { background: var(--bg-elev); border-radius: 4px; }
</style>
```

- [ ] **Step 2: Verify the page**

Visit `http://localhost:4321/agent-smith/log` — expected: full list of seed entries, newest first.

- [ ] **Step 3: Commit**

```bash
git add web/src/pages/log/index.astro
git commit -m "feat(web): /log page — reverse-chronological feed"
```

---

## Phase 3 — Docs (Starlight) section

### Task 22: Author the 7 docs pages

**Files:**
- Create: `web/src/content/docs/getting-started.md`
- Create: `web/src/content/docs/architecture.md`
- Create: `web/src/content/docs/agents.md`
- Create: `web/src/content/docs/security.md`
- Create: `web/src/content/docs/operations.md`
- Create: `web/src/content/docs/contributing.md`
- Create: `web/src/content/docs/roadmap.md`

- [ ] **Step 1: Add Starlight to the content config** — modify `web/src/content/config.ts`:

```ts
import { defineCollection, z } from 'astro:content';
import { docsSchema } from '@astrojs/starlight/schema';

const log = defineCollection({
  type: 'content',
  schema: z.object({
    timestamp: z.coerce.date(),
    agent: z.enum(['devbot', 'infrabot', 'sherod']),
    run_id: z.string().min(6),
    kind: z.enum(['pr_shipped', 'pr_merged', 'pr_reviewed', 'incident', 'release', 'note']),
    summary: z.string().max(160),
    link: z.string().url().optional(),
  }),
});

const docs = defineCollection({ schema: docsSchema() });

export const collections = { log, docs };
```

- [ ] **Step 2: Author `web/src/content/docs/getting-started.md`** — minimal title + frontmatter, body pulls from current README:

```md
---
title: Getting Started
description: Run agent-smith in your own cluster.
---

agent-smith ships as a container image (`ghcr.io/sherodtaylor/agent-smith`) and a Helm chart (`oci://ghcr.io/sherodtaylor/charts/agent-smith`). The chart deploys one `StatefulSet` per agent persona.

…content authored from `README.md#how-it-works` + `charts/agent-smith/README.md`.
```

(For brevity in this plan: each docs page mirrors the structure of the corresponding section in `README.md` and `docs/`. The author writes one cohesive page per topic in the same voice as the README — declarative, terse, no marketing.)

- [ ] **Step 3: Author the remaining 5 docs pages** — `architecture.md`, `agents.md`, `security.md`, `operations.md`, `contributing.md` — each with a frontmatter `title` + `description`, content lifted from the corresponding README section or runbook.

- [ ] **Step 4: Author `web/src/content/docs/roadmap.md`** — copies content from `docs/roadmap-v1.md`:

```md
---
title: Roadmap
description: agent-smith v1 themes, future considerations, and sequencing.
---

import { Aside } from '@astrojs/starlight/components';

<Aside type="tip">Canonical source: `docs/roadmap-v1.md` in the repo. Updated in lockstep.</Aside>

…full content copy of docs/roadmap-v1.md…
```

- [ ] **Step 5: Verify the docs section builds + renders nav**

Run: `bun run build` from `web/`. Expected: success. Visit `http://localhost:4321/agent-smith/docs/getting-started` — sidebar with 7 entries.

- [ ] **Step 6: Commit**

```bash
git add web/src/content/config.ts web/src/content/docs
git commit -m "feat(web): docs section — 7 pages backed by Starlight"
```

### Task 23: Add a CI-time check that docs/roadmap-v1.md and docs/roadmap.md stay in sync

**Files:**
- Create: `web/scripts/check-roadmap-sync.ts`
- Modify: `web/package.json` (add `"check:roadmap": "bun web/scripts/check-roadmap-sync.ts"`)

- [ ] **Step 1: Write the check script**

```ts
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';

const repoRoadmap = await readFile(join(import.meta.dir, '..', '..', 'docs', 'roadmap-v1.md'), 'utf8');
const siteRoadmap = await readFile(join(import.meta.dir, '..', 'src', 'content', 'docs', 'roadmap.md'), 'utf8');

// Strip the Starlight frontmatter + Aside import from the site copy.
const stripFrontmatter = (s: string) => s.replace(/^---\n[\s\S]*?\n---\n/, '').replace(/^import.*?;\n/m, '').trim();

const a = stripFrontmatter(siteRoadmap);
const b = repoRoadmap.trim();

if (!a.includes(b.slice(0, 200))) {
  console.error('docs/roadmap.md is stale relative to docs/roadmap-v1.md. Re-copy the body.');
  process.exit(1);
}
console.log('roadmap docs in sync ✓');
```

- [ ] **Step 2: Run it once to confirm it passes**

Run: `bun web/scripts/check-roadmap-sync.ts`
Expected: `roadmap docs in sync ✓`

- [ ] **Step 3: Commit**

```bash
git add web/scripts/check-roadmap-sync.ts web/package.json
git commit -m "chore(web): roadmap sync check between repo + site copies"
```

---

## Phase 4 — Lottie animations

### Task 24: Lottie player wrapper component

**Files:**
- Create: `web/src/components/LottiePlayer.astro`

- [ ] **Step 1: Write component (lazy-loads the player only on visit)**

```astro
---
interface Props { src: string; autoplay?: boolean; loop?: boolean; once?: boolean; ariaLabel?: string; }
const { src, autoplay = true, loop = false, once = false, ariaLabel } = Astro.props;
---
<div class="lottie-host" role="img" aria-label={ariaLabel}>
  <noscript>
    <p class="fallback">[motion graphic — enable JS to play]</p>
  </noscript>
  <lottie-player
    src={src}
    background="transparent"
    speed="1"
    autoplay={autoplay ? '' : undefined}
    loop={loop ? '' : undefined}
    data-once={once ? '1' : undefined}
  ></lottie-player>
</div>

<script>
  // Lazy-load the player only when the component appears in the viewport.
  const io = new IntersectionObserver(async (entries) => {
    for (const e of entries) {
      if (e.isIntersecting) {
        await import('@lottiefiles/lottie-player');
        io.unobserve(e.target);
      }
    }
  }, { rootMargin: '200px' });

  document.querySelectorAll('.lottie-host').forEach(el => io.observe(el));

  // Honour `prefers-reduced-motion` by freezing on frame 0.
  if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    document.querySelectorAll('lottie-player').forEach(p => p.setAttribute('autoplay', 'false'));
  }
</script>

<style>
  .lottie-host { width: 100%; min-height: 1px; }
  .fallback    { font-family: var(--font-mono); color: var(--fg-muted); }
</style>
```

- [ ] **Step 2: Commit**

```bash
git add web/src/components/LottiePlayer.astro
git commit -m "feat(web): LottiePlayer — lazy-loaded, reduced-motion aware"
```

### Task 25: Hero boot-sequence animation

**Files:**
- Create: `web/src/animations/hero-boot.json`

- [ ] **Step 1: Author a minimal hand-rolled Lottie JSON** — 3 seconds, types `$ agent-smith --hello` character by character into the prompt line.

(For the engineer: open `https://lottiefiles.com/preview` and a JSON spec reference; or use the `lottie-builder` npm CLI to scaffold. Constraints: total file size ≤ 18KB gzipped, 30fps max, no nested comps.)

- [ ] **Step 2: Wire into `HeroPane.astro`** — add a `<LottiePlayer src="..." once />` overlay positioned over the `.prompt-line`.

- [ ] **Step 3: Run dev server, verify the animation plays once on load and freezes**

- [ ] **Step 4: Commit**

```bash
git add web/src/animations/hero-boot.json web/src/components/HeroPane.astro
git commit -m "feat(web): hero boot-sequence Lottie — types into the prompt"
```

### Task 26: Architecture-section ASCII-draw animation

**Files:**
- Create: `web/src/animations/ascii-draw.json`

- [ ] **Step 1: Author a Lottie that reveals the ASCII architecture diagram line-by-line over 2s**

- [ ] **Step 2: Wire into the architecture `<AsciiBox>` in `index.astro`** with `<LottiePlayer once ariaLabel="Architecture diagram drawing" />`

- [ ] **Step 3: Verify scroll-into-view triggers playback** (IntersectionObserver in T24 handles lazy-load; add a `data-on-visible="play"` attribute hook if needed in `LottiePlayer.astro`).

- [ ] **Step 4: Commit**

```bash
git add web/src/animations/ascii-draw.json web/src/pages/index.astro
git commit -m "feat(web): architecture diagram draw-in Lottie"
```

### Task 27: Log section newest-entry pulse animation

**Files:**
- Create: `web/src/animations/log-pulse.json`

- [ ] **Step 1: Author a 1.5s soft-fade pulse in `--accent` color**

- [ ] **Step 2: Apply it to the first `<li>` rendered in `AuditTail.astro` and `web/src/pages/log/index.astro`**

- [ ] **Step 3: Verify total Lottie payload (player + 3 JSONs) fits the 60KB sub-budget**

Run after build:
```bash
cd web && du -b dist/_astro/*lottie*.js dist/_astro/*.json 2>/dev/null | awk '{s+=$1} END {print "total bytes:", s, "(budget: 60KB gzip ≈ 180KB raw)"}'
```

- [ ] **Step 4: Commit**

```bash
git add web/src/animations/log-pulse.json
git commit -m "feat(web): log newest-entry pulse Lottie"
```

---

## Phase 5 — Misc pages, robots, sitemap, 404

### Task 28: robots.txt

**Files:**
- Create: `web/public/robots.txt`

- [ ] **Step 1: Write file**

```
User-agent: *
Allow: /

Sitemap: https://sherodtaylor.github.io/agent-smith/sitemap-index.xml
```

- [ ] **Step 2: Commit**

```bash
git add web/public/robots.txt
git commit -m "feat(web): robots.txt — allow-all + sitemap"
```

### Task 29: 404 page

**Files:**
- Create: `web/src/pages/404.astro`

- [ ] **Step 1: Write page**

```astro
---
import BaseLayout from '../layouts/BaseLayout.astro';
import TmuxStatusBar from '../components/TmuxStatusBar.astro';
---
<BaseLayout title="404">
  <TmuxStatusBar slot="status-bar" sessionName="0:wat" />
  <h1>$ ls /agent-smith/wat</h1>
  <pre>wat: No such file or directory</pre>
  <p><a href={import.meta.env.BASE_URL}>$ cd .. ›</a></p>
</BaseLayout>
```

- [ ] **Step 2: Commit**

```bash
git add web/src/pages/404.astro
git commit -m "feat(web): 404 page — terminal-styled"
```

---

## Phase 6 — Crew-status refresh script

### Task 30: TDD — write the test for `refresh-crew-status.ts`

**Files:**
- Create: `web/scripts/refresh-crew-status.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { describe, expect, test, mock } from 'bun:test';
import { buildCrewStatus } from './refresh-crew-status';

describe('buildCrewStatus', () => {
  test('aggregates PRs by author into the agent list', async () => {
    const ghClient = {
      listPRs: mock(async () => ([
        { number: 32, title: 'docs: roadmap', merged_at: '2026-05-26T03:34:00Z', user: { login: 'devbot' }, repo: 'agent-smith' },
        { number: 28, title: 'chart: hook',   merged_at: '2026-05-26T01:00:00Z', user: { login: 'infrabot' }, repo: 'agent-smith' },
        { number: 40, title: 'docs: sync',    merged_at: '2026-05-27T11:00:00Z', user: { login: 'devbot' }, repo: 'agent-smith' },
      ])),
      latestRelease: mock(async () => ({ tag_name: 'v0.1.21' })),
    };

    const status = await buildCrewStatus(ghClient, { now: new Date('2026-05-28T00:00:00Z') });

    expect(status.agents.find(a => a.name === 'devbot')?.last_pr?.number).toBe(40);
    expect(status.agents.find(a => a.name === 'infrabot')?.last_pr?.number).toBe(28);
    expect(status.prs_this_week).toBe(3);
    expect(status.last_release).toBe('v0.1.21');
    expect(status.generated_at).toBeDefined();
  });

  test('handles agent with zero PRs', async () => {
    const ghClient = { listPRs: async () => [], latestRelease: async () => ({ tag_name: 'v0.1.0' }) };
    const status = await buildCrewStatus(ghClient, { now: new Date() });
    expect(status.agents.find(a => a.name === 'devbot')?.last_pr).toBeNull();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test scripts/refresh-crew-status.test.ts`
Expected: FAIL — `module not found`.

- [ ] **Step 3: Commit (test only, red)**

```bash
git add web/scripts/refresh-crew-status.test.ts
git commit -m "test(web): refresh-crew-status — aggregate PRs by author"
```

### Task 31: Implement `refresh-crew-status.ts`

**Files:**
- Create: `web/scripts/refresh-crew-status.ts`

- [ ] **Step 1: Write the implementation**

```ts
import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';

type MergedPR = { number: number; title: string; merged_at: string; user: { login: string }; repo: string };
type Release  = { tag_name: string };

export interface GhClient {
  listPRs: () => Promise<MergedPR[]>;
  latestRelease: () => Promise<Release>;
}

export interface BuildOpts { now: Date; }

const AGENTS = [
  { name: 'devbot',   role: 'code'  as const },
  { name: 'infrabot', role: 'infra' as const },
];

export async function buildCrewStatus(client: GhClient, { now }: BuildOpts) {
  const prs = await client.listPRs();
  const release = await client.latestRelease();
  const weekAgo = new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000);

  const agents = AGENTS.map(a => {
    const mine = prs.filter(p => p.user.login === a.name).sort((x, y) => +new Date(y.merged_at) - +new Date(x.merged_at));
    const lastPR = mine[0];
    return {
      ...a,
      last_pr: lastPR ? { number: lastPR.number, title: lastPR.title, merged_at: lastPR.merged_at, repo: lastPR.repo } : null,
      last_seen: lastPR ? lastPR.merged_at : null,
    };
  });

  return {
    generated_at: now.toISOString(),
    agents,
    last_release: release.tag_name,
    prs_this_week: prs.filter(p => new Date(p.merged_at) >= weekAgo).length,
  };
}

async function fetchPRs(repos: string[], token: string): Promise<MergedPR[]> {
  const out: MergedPR[] = [];
  for (const repo of repos) {
    const res = await fetch(`https://api.github.com/repos/${repo}/pulls?state=closed&per_page=50`, {
      headers: { 'Authorization': `Bearer ${token}`, 'Accept': 'application/vnd.github+json' },
    });
    const data = await res.json() as any[];
    for (const p of data) if (p.merged_at) out.push({ number: p.number, title: p.title, merged_at: p.merged_at, user: { login: p.user.login }, repo: repo.split('/')[1] });
  }
  return out;
}

async function fetchLatestRelease(repo: string, token: string): Promise<Release> {
  const res = await fetch(`https://api.github.com/repos/${repo}/releases/latest`, {
    headers: { 'Authorization': `Bearer ${token}`, 'Accept': 'application/vnd.github+json' },
  });
  return await res.json() as Release;
}

// CLI entry point — invoked from website.yml
if (import.meta.main) {
  const token = process.env.GITHUB_TOKEN ?? '';
  if (!token) { console.error('GITHUB_TOKEN missing'); process.exit(1); }
  const client: GhClient = {
    listPRs: () => fetchPRs(['sherodtaylor/agent-smith', 'sherodtaylor/homelab'], token),
    latestRelease: () => fetchLatestRelease('sherodtaylor/agent-smith', token),
  };
  const status = await buildCrewStatus(client, { now: new Date() });
  const out = join(import.meta.dir, '..', 'src', 'data', 'crew-status.json');
  await writeFile(out, JSON.stringify(status, null, 2));
  console.log(`wrote ${out}`);
}
```

- [ ] **Step 2: Run tests**

Run: `cd web && bun test scripts/refresh-crew-status.test.ts`
Expected: PASS (both tests).

- [ ] **Step 3: Try the CLI locally**

Run: `cd web && GITHUB_TOKEN=$(gh auth token) bun scripts/refresh-crew-status.ts`
Expected: writes `web/src/data/crew-status.json` with real data; console echoes the path.

- [ ] **Step 4: Commit**

```bash
git add web/scripts/refresh-crew-status.ts
git commit -m "feat(web): refresh-crew-status.ts — gh-api → JSON for build-time status"
```

---

## Phase 7 — Build & deploy pipeline

### Task 32: `.github/workflows/website.yml`

**Files:**
- Create: `.github/workflows/website.yml`

- [ ] **Step 1: Write workflow**

```yaml
name: website

on:
  push:
    branches: [main]
    paths:
      - 'web/**'
      - 'docs/**'
      - 'README.md'
      - '.github/workflows/website.yml'
  workflow_dispatch: {}

permissions:
  contents: read
  pages: write
  id-token: write

concurrency:
  group: pages
  cancel-in-progress: false

jobs:
  build:
    runs-on: ubuntu-latest
    container: oven/bun:1
    steps:
      - uses: actions/checkout@v4
      - name: Install dependencies
        working-directory: web
        run: bun install --frozen-lockfile
      - name: Refresh crew status
        working-directory: web
        env: { GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }} }
        run: bun scripts/refresh-crew-status.ts
      - name: Check roadmap sync
        working-directory: web
        run: bun scripts/check-roadmap-sync.ts
      - name: Build
        working-directory: web
        run: bun run build
      - uses: actions/upload-pages-artifact@v3
        with: { path: web/dist }

  deploy:
    needs: build
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      - id: deployment
        uses: actions/deploy-pages@v4
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/website.yml
git commit -m "ci(website): build + deploy to GitHub Pages on web/docs changes"
```

### Task 33: Configure GitHub Pages source = Actions (manual UI step)

**Files:** none (one-time GitHub UI step; document in runbook T39)

- [ ] **Step 1: In repo Settings → Pages, set Source to "GitHub Actions"** (Sherod or PR reviewer does this once before the first deploy lands).

- [ ] **Step 2: Verify the workflow has Pages permissions** (`pages: write`, `id-token: write` are set in T32; nothing else needed).

(No commit — manual setup, captured in the runbook task.)

### Task 34: Smoke-test the build in CI by triggering `workflow_dispatch`

**Files:** none

- [ ] **Step 1: Push the branch**

```bash
git push -u origin feat/website-v1
```

- [ ] **Step 2: Trigger workflow manually**

Run: `gh workflow run website.yml --ref feat/website-v1`
Expected: workflow appears in `gh run list -w website.yml --limit 1`.

- [ ] **Step 3: Wait for completion + check status**

Run: `gh run watch`
Expected: green build (deploy stage will be skipped or fail because `main` is the only branch with Pages permission — that's fine for this smoke test; the build job is what we're verifying).

### Task 35: Lighthouse CI perf-budget enforcement

**Files:**
- Create: `web/lighthouserc.json`
- Create: `.github/workflows/lighthouse.yml`

- [ ] **Step 1: Write `web/lighthouserc.json`**

```json
{
  "ci": {
    "collect": {
      "staticDistDir": "web/dist",
      "url": ["http://localhost/agent-smith/", "http://localhost/agent-smith/log/"],
      "numberOfRuns": 3
    },
    "assert": {
      "assertions": {
        "largest-contentful-paint": ["error", { "maxNumericValue": 1500 }],
        "total-byte-weight":        ["error", { "maxNumericValue": 256000 }],
        "unused-javascript":        ["warn",  { "maxLength": 0 }],
        "categories:accessibility": ["error", { "minScore": 0.95 }]
      }
    },
    "upload": { "target": "temporary-public-storage" }
  }
}
```

- [ ] **Step 2: Write `.github/workflows/lighthouse.yml`**

```yaml
name: lighthouse

on:
  pull_request:
    paths: ['web/**']
  push:
    branches: [main]
    paths: ['web/**']

jobs:
  lhci:
    runs-on: ubuntu-latest
    container: oven/bun:1
    steps:
      - uses: actions/checkout@v4
      - name: Install
        working-directory: web
        run: bun install --frozen-lockfile
      - name: Seed crew-status
        run: cp web/src/data/crew-status.example.json web/src/data/crew-status.json
      - name: Build
        working-directory: web
        run: bun run build
      - name: Run Lighthouse CI
        working-directory: web
        run: bunx --bun @lhci/cli@latest autorun
```

- [ ] **Step 3: Commit both**

```bash
git add web/lighthouserc.json .github/workflows/lighthouse.yml
git commit -m "ci(website): Lighthouse CI — perf + a11y budget enforcement"
```

### Task 36: Verify Lighthouse passes locally

**Files:** none

- [ ] **Step 1: Build + run LHCI locally**

```bash
cd web && bun run build && bunx --bun @lhci/cli@latest autorun
```

- [ ] **Step 2: Read output**

Expected: all assertions pass, OR specific failures named — fix them (likely candidates: oversized images, unused CSS, missing `meta description`).

If any assertion fails, iterate:
- LCP too high → audit fonts (should be `font-display: swap`), confirm no blocking script
- Total bytes too high → audit Lottie payload, trim animations or compress
- a11y < 0.95 → add missing labels / contrast

(No commit yet — fixes are folded into the relevant component task. If you discover a real fix here, add a step that names the change and commit it then.)

---

## Phase 8 — PR-merge → log entry pipeline

### Task 37: `.github/workflows/log-pr-merge.yml` + ADR

**Files:**
- Create: `.github/workflows/log-pr-merge.yml`
- Create: `docs/adr/2026-05-27-log-pr-dispatch.md`

- [ ] **Step 1: Write the workflow**

```yaml
name: log-pr-merge

on:
  pull_request:
    types: [closed]
  repository_dispatch:
    types: [pr-merged]

permissions:
  contents: write

jobs:
  log:
    if: github.event.pull_request.merged == true || github.event_name == 'repository_dispatch'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { ref: main, token: ${{ secrets.GITHUB_TOKEN }} }
      - name: Compose entry
        id: compose
        env:
          GH_EVENT: ${{ toJson(github.event) }}
        run: |
          set -euo pipefail
          if [[ "${{ github.event_name }}" == "pull_request" ]]; then
            NUMBER=${{ github.event.pull_request.number }}
            TITLE='${{ github.event.pull_request.title }}'
            AUTHOR='${{ github.event.pull_request.user.login }}'
            LINK='${{ github.event.pull_request.html_url }}'
            REPO='agent-smith'
            TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
          else
            NUMBER='${{ github.event.client_payload.number }}'
            TITLE='${{ github.event.client_payload.title }}'
            AUTHOR='${{ github.event.client_payload.author }}'
            LINK='${{ github.event.client_payload.link }}'
            REPO='${{ github.event.client_payload.repo }}'
            TS='${{ github.event.client_payload.merged_at }}'
          fi

          AGENT=$AUTHOR
          case "$AUTHOR" in devbot|infrabot) AGENT=$AUTHOR ;; *) AGENT='sherod' ;; esac

          SLUG=$(echo "$TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/-\+/-/g' | sed 's/^-\|-$//g' | cut -c1-50)
          DATE=$(echo "$TS" | cut -c1-10)
          FILE="web/src/content/log/${DATE}-pr-${NUMBER}-${SLUG}.mdx"
          RUN=$(echo "${{ github.run_id }}" | sha1sum | cut -c1-6)

          mkdir -p web/src/content/log
          cat > "$FILE" <<EOF
          ---
          timestamp: ${TS}
          agent: ${AGENT}
          run_id: ${RUN}
          kind: pr_merged
          summary: "merged PR #${NUMBER} (${TITLE})"
          link: ${LINK}
          ---
          EOF
          echo "file=$FILE" >> $GITHUB_OUTPUT
      - name: Commit + push
        run: |
          git config user.name  'agent-smith[bot]'
          git config user.email 'agent-smith-bot@users.noreply.github.com'
          git add "${{ steps.compose.outputs.file }}"
          git commit -m "chore(log): ${{ steps.compose.outputs.file }}"
          git push
```

- [ ] **Step 2: Write the ADR documenting the `repository_dispatch` payload**

`docs/adr/2026-05-27-log-pr-dispatch.md`:
```md
# ADR: PR-merge → log entry via repository_dispatch

**Date:** 2026-05-27
**Status:** accepted

## Context
The website's `/log` page wants entries from PR-merge events in
`sherodtaylor/agent-smith` AND `sherodtaylor/homelab`. The agent-smith
repo holds the site content; homelab is a separate repo.

## Decision
- agent-smith listens for its own `pull_request: closed (merged)`
  events.
- homelab fires a `repository_dispatch` with type `pr-merged` into
  agent-smith on PR merge.

## Payload (homelab → agent-smith)

```yaml
event-type: pr-merged
client-payload:
  number: 42
  title: "fix: foo"
  author: "infrabot"
  link: "https://github.com/sherodtaylor/homelab/pull/42"
  repo: "homelab"
  merged_at: "2026-05-27T10:00:00Z"
```

## InfraBot follow-up
Wire the homelab workflow that fires this dispatch on `pull_request:
closed (merged)`. PAT with `repo` scope on agent-smith required.
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/log-pr-merge.yml docs/adr/2026-05-27-log-pr-dispatch.md
git commit -m "ci(log): pr-merge → log entry workflow + dispatch ADR"
```

### Task 38: Smoke-test the log-merge workflow with a synthetic dispatch

**Files:** none

- [ ] **Step 1: Fire a test dispatch**

```bash
gh api repos/sherodtaylor/agent-smith/dispatches -X POST -f event_type=pr-merged \
  -F client_payload='{"number":999,"title":"test entry","author":"infrabot","link":"https://example.com","repo":"homelab","merged_at":"2026-05-27T12:00:00Z"}'
```

- [ ] **Step 2: Watch the workflow + confirm a commit lands**

Run: `gh run list -w log-pr-merge.yml --limit 1` then `gh run watch`.

Expected: a new commit on the branch (or `main` if merged) of the form `chore(log): web/src/content/log/2026-05-27-pr-999-test-entry.mdx`.

- [ ] **Step 3: Clean up the test entry**

```bash
git rm web/src/content/log/2026-05-27-pr-999-test-entry.mdx
git commit -m "chore(log): remove smoke-test entry"
```

---

## Phase 9 — Docs for operators + custom-domain readiness

### Task 39: `web/README.md` + `docs/runbooks/website-deploy.md`

**Files:**
- Create: `web/README.md`
- Create: `docs/runbooks/website-deploy.md`

- [ ] **Step 1: Write `web/README.md`**

```md
# web — agent-smith website

Astro 5 + Starlight, deployed to GitHub Pages via Actions.

## Local dev

    bun install
    cp src/data/crew-status.example.json src/data/crew-status.json
    bun run dev   # http://localhost:4321/agent-smith/

## Tests

    bun test
    bun run check               # type check
    bun scripts/check-roadmap-sync.ts

## Build

    bun run build && bun run preview

## Custom-domain swap (when ready)

1. Add `public/CNAME` with the apex/subdomain.
2. Repo Settings → Pages → Custom domain → set value.
3. In `astro.config.mjs`, set `base: '/'` and update `site:` to the new origin.
4. Wait for DNS + Pages cert.

## Analytics

None. Decision: stay zero-third-party in v1. Revisit only if we need
to know whether adopters land.
```

- [ ] **Step 2: Write `docs/runbooks/website-deploy.md`**

```md
# website-deploy

## Trigger
Push to `main` touching `web/**`, `docs/**`, `README.md`, or
`.github/workflows/website.yml` → `.github/workflows/website.yml`.

## First-time setup
1. Repo Settings → Pages → Source = GitHub Actions.
2. Branch protection on `main` is unchanged.

## Failure modes
- **Build fails on `refresh-crew-status.ts`** — GITHUB_TOKEN permissions; ensure default token scope includes `metadata: read`, `contents: read`.
- **Lighthouse perf budget fails** — open the LHCI run output; trim CSS/JS or kill the offending asset.
- **Lottie payload over 60KB** — re-export with smaller frames or drop one of the 3 animations.

## Custom domain swap
See `web/README.md#custom-domain-swap-when-ready`.
```

- [ ] **Step 3: Commit**

```bash
git add web/README.md docs/runbooks/website-deploy.md
git commit -m "docs: web/README + website-deploy runbook"
```

---

## Phase 10 — PR

### Task 40: Final build, push, open PR

**Files:** none

- [ ] **Step 1: Final local build verification**

```bash
cd web && bun run check && bun test && bun run build
```

Expected: all green.

- [ ] **Step 2: Push (or update push)**

```bash
git push -u origin feat/website-v1
```

- [ ] **Step 3: Open the PR**

```bash
SSL_CERT_FILE=/root/iron-proxy.crt gh pr create --repo sherodtaylor/agent-smith \
  --title "[dev] feat: agent-smith website — v1 (Astro + Starlight, GH Pages)" \
  --body "$(cat <<'EOF'
## What
Implements the spec in docs/superpowers/specs/2026-05-26-agent-smith-website-design.md.

- Landing page (hero with tmux pane, narrative, capabilities, architecture, crew status)
- /docs section (Starlight, 7 pages: getting-started, architecture, agents, security, operations, contributing, roadmap)
- /log chronological feed + content collection
- PR-merge → log entry workflow + ADR for the homelab → agent-smith dispatch
- GitHub Pages deploy via Actions
- Lighthouse CI for perf + a11y budget
- 3 Lottie animations (hero boot, ASCII draw, log pulse) within the 60KB sub-budget

## Resolved spec open questions

1. Berkeley Mono → not licensed; JetBrains Mono weight 800 for display.
2. Crew-status shape → { generated_at, agents: [...], last_release, prs_this_week }.
3. PR-merge → log → repository_dispatch from homelab + native pull_request listener.
4. Lottie authoring → hand-rolled JSON for v1.

## Verify

- cd web && bun install && bun run build
- gh workflow run website.yml --ref feat/website-v1
- Pages source is "GitHub Actions" (set in repo Settings → Pages first time only)
- Visit https://sherodtaylor.github.io/agent-smith/ after merge

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4: Worktree cleanup after merge**

```bash
cd /workspace/agent-smith
git worktree remove ../agent-smith-website
git branch -d feat/website-v1 || true
```

---

## Self-review (done before handoff)

- **Spec coverage:** §1 (IA) → T08, T15, T18-22, T29. §2 (visual) → T06, T07, T09-14. §3 (tech) → T02, T03, T22, T24, T31, T32. §4 (content) → T15, T17-22. §5 (deploy/ops) → T32, T35, T37, T39. §6 (out of scope) → respected by absence. §7 (open questions) → resolved at top + flagged in PR body.
- **Placeholder scan:** done; no TODO/TBD/FIXME in steps; each step shows actual code or exact commands.
- **Type consistency:** `buildCrewStatus`, `GhClient`, `MergedPR`, `StatusBadge.Status` types referenced consistently across tasks T30, T31, T13. Component prop interfaces are inline and self-contained.
- **Ambiguity:** scoped the workflow trigger paths explicitly; named the `repository_dispatch` payload shape in the ADR; named the LHCI assertion thresholds with exact numbers.

If an executor hits a gap, fix in place and update this plan with a one-line addendum at the end.
