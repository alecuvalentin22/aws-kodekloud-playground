#!/usr/bin/env bash
# Push fake app logs into the app-logs data stream so there is something to
# search in Kibana and something for ILM to roll over.
set -euo pipefail
ES="${ES:-http://10.0.0.11:9200}"
SERVICES=(idp idbroker token-service gateway)
LEVELS=(INFO INFO INFO WARN ERROR)
for i in $(seq 1 "${1:-2000}"); do
  printf '{"create":{}}\n{"@timestamp":"%s","service.name":"%s","log.level":"%s","trace.id":"%032x","message":"request %d completed"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" \
    "${SERVICES[$((RANDOM % 4))]}" \
    "${LEVELS[$((RANDOM % 5))]}" \
    "$RANDOM$RANDOM" "$i"
done | curl -s -XPOST "$ES/app-logs/_bulk" -H 'Content-Type: application/x-ndjson' --data-binary @- | jq '.errors'
