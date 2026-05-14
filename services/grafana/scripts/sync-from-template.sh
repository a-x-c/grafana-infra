#!/usr/bin/env bash
# Pull dashboard updates from the grafana template into this app's dashboards/.
#
# Reads template URL + ref + per-app substitution vars from `.template-vars`
# (next to this script's parent dir). Clones the template at the given ref,
# re-runs init.sh's placeholder substitution against the template's dashboard
# JSONs, and writes the result into ./dashboards/ — but ONLY for dashboards
# that already exist locally. New dashboards from the template are listed
# without being written; copy them in manually if you want them.
#
# Usage:
#   ./scripts/sync-from-template.sh                 # ref from .template-vars, default main
#   ./scripts/sync-from-template.sh --ref v2026.05.20
#   ./scripts/sync-from-template.sh --dry-run       # report drift without writing
#   ./scripts/sync-from-template.sh --include cloud-run-overview.json,gcp-billing-costs.json
#
# After running, review with `git diff dashboards/` and commit if desired.

set -euo pipefail

# ── locate ourselves ────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GRAFANA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$GRAFANA_DIR"

# ── load .template-vars ─────────────────────────────────────────────────────
VARS_FILE="$GRAFANA_DIR/.template-vars"
if [ ! -f "$VARS_FILE" ]; then
  echo "ERROR: $VARS_FILE not found." >&2
  echo "Create it from .template-vars.example with the values used at bootstrap." >&2
  exit 2
fi

# Read KEY=value lines (strip quotes/comments). Export so sed substitution sees them.
set -a
# shellcheck disable=SC1090
. "$VARS_FILE"
set +a

: "${PROJECT_SLUG:?PROJECT_SLUG required in .template-vars}"
: "${DISPLAY_NAME:?DISPLAY_NAME required in .template-vars}"
: "${GCP_PROJECT:?GCP_PROJECT required in .template-vars}"
: "${TEMPLATE_URL:?TEMPLATE_URL required in .template-vars (e.g. file:///home/ac/Dev/templates/grafana or https://github.com/org/repo.git)}"
: "${GRAFANA_STACK:=axc}"
: "${GRAFANA_CLOUD_ORG:=axc}"
: "${TF_STATE_BUCKET:=}"
: "${GH_REPO:=}"
: "${CLOUD_RUN_SERVICES:=}"   # pipe-joined list, e.g. "imu-api|imu-worker"
: "${VM_NAME:=}"
: "${BUCKET_NAME:=}"

# ── args ────────────────────────────────────────────────────────────────────
REF="${TEMPLATE_REF:-main}"
DRY_RUN=0
INCLUDE_FILTER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ref)        REF="$2"; shift 2 ;;
    --ref=*)      REF="${1#--ref=}"; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --include)    INCLUDE_FILTER="$2"; shift 2 ;;
    --include=*)  INCLUDE_FILTER="${1#--include=}"; shift ;;
    -h|--help)
      grep -E '^# ' "$0" | sed 's/^# //'
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

# ── clone template into a tempdir ───────────────────────────────────────────
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "Fetching template from $TEMPLATE_URL @ $REF..." >&2
git clone --quiet --depth 1 --branch "$REF" "$TEMPLATE_URL" "$TMPDIR/template" 2>/dev/null || {
  # branch-clone fails for tags on shallow clones in some git versions; retry full
  git clone --quiet "$TEMPLATE_URL" "$TMPDIR/template"
  ( cd "$TMPDIR/template" && git checkout --quiet "$REF" )
}

TEMPLATE_DASHBOARDS="$TMPDIR/template/services/grafana/dashboards"
if [ ! -d "$TEMPLATE_DASHBOARDS" ]; then
  echo "ERROR: template at $REF has no services/grafana/dashboards/ directory" >&2
  exit 1
fi

# ── substitute placeholders into a staging dir ──────────────────────────────
STAGE="$TMPDIR/staged"
mkdir -p "$STAGE"

subst() {
  local in_file="$1" out_file="$2"
  # Use a custom delimiter (|) for sed because some values may contain /.
  sed \
    -e "s|{{project_slug}}|$PROJECT_SLUG|g" \
    -e "s|{{display_name}}|$DISPLAY_NAME|g" \
    -e "s|{{gcp_project}}|$GCP_PROJECT|g" \
    -e "s|{{grafana_stack}}|$GRAFANA_STACK|g" \
    -e "s|{{grafana_cloud_org}}|$GRAFANA_CLOUD_ORG|g" \
    -e "s|{{tf_state_bucket}}|$TF_STATE_BUCKET|g" \
    -e "s|{{gh_repo}}|$GH_REPO|g" \
    -e "s|__VM_NAME__|$VM_NAME|g" \
    -e "s|__BUCKET_NAME__|$BUCKET_NAME|g" \
    "$in_file" > "$out_file"

  # Cloud Run service names — only patched if CLOUD_RUN_SERVICES is set
  # AND the templating list still contains the template's placeholder names
  # ("service-one", "service-two", "service-three"). Once an app's services
  # have been substituted in, leave the JSON alone — re-running json.dump
  # would reformat indentation and escape non-ASCII (em-dashes etc.), causing
  # spurious drift on every sync.
  if [ -n "${CLOUD_RUN_SERVICES:-}" ] && grep -q 'service-one\|service-two\|service-three' "$out_file"; then
    python3 - "$out_file" <<'PY'
import json, os, sys
path = sys.argv[1]
services = [s for s in os.environ["CLOUD_RUN_SERVICES"].split("|") if s]
if not services:
    sys.exit(0)
d = json.load(open(path))
templating = d.get("templating", {}).get("list") or []
changed = False
for tmpl in templating:
    if tmpl.get("name") not in {"service", "services"}:
        continue
    pipe = "|".join(services)
    tmpl["query"] = pipe
    tmpl["allValue"] = pipe
    tmpl["options"] = [
        {"selected": False, "text": s, "value": s} for s in services
    ]
    # Multi-select default to "All" so the dashboard works on first load.
    if tmpl.get("multi"):
        tmpl["options"].insert(0, {"selected": True, "text": "All", "value": "$__all"})
        tmpl["current"] = {"selected": True, "text": ["All"], "value": ["$__all"]}
    else:
        tmpl["options"][0]["selected"] = True
        tmpl["current"] = {"selected": False, "text": services[0], "value": services[0]}
    changed = True
if changed:
    json.dump(d, open(path, "w"), indent=2, ensure_ascii=False)
PY
  fi
}

# Which dashboards to consider:
#  - default: every file present in template/dashboards
#  - filtered by --include if given (comma-joined basenames)
declare -a CANDIDATES=()
if [ -n "$INCLUDE_FILTER" ]; then
  IFS=',' read -r -a CANDIDATES <<< "$INCLUDE_FILTER"
else
  while IFS= read -r -d '' f; do
    CANDIDATES+=("$(basename "$f")")
  done < <(find "$TEMPLATE_DASHBOARDS" -maxdepth 1 -type f -name '*.json' -print0)
fi

LOCAL_DASHBOARDS="$GRAFANA_DIR/dashboards"
mkdir -p "$LOCAL_DASHBOARDS"

# ── classify each candidate: update existing | new (skip) | missing in template ─
declare -a UPDATED=()  # files that will be (or would be) written
declare -a NEW_IN_TEMPLATE=() # files in template but not in app
declare -a CLEAN=() # files unchanged after substitution
for name in "${CANDIDATES[@]}"; do
  src="$TEMPLATE_DASHBOARDS/$name"
  if [ ! -f "$src" ]; then
    echo "skip: $name (not in template at $REF)" >&2
    continue
  fi
  local_path="$LOCAL_DASHBOARDS/$name"
  staged_path="$STAGE/$name"
  subst "$src" "$staged_path"
  if [ ! -f "$local_path" ]; then
    NEW_IN_TEMPLATE+=("$name")
    continue
  fi
  if ! diff -q "$local_path" "$staged_path" >/dev/null 2>&1; then
    UPDATED+=("$name")
  else
    CLEAN+=("$name")
  fi
done

# ── report ──────────────────────────────────────────────────────────────────
echo
echo "Template ref:     $REF"
echo "Template URL:     $TEMPLATE_URL"
echo "Dashboards dir:   $LOCAL_DASHBOARDS"
echo
echo "Unchanged (${#CLEAN[@]}):"
for n in "${CLEAN[@]}"; do echo "  = $n"; done
echo "Drift detected (${#UPDATED[@]}):"
for n in "${UPDATED[@]}"; do echo "  ~ $n"; done
echo "New in template, not in app (${#NEW_IN_TEMPLATE[@]}):"
for n in "${NEW_IN_TEMPLATE[@]}"; do echo "  + $n   (use --include $n to add it)"; done
echo

if [ "$DRY_RUN" -eq 1 ]; then
  exit 0
fi

if [ "${#UPDATED[@]}" -eq 0 ]; then
  echo "Nothing to update."
  exit 0
fi

for n in "${UPDATED[@]}"; do
  cp "$STAGE/$n" "$LOCAL_DASHBOARDS/$n"
done

echo "Wrote ${#UPDATED[@]} updated dashboard(s). Review with:"
echo "  git diff dashboards/"
