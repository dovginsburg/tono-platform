FROM python:3.11-slim

ARG TONO_CANONICAL_SHA=unknown
ARG TONO_SCHEMA_REVISION=legacy-sqlite-unversioned

LABEL org.opencontainers.image.revision="${TONO_CANONICAL_SHA}" \
      com.tonoit.schema-revision="${TONO_SCHEMA_REVISION}"

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    TONO_CANONICAL_SHA="${TONO_CANONICAL_SHA}" \
    TONO_SCHEMA_REVISION="${TONO_SCHEMA_REVISION}"

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY . /app/backend/

RUN useradd --create-home --shell /bin/bash tono \
 && mkdir -p /data \
 && chown -R tono:tono /app /data
USER tono

EXPOSE 8765

# Single application worker on purpose: production (Render srv-d9gg8ngk1i2s738lngd0)
# runs on a persistent disk at /data backed by one SQLite file in WAL mode.
# Multiple workers would each run Store._init_schema() concurrently at startup,
# racing on `PRAGMA journal_mode=WAL` against the same file, and would share a
# single-writer SQLite database across processes with no shared-file safety
# guarantee. One worker serializes schema init and writes. Do not raise this
# without a genuinely concurrency-safe backing store.
CMD uvicorn backend.server:app --host 0.0.0.0 --port ${PORT:-8765} --workers 1
