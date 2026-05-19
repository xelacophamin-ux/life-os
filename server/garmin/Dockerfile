FROM python:3.12-alpine
WORKDIR /app

# Build deps for cryptography (garminconnect dependency)
RUN apk add --no-cache gcc musl-dev libffi-dev openssl-dev tzdata
ENV TZ=Europe/Paris

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY fetch_garmin.py .
RUN chmod +x fetch_garmin.py

ENV DATA_DIR=/data

# Container runs a tiny loop: fetch immediately, then every 4 hours.
# Garmin's data takes a few hours to sync from the watch, so this gives fresh data
# without hammering their servers.
CMD sh -c 'while true; do \
  echo "=== Garmin fetch at $(date -Iseconds) ==="; \
  python /app/fetch_garmin.py || echo "(fetch failed, will retry)"; \
  echo "Sleeping 4h until next run…"; \
  sleep 14400; \
done'
