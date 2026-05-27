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
