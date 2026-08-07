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

# ---- stage 2b: D1 spike — bake agent-substrate binaries ----
# Substrate ships zero prebuilt images (verified 2026-07-30 — zero GHCR
# packages, single tagged release with no assets). D1 spike builds all 6
# binaries into the runtime image; substrate manifests are then patched
# at install time to reference ghcr.io/sherodtaylor/agent-smith:<tag>
# with different `command: [...]` entries per component.
#
# Substrate SHA pinned to a specific commit for reproducibility; bump by
# updating SUBSTRATE_SHA + re-running the CI build.
FROM golang:1.25-bookworm AS substrate-builder
ARG SUBSTRATE_SHA=46adcb8017852fa4e322798828f3b2ea361fc4cf
RUN git clone https://github.com/agent-substrate/substrate.git /src
WORKDIR /src
RUN git checkout "${SUBSTRATE_SHA}"
RUN mkdir -p /out && \
    for cmd in ateapi atelet atecontroller atenet ateom-gvisor podcertcontroller; do \
      echo ">>> building substrate/cmd/${cmd}"; \
      CGO_ENABLED=0 go build -trimpath -ldflags="-s -w -X main.substrateSHA=${SUBSTRATE_SHA}" \
        -o "/out/${cmd}" "./cmd/${cmd}"; \
    done
# Vendor the manifests + install script so D1-mode installers don't need
# to re-clone substrate at runtime.
RUN cp -r manifests /out/manifests && \
    cp -r hack /out/hack && \
    echo "${SUBSTRATE_SHA}" > /out/SUBSTRATE_SHA

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

# D1 spike: substrate binaries + vendored manifests. The runtime image now
# doubles as the substrate component image — chart install patches manifests
# to use `image: <this-image>` + `command: ["/usr/local/bin/<component>"]`
# instead of substrate's default `ko://...` refs.
#
# Keep separate from the agent-smith harness path: the harness entrypoint
# stays `/opt/agent-smith/scripts/entrypoint.sh`; substrate components run
# via explicit `command:` overrides so nothing shifts by accident.
COPY --from=substrate-builder /out/ateapi              /usr/local/bin/ateapi
COPY --from=substrate-builder /out/atelet              /usr/local/bin/atelet
COPY --from=substrate-builder /out/atecontroller       /usr/local/bin/atecontroller
COPY --from=substrate-builder /out/atenet              /usr/local/bin/atenet
COPY --from=substrate-builder /out/ateom-gvisor        /usr/local/bin/ateom-gvisor
COPY --from=substrate-builder /out/podcertcontroller   /usr/local/bin/podcertcontroller
COPY --from=substrate-builder /out/manifests           /opt/agent-smith/substrate/manifests
COPY --from=substrate-builder /out/hack                /opt/agent-smith/substrate/hack
COPY --from=substrate-builder /out/SUBSTRATE_SHA       /opt/agent-smith/substrate/SUBSTRATE_SHA

# chromedp uses the system Chromium; point it at the Debian package path
ENV CHROMEDP_CHROME_PATH=/usr/bin/chromium

# App code
WORKDIR /opt/agent-smith
COPY agents/   ./agents/
COPY scripts/  ./scripts/
RUN chmod +x scripts/setup.sh scripts/entrypoint.sh scripts/claude-loop.sh scripts/strip-ansi.sh

CMD ["/opt/agent-smith/scripts/entrypoint.sh"]
