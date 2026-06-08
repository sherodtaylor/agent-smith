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
    expect(status.agents.find(a => a.name === 'pmbot')?.last_pr).toBeNull();
    expect(status.agents.length).toBe(3);
    expect(status.prs_this_week).toBe(3);
    expect(status.last_release).toBe('v0.1.21');
    expect(status.generated_at).toBeDefined();
  });

  test('handles agent with zero PRs', async () => {
    const ghClient = { listPRs: async () => [], latestRelease: async () => ({ tag_name: 'v0.1.0' }) };
    const status = await buildCrewStatus(ghClient, { now: new Date() });
    expect(status.agents.find(a => a.name === 'devbot')?.last_pr).toBeNull();
    expect(status.agents.find(a => a.name === 'pmbot')?.last_pr).toBeNull();
  });
});
