FROM python:3.12.11-slim-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends g++ && rm -rf /var/lib/apt/lists/*
USER 65534:65534
WORKDIR /work
CMD ["python3", "-I", "/work/harness.py"]
