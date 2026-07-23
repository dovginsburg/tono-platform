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

# build-essential: compile any wheels that lack manylinux binaries.
# gosu: Debian-packaged, statically-linked su/sudo replacement used by the
#   entrypoint to drop from root to `tono` after fixing /data ownership. We
#   install it from apt (NOT a curl-downloaded binary) so provenance is the
#   distro's signed package feed and the image stays auditable.
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential gosu \
 && rm -rf /var/lib/apt/lists/* \
 && gosu nobody true

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY . /app/backend/

# Create the unprivileged runtime user and the /data mount point. Ownership of
# a freshly-mounted (root-owned) volume is corrected at RUNTIME by the
# entrypoint; this build-time chown only covers the image's own copy.
RUN useradd --create-home --shell /bin/bash tono \
 && mkdir -p /data \
 && chown -R tono:tono /app /data \
 && install -m 0755 /app/backend/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

# NOTE: we deliberately do NOT set `USER tono`. The container starts as root so
# the entrypoint can chown a fresh root-owned /data volume, then gosu drops to
# `tono` before exec — root is never the identity the application runs under.

EXPOSE 8765

# Single application worker on purpose: production (Render srv-d9gg8ngk1i2s738lngd0)
# runs on a persistent disk at /data backed by one SQLite file in WAL mode.
# Multiple workers would each run Store._init_schema() concurrently at startup,
# racing on `PRAGMA journal_mode=WAL` against the same file, and would share a
# single-writer SQLite database across processes with no shared-file safety
# guarantee. One worker serializes schema init and writes. Do not raise this
# without a genuinely concurrency-safe backing store.
#
# Exec-form ENTRYPOINT + CMD: the entrypoint is PID 1 (root, minimal), drops to
# tono via gosu, and execs uvicorn so uvicorn becomes PID 1 and receives
# SIGTERM directly for graceful shutdown. The port is appended by the
# entrypoint as ${PORT:-8765} (Render/Railway inject PORT).
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["uvicorn", "backend.server:app", "--host", "0.0.0.0", "--workers", "1"]
