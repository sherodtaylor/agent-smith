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
  { name: 'devbot',   role: 'code'    as const },
  { name: 'infrabot', role: 'infra'   as const },
  { name: 'pmbot',    role: 'product' as const },
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
      state: 'active' as const,
      dnd_until: null,
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
    const data = await res.json();
    // Default `GITHUB_TOKEN` in GitHub Actions is scoped to the current repo.
    // Cross-repo reads (e.g. sherodtaylor/homelab from inside agent-smith's
    // workflow) come back as `{"message": "Not Found"}` not an array — skip
    // with a warning instead of crashing on `for…of {}`.
    if (!Array.isArray(data)) {
      console.warn(`[refresh-crew-status] ${repo}: HTTP ${res.status} — ${JSON.stringify(data).slice(0, 160)}`);
      continue;
    }
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
