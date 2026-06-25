FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Build deps for httpx/uvicorn's optional [standard] extras (uvloop, httptools,
# websockets) need a C compiler. We use the slim image so we install build-base
# only at build time and don't bloat the final layer.
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Layer deps separately from code so deploys don't reinstall on code-only changes.
COPY Backend/requirements.txt /app/Backend/requirements.txt
RUN pip install --no-cache-dir -r /app/Backend/requirements.txt

COPY Backend/ /app/Backend/

# Non-root runtime.
RUN useradd --create-home --shell /bin/bash tono \
 && chown -R tono:tono /app
USER tono

WORKDIR /app

EXPOSE 8765

# Two workers is plenty at MVP scale; SQLite serializes writes either way.
# Import via the qualified module path because Backend uses relative
# imports (e.g. `from . import payments`); running it as a bare
# `server:app` from /app/Backend fails at startup with
# "attempted relative import with no known parent package".
CMD ["uvicorn", "Backend.server:app", "--host", "0.0.0.0", "--port", "8765", "--workers", "2"]
