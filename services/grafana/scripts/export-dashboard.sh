#!/usr/bin/env bash
# Pull a dashboard from Grafana Cloud and write it to ../dashboards/<slug>.json
# stripped of mutable runtime fields (id, version, iteration) so it round-trips
# cleanly through Terraform.
#
# Usage:  ./scripts/export-dashboard.sh <dashboard_uid>
# Env:    GRAFANA_URL    (default https://{{grafana_stack}}.grafana.net)
#         GRAFANA_API_KEY (required — a stack-admin token; the justfile reads
#                          it from `terraform output -raw stack_admin_token`)

set -euo pipefail

UID_ARG="${1:?usage: export-dashboard.sh <dashboard_uid>}"
GRAFANA_URL="${GRAFANA_URL:-https://{{grafana_stack}}.grafana.net}"
: "${GRAFANA_API_KEY:?GRAFANA_API_KEY must be set}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${REPO_ROOT}/dashboards"
mkdir -p "${OUT_DIR}"

RAW=$(curl -sSf -H "Authorization: Bearer ${GRAFANA_API_KEY}" \
  "${GRAFANA_URL}/api/dashboards/uid/${UID_ARG}")

SLUG=$(echo "${RAW}" | jq -r '.meta.slug')
OUT_FILE="${OUT_DIR}/${SLUG}.json"

echo "${RAW}" | jq '.dashboard | del(.id, .version, .iteration)' > "${OUT_FILE}"

echo "Wrote ${OUT_FILE}"
