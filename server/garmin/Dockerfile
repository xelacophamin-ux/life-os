FROM python:3.12-alpine
WORKDIR /app

# Build deps for cryptography (garminconnect dependency) + cron + tzdata
RUN apk add --no-cache gcc musl-dev libffi-dev openssl-dev tzdata dcron
ENV TZ=Europe/Paris

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY fetch_garmin.py .
RUN chmod +x fetch_garmin.py

# Daily fetch schedule (Europe/Paris):
#  - 07:00  → fresh data once Garmin has processed the night's sleep
#  - 13:00  → mid-day refresh (body battery, stress trend)
#  - 21:30  → ready for the evening recap
# Output piped to PID 1 stdout so it appears via `docker logs lifeos-garmin`.
RUN mkdir -p /etc/crontabs && \
    printf '%s\n%s\n%s\n' \
      '0 7 * * * /usr/local/bin/python /app/fetch_garmin.py >> /proc/1/fd/1 2>&1' \
      '0 13 * * * /usr/local/bin/python /app/fetch_garmin.py >> /proc/1/fd/1 2>&1' \
      '30 21 * * * /usr/local/bin/python /app/fetch_garmin.py >> /proc/1/fd/1 2>&1' \
      > /etc/crontabs/root

ENV DATA_DIR=/data

# 1. Initial fetch on boot so the cache exists immediately after deploy.
# 2. Replace shell with crond in foreground (verbose -l 8 log level, log to stderr).
CMD sh -c 'echo "=== Initial Garmin fetch at $(date -Iseconds) ==="; \
  python /app/fetch_garmin.py 2>&1 || echo "(initial fetch failed, cron will retry at next schedule)"; \
  echo ""; \
  echo "=== Cron schedule active: 07:00 · 13:00 · 21:30 Europe/Paris ==="; \
  exec crond -f -l 8 -L /dev/stderr'
