// Live-update the tmux status bar without requiring a website redeploy.
//
// First paint uses the build-time `crew-status.json` values (no LCP penalty).
// After paint, this script hits the GitHub API to refresh:
//   - last release tag (from /repos/.../releases/latest)
//   - PRs merged in the last 7 days (from /search/issues)
//
// Anonymous GitHub API rate limit is 60/hr per IP. We cache the result in
// sessionStorage with a 5-minute TTL so a tab opening the site twice in
// quick succession only spends one budget unit. The site keeps working if
// GitHub is unreachable — the build-time values stay on screen.
(() => {
  const REPO = 'sherodtaylor/agent-smith';
  const TTL_MS = 5 * 60 * 1000;
  const CACHE_KEY = 'agent-smith:live-status:v1';

  function readCache() {
    try {
      const raw = sessionStorage.getItem(CACHE_KEY);
      if (!raw) return null;
      const { ts, data } = JSON.parse(raw);
      if (!ts || Date.now() - ts > TTL_MS) return null;
      return data;
    } catch {
      return null;
    }
  }

  function writeCache(data) {
    try {
      sessionStorage.setItem(CACHE_KEY, JSON.stringify({ ts: Date.now(), data }));
    } catch {
      // sessionStorage can be unavailable in privacy modes. Best-effort.
    }
  }

  async function fetchFresh() {
    const weekAgoIso = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000)
      .toISOString()
      .slice(0, 10);
    const headers = { Accept: 'application/vnd.github+json' };

    const [relRes, prRes] = await Promise.all([
      fetch(`https://api.github.com/repos/${REPO}/releases/latest`, { headers }),
      fetch(
        `https://api.github.com/search/issues?q=is:pr+is:merged+repo:${REPO}+merged:>=${weekAgoIso}&per_page=1`,
        { headers },
      ),
    ]);

    if (!relRes.ok || !prRes.ok) return null;
    const rel = await relRes.json();
    const prs = await prRes.json();
    if (typeof rel?.tag_name !== 'string' || typeof prs?.total_count !== 'number') {
      return null;
    }
    return { last_release: rel.tag_name, prs_this_week: prs.total_count };
  }

  function render(data) {
    document
      .querySelectorAll('[data-live-release]')
      .forEach((el) => {
        el.textContent = data.last_release;
      });
    document
      .querySelectorAll('[data-live-prs]')
      .forEach((el) => {
        el.textContent = String(data.prs_this_week);
      });
  }

  // Cache hit: paint immediately.
  const cached = readCache();
  if (cached) render(cached);

  // Background refresh — outpaces the cache when the user reloads
  // immediately after a release lands.
  (async () => {
    try {
      const fresh = await fetchFresh();
      if (fresh) {
        writeCache(fresh);
        render(fresh);
      }
    } catch {
      // Network errors leave the build-time values in place.
    }
  })();
})();
