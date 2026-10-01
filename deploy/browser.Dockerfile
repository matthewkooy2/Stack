FROM python:3.12.11-slim-bookworm
ARG TARGETARCH
WORKDIR /app
# Official 0.37.21 native Linux runtime; checksums from its release assets.
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && case "$TARGETARCH" in \
      arm64) arch=aarch64; sha=9f7cc107519243ee5fc16f642606ed79e94ca024f28b269745d208b2d142d692 ;; \
      amd64) arch=x86_64; sha=1f4385aca73182f90ca0bf2dd887713df6e0530115e0835dc09e396256a7333d ;; \
      *) exit 1 ;; esac \
    && curl -fsSL "https://github.com/jaseci-labs/jac/releases/download/v0.37.21/jac-0.37.21-linux-$arch" -o /usr/local/bin/jac \
    && echo "$sha  /usr/local/bin/jac" | sha256sum -c - \
    && chmod 755 /usr/local/bin/jac
COPY deploy/browser.jac.toml /app/jac.toml
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/playwright JAC_CACHE_HOME=/opt/jac-cache
RUN jac install --no-npm
COPY deploy /app/deploy
RUN jac run --no-serve deploy/install-browser.jac \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home pwuser
COPY agents /app/agents
COPY discovery /app/discovery
ENV PYTHONDONTWRITEBYTECODE=1 STACK_BROWSER_BIND=0.0.0.0 JAC_CACHE_HOME=/tmp/jac-cache
USER pwuser
ENTRYPOINT ["sh", "/app/deploy/browser-entrypoint"]
