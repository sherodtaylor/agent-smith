# ---- stage 1: build mcp-nats ----
# mcp-nats requires Go 1.25+ (see its go.mod: `go 1.25.0`).
FROM golang:1.25-bookworm AS mcp-nats-builder
RUN git clone --depth 1 https://github.com/sinadarbouy/mcp-nats.git /src
WORKDIR /src
# The MCP server's main package lives under ./cmd/mcp-nats (module
# github.com/sinadarbouy/mcp-nats). It speaks stdio MCP when invoked with
# `--transport stdio` and reads NATS_URL from the environment.
RUN CGO_ENABLED=0 go build -o /out/mcp-nats ./cmd/mcp-nats

# ---- stage 2: build claude-reauth ----
FROM golang:1.23-bookworm AS reauth-builder
WORKDIR /src
COPY cmd/claude-reauth/ .
# go mod tidy generates go.sum at build time (requires network access in CI).
RUN go mod tidy && CGO_ENABLED=0 go build -o /out/claude-reauth .

# ---- stage 3: runtime ----
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
# Install Bun outside /root so the home PVC mount cannot shadow it.
ENV BUN_INSTALL=/usr/local

RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl wget ca-certificates gnupg unzip \
      vim tmux jq \
      chromium chromium-driver \
    && rm -rf /var/lib/apt/lists/*

# ttyd — web-based terminal for the reauth tunnel fallback
RUN TTYD_VERSION=$(curl -sL https://api.github.com/repos/tsl0922/ttyd/releases/latest \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])" 2>/dev/null \
      || echo "1.7.7") \
    && curl -fLo /usr/local/bin/ttyd \
         "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.x86_64" \
    && chmod +x /usr/local/bin/ttyd

# GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# kubectl
RUN KUBECTL_VERSION=$(curl -sL https://dl.k8s.io/release/stable.txt) \
    && curl -Lo /usr/local/bin/kubectl \
         "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    && chmod +x /usr/local/bin/kubectl

# Infisical CLI — consumed by homelab/scripts/lib/infisical.sh for in-pod
# secret push/pull (machine-identity flow). Pin a version; bump deliberately.
ARG INFISICAL_CLI_VERSION=0.41.0
RUN curl -fsSL -o /tmp/infisical.tar.gz \
         "https://github.com/Infisical/infisical/releases/download/infisical-cli/v${INFISICAL_CLI_VERSION}/infisical_${INFISICAL_CLI_VERSION}_linux_amd64.tar.gz" \
    && tar -xz -C /usr/local/bin -f /tmp/infisical.tar.gz infisical \
    && chmod +x /usr/local/bin/infisical \
    && rm /tmp/infisical.tar.gz \
    && infisical --version

# Node.js (for the Claude Code CLI)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# Bun (runtime for the Matrix channel plugin) — installs to $BUN_INSTALL/bin
RUN curl -fsSL https://bun.sh/install | bash

# Binaries from build stages
COPY --from=mcp-nats-builder /out/mcp-nats /usr/local/bin/mcp-nats
COPY --from=reauth-builder   /out/claude-reauth /usr/local/bin/claude-reauth

# chromedp uses the system Chromium; point it at the Debian package path
ENV CHROMEDP_CHROME_PATH=/usr/bin/chromium

# App code
WORKDIR /opt/agent-smith
COPY agents/   ./agents/
COPY scripts/  ./scripts/
RUN chmod +x scripts/setup.sh scripts/entrypoint.sh scripts/claude-loop.sh scripts/strip-ansi.sh

CMD ["/opt/agent-smith/scripts/entrypoint.sh"]
