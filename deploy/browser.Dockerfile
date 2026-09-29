FROM python:3.12.11-slim-bookworm
WORKDIR /app
COPY deploy/browser-requirements.txt /app/requirements.txt
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/playwright
RUN pip install --no-cache-dir -r requirements.txt \
    && playwright install --with-deps --only-shell chromium \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home pwuser
COPY agents /app/agents
COPY discovery /app/discovery
ENV PYTHONDONTWRITEBYTECODE=1 STACK_BROWSER_BIND=0.0.0.0
USER pwuser
CMD ["python", "-m", "agents.browser_service"]
