# ---- stage 1: build mcp-nats ----
# mcp-nats requires Go 1.25+ (see its go.mod: `go 1.25.0`).
FROM golang:1.25-bookworm AS mcp-nats-builder
RUN git clone --depth 1 https://github.com/sinadarbouy/mcp-nats.git /src
WORKDIR /src
# The MCP server's main package lives under ./cmd/mcp-nats (module
# github.com/sinadarbouy/mcp-nats). It speaks stdio MCP when invoked with
# `--transport stdio` and reads NATS_URL from the environment.
RUN CGO_ENABLED=0 go build -o /out/mcp-nats ./cmd/mcp-nats

# ---- stage 2: runtime ----
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
# Install Bun outside /root so the home PVC mount cannot shadow it.
ENV BUN_INSTALL=/usr/local

RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl wget ca-certificates gnupg unzip \
      zsh vim tmux jq \
    && rm -rf /var/lib/apt/lists/* \
    && chsh -s /bin/zsh root

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

# Node.js (for the Claude Code CLI)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# Bun (runtime for the Matrix channel plugin) — installs to $BUN_INSTALL/bin
RUN curl -fsSL https://bun.sh/install | bash

# mcp-nats binary
COPY --from=mcp-nats-builder /out/mcp-nats /usr/local/bin/mcp-nats

# App code
WORKDIR /opt/agent-smith
COPY agents/   ./agents/
COPY scripts/  ./scripts/
RUN chmod +x scripts/setup.sh scripts/entrypoint.sh scripts/claude-loop.sh

CMD ["/opt/agent-smith/scripts/entrypoint.sh"]
