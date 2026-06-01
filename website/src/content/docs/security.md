---
title: Security
description: Iron-proxy, secret swapping, network egress.
---

The pod never holds a real credential. Stub tokens are committed to the
repo; the egress credential firewall (iron-proxy) swaps them for real
values at the network boundary. A compromised pod can't reach outside
the allowlist.

## iron-proxy in one diagram

All agent egress runs through **iron-proxy** at ClusterIP
`10.43.100.100`. This is the **egress credential firewall**: agents hold
only worthless proxy tokens, and iron-proxy swaps real secrets in at the
network boundary. A leaked agent token is worthless outside the cluster.

```
   agent pod                            iron-proxy                       internet
   ─────────                            ──────────                       ────────
   git/gh/curl/claude
     │  Authorization: Bearer proxy-token-github
     │  Authorization: Bearer access-token-stub
     ▼
   resolve api.github.com  ─────►  iron-proxy MITM (private CA in pod's trust store)
                                       │
                                       │  match host → look up real credential
                                       │  rewrite Authorization header
                                       ▼
                                   forward to upstream  ───────────►  api.github.com
                                                                       api.anthropic.com
```

## What the pod holds

- `proxy-token-github` (placeholder GitHub token) in `GITHUB_TOKEN`.
- The stub OAuth payload in `agents/_shared/.credentials.json`:
  `access-token-stub` and `refresh-token-stub` — literal placeholder
  strings, never the real GitHub PAT or Claude OAuth tokens.
- The iron-proxy CA cert, distributed via ExternalSecret. `setup.sh`
  installs it into the system trust store with `update-ca-certificates`
  so `git`, `gh`, and `curl` trust the MITM; the Dockerfile sets
  `NODE_EXTRA_CA_CERTS` so the Node-based `claude` CLI does too.

## What iron-proxy does

- MITMs all HTTPS egress using its private CA.
- Enforces a default-deny domain allowlist — only listed hosts get
  egress.
- Rewrites `Authorization` headers with the real credentials scoped to
  each host.
- Holds the live upstream credentials in its own environment.

Agent DNS is pointed at iron-proxy (`dnsPolicy: None`). In-cluster names
(`*.cluster.local`) pass through to CoreDNS so NATS and the Matrix
homeserver still resolve normally.

## Properties this gives the operator

- A leaked pod token is worthless outside the cluster (it's literally
  `proxy-token-github`).
- Token rotation is iron-proxy's job. Agents never refresh OAuth — the
  pod's `~/.claude/.credentials.json` is permanently the stub.
- Default-deny domain allowlist means a misbehaving agent can't
  exfiltrate to an attacker-controlled host even if it tried.
- The blast radius of a compromised agent pod is "what can be done
  through the allowlist," not "all of the operator's accounts."

The agent code itself is unaware of any of this — it sends
`Authorization: Bearer proxy-token-github`, iron-proxy turns it into a
real PAT, the target site sees a normal request.

## Why a stub, not a setup token

`claude setup-token` (and its older API key flow) is the
development-environment auth path. It is not used in agent-smith
because:

- **Setup tokens are short-lived.** They mint a real OAuth pair on
  first use and embed it in `~/.claude/.credentials.json`. The pod would
  then be holding a real refresh token — exactly the thing iron-proxy
  exists to prevent.
- **They only work interactively.** `claude setup-token <code>` blocks
  on a browser flow to get the code in the first place. A headless pod
  has no browser, so the only path was to copy a `credentials.json`
  from a human's machine — which had all the rotation and secret-leak
  problems iron-proxy was meant to solve.
- **They get rotated by the upstream.** When Anthropic rotates a refresh
  token mid-flight, the pod's credentials silently expire. With the
  stub-token flow there is nothing rotating — iron-proxy holds the live
  credential and refreshes it on its own schedule.

For a local dev clone (no iron-proxy involved), use the interactive
flow:

```bash
claude /login
```

That writes a real `~/.claude/.credentials.json` on the laptop, and the
rest of the repo (settings, MCP config, channels, hooks) Just Works
against it. **Never copy that file into a pod** — that's the exact
failure mode the stub + iron-proxy approach was introduced to fix.

## Re-authenticating cold SSO cookies

The Anthropic OAuth tokens that `iron-proxy` swaps in for the stub eventually
need a real human login (cookies expire, accounts rotate). `claude-reauth`
runs as the pod's startup auth flow:

1. Try `claude auth status` + verify the credentials on disk are real (not
   stubs).
2. If they're stubs, spawn `claude auth login --claudeai` and capture the
   OAuth authorize URL.
3. Try a headless Chromium pass with cached SSO cookies from
   `~/.chrome-profile/`. If the cookies are warm, the redirect to the
   callback URL completes silently and the callback `code` is piped
   straight into the running `claude auth login` subprocess stdin.
4. **If headless fails** (cookies cold, fresh PVC, new bot account), serve
   a **single-purpose web form** on port 7681. The page shows the OAuth
   authorize URL and accepts one input — the callback `code` — which is
   piped to the same `claude auth login` subprocess stdin. The form is
   single-use; subsequent submissions get an HTTP 410 Gone. No shell is
   exposed.
5. Matrix-DM the operator with the tunnel URL so they can complete the
   flow from a browser.

This replaced an earlier `ttyd` shell flow (v0.2.12 and prior). The shell
gave operators a full writable terminal at the same hostname — convenient
but high blast-radius if anyone else reached the ingress URL. The web form
narrows the attack surface to "one field that accepts an OAuth code an
attacker doesn't have."

The legacy `ttyd` path is still available behind `REAUTH_MODE=ttyd` for
emergency recovery if the web form ever breaks.

## The two GitHub tokens

Two GitHub tokens travel with the agent, intentionally:

- `GITHUB_TOKEN` — the proxy stub. Used by `gh` and direct GitHub REST
  API calls. iron-proxy sees the literal `proxy-token-github` string in
  the `Authorization: Bearer …` header and swaps it for the real PAT.
- `GIT_GITHUB_TOKEN` — the **real** PAT, written to
  `~/.git-credentials` for git HTTPS Basic Auth.

The split exists because `git` HTTPS uses Basic Auth
(`Authorization: Basic <base64(user:pass)>`), which is opaque to
plain-text matching. iron-proxy can't swap it. So the real PAT has to
live in the pod for git operations, while everything else uses the
proxy token.

This is a known wart; an iron-proxy that can decode and rewrite Basic
Auth would let the second token disappear.

## Stop hook + persona rules forbid leaking secrets

Two additional layers prevent the agent itself from leaking what it has
access to:

- The `check-pr-comments.sh` Stop hook runs after every Claude turn and
  rewakes the agent on unaddressed review comments. It does not echo
  secret content.
- The base persona (`agents/_shared/CLAUDE.md`) forbids the agent from
  printing, echoing, or logging secret values in Matrix replies, in
  command output, or in code. Generated secrets must be written
  directly to their destination (Infisical, a k8s Secret, a file).

These rules are part of the runtime contract every agent loads at
startup. Persona files cannot override them.
