FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    VO1D_DB=/data/relay.sqlite3

WORKDIR /app

COPY requirements.txt .

RUN apt-get update \
    && apt-get install -y --no-install-recommends gosu \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir -r requirements.txt \
    && useradd --uid 10001 --create-home --shell /usr/sbin/nologin relay \
    && mkdir -p /data \
    && chown relay:relay /data

COPY app.py realtime.py privacy.py push.py ./
COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint
RUN chmod 0755 /usr/local/bin/railway-entrypoint

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/railway-entrypoint"]

