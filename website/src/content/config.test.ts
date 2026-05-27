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
