FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

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

CMD uvicorn backend.server:app --host 0.0.0.0 --port ${PORT:-8765} --workers 2
