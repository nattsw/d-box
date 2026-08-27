ARG BASE=discourse/discourse_dev:release
FROM ${BASE}

USER root
SHELL ["/bin/bash", "-c"]

# gh + jq (ripgrep already ships in the base image)
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates gnupg jq \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# Shared browser path owned by discourse. The actual browsers are baked later in
# the pre-init step (as the discourse user) so the box's npx cache + browser match
# exactly — baking here as root would use /root/.npm and drift from the box's HOME.
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
ENV TESTEM_DEFAULT_BROWSER=Chromium
ENV DISCOURSE_DISABLE_BROWSER_SANDBOX=1
ENV CHROME_BIN=/usr/local/bin/chromium
# system deps chromium needs (installed once here via a throwaway browser install)
RUN npx -y playwright@latest install --with-deps chromium >/dev/null 2>&1 || true \
 && rm -rf /ms-playwright && mkdir -p /ms-playwright \
 && chown -R discourse:discourse /ms-playwright

# agent CLIs + the discourse-mcp server. Kept LAST and on its OWN layer with a
# cache-bust ARG so `d-box build` always re-fetches the newest published versions
# (Docker otherwise caches `npm install` by command string and freezes it forever).
# Placing it after the apt/playwright layers means busting it leaves those cached.
# (npm global prefix is /usr → on PATH for all users.)
ARG CLI_CACHEBUST=0
ARG DISCOURSE_MCP=@discourse/mcp@0.1.10
ARG PLAYWRIGHT_MCP=@playwright/mcp@0.0.75
RUN echo "cli build token: ${CLI_CACHEBUST}" \
 && npm install -g @anthropic-ai/claude-code@latest @openai/codex@latest "${DISCOURSE_MCP}" "${PLAYWRIGHT_MCP}"

COPY entrypoint.rb /usr/local/bin/d-box-entrypoint
RUN chmod +x /usr/local/bin/d-box-entrypoint

# seed config, then hand off to the base image's service supervisor
ENTRYPOINT ["/usr/local/bin/d-box-entrypoint"]
