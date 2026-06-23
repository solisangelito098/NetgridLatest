#!/bin/sh
set -eu
: "${APP_URL:?APP_URL must be set}"
: "${CRON_PATH:?CRON_PATH must be set}"
: "${CRON_SECRET:?CRON_SECRET must be set}"

# CRON_PATH may include a query string (e.g.
# "/api/cron/auto-publish?shard=0&shardCount=4"). The case statement
# below just prepends the URL scheme; the path + query passes through.
case "$APP_URL" in
  http://*|https://*) URL="${APP_URL}${CRON_PATH}" ;;
  *)                  URL="https://${APP_URL}${CRON_PATH}" ;;
esac

# Default per-cron timeout — overridable from the cron service's env so
# slow paths (auto-publish at 600s maxDuration, monthly-reports at 300s)
# can opt up without blanket-extending fast paths. Defaults to 660 to
# match the longest-running route (auto-publish, 600s) plus headroom.
MAX_TIME="${CRON_MAX_TIME:-660}"

exec curl -fsS --retry 3 --max-time "$MAX_TIME" \
  -H "Authorization: Bearer ${CRON_SECRET}" \
  "$URL"
