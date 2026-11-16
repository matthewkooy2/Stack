FROM ubuntu:24.04@sha256:2198e4c65076e9cb0b3d695219df667c0e3b0072da64ca3c2648aca17dcecaf5 AS base
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libfontconfig1 libstdc++6 python3 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --uid 10001 --create-home stack \
    && install -d -m 0755 -o stack -g stack /opt/stack
WORKDIR /opt/stack
ENV PYTHONUNBUFFERED=1 PYTHON_DOTENV_DISABLED=1

FROM base AS build
RUN apt-get update \
    && apt-get install -y --no-install-recommends cmake g++ git make python3-venv xz-utils \
    && rm -rf /var/lib/apt/lists/*
COPY --chown=stack:stack main.jac jac.toml THIRD_PARTY_NOTICES.txt ./
COPY --chown=stack:stack agents/ agents/
COPY --chown=stack:stack core/ core/
COPY --chown=stack:stack dependencies/ dependencies/
COPY --chown=stack:stack discovery/ discovery/
COPY --chown=stack:stack mobile/ mobile/
COPY --chown=stack:stack native/ native/
COPY --chown=stack:stack scripts/ scripts/
COPY --chown=stack:stack web/ web/
COPY deploy/compose.yaml /opt/stack-release/compose.yaml
USER stack
RUN python3 -c 'import sys; from pathlib import Path; root = Path.cwd(); sys.path.insert(0, str(root / "scripts")); import bootstrap; bootstrap.setup(root)' \
    && rm -rf .jac/tools/downloads .jac/tools/postgres .jac/client/node_modules \
        .jac/npm-cache .jac/pip-cache .jac/tool-cache/pg

# Bake the pinned local fallback for devices without on-device speech.
RUN STACK_TRANSCRIPTION_PORTABLE=1 python3 -m agents.setup_transcription \
    && rm -rf .jac/transcription/source .jac/transcription/cache .jac/transcription/setup-command.log \
    && mkdir -p /opt/stack/transcription-status

FROM base
LABEL org.opencontainers.image.source="https://github.com/matthewkooy2/Stack"
COPY --from=build --chown=stack:stack /opt/stack /opt/stack
COPY --from=build /opt/stack-release/compose.yaml /opt/stack-release/compose.yaml
USER stack
ENTRYPOINT ["/opt/stack/scripts/jac"]
