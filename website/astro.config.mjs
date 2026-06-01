import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import mdx from '@astrojs/mdx';
import sitemap from '@astrojs/sitemap';

// PR_PREVIEW_BASE is set by .github/workflows/website-preview.yml so per-PR
// builds resolve their assets and links under /agent-smith/pr-<N>/ instead
// of /agent-smith/. Falls back to the production base for main and local
// dev builds. Trailing slash is normalized off — Astro accepts either
// form but consistency keeps the diff between PR preview and main minimal.
const base = (process.env.PR_PREVIEW_BASE ?? '/agent-smith').replace(/\/$/, '');

export default defineConfig({
  site: 'https://sherodtaylor.github.io',
  base,
  trailingSlash: 'never',
  output: 'static',
  integrations: [
    // Starlight first — it injects astro-expressive-code which must precede mdx().
    starlight({
      title: 'agent-smith',
      customCss: ['./src/styles/tokens.css', './src/styles/global.css'],
      // We provide our own terminal-styled 404 page at src/pages/404.astro.
      disable404Route: true,
      sidebar: [
        { label: 'Getting Started', slug: 'getting-started' },
        { label: 'Deployment',      slug: 'deployment' },
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
    mdx(),
    sitemap(),
  ],
});
