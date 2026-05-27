// Bun test preload: alias the Astro virtual module `astro:content` so that
// schema unit tests can import `defineCollection`/`z` exactly the way the
// runtime imports them. Astro provides these via Vite's virtual-module
// plumbing — Bun has no such plumbing, so we shim it here.
import { plugin } from 'bun';

plugin({
  name: 'astro-content-virtual-shim',
  setup(build) {
    build.module('astro:content', () => ({
      contents: `
        import { z } from 'zod';
        export { z };
        export function defineCollection(config) { return config; }
      `,
      loader: 'ts',
    }));
  },
});
