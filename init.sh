#!/usr/bin/env bash
# Substitute template placeholders across the repo.
#
# Either pass --interactive (prompts for each value, with sensible defaults
# derived from earlier answers) or set the env vars and pass --non-interactive.
#
# Placeholders this script knows how to replace:
#   {{project_slug}}        e.g. "myproject"     — UID/tag/folder prefix
#   {{display_name}}        e.g. "MyProject"     — title prefix
#   {{gcp_project}}         e.g. "myproject-app" — GCP project ID
#   {{grafana_stack}}       e.g. "myproject"     — <stack>.grafana.net subdomain
#   {{grafana_cloud_org}}   e.g. "myproject"     — grafana.com org slug
#   {{tf_state_bucket}}     e.g. "myproject-app-tf-state"
#   {{gh_repo}}             e.g. "myorg/myproject"
#
# After running this, the {{...}} placeholders are gone and `terraform fmt`
# / `terraform validate` should pass.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

ask() {
  local var="$1" prompt="$2" default="${3:-}"
  local current="${!var:-}"
  if [ -n "$current" ]; then return; fi
  if [ -n "$default" ]; then
    read -r -p "$prompt [$default]: " val
    val="${val:-$default}"
  else
    read -r -p "$prompt: " val
  fi
  printf -v "$var" '%s' "$val"
}

mode="${1:-interactive}"

if [ "$mode" = "--non-interactive" ]; then
  : "${PROJECT_SLUG:?PROJECT_SLUG required}"
  : "${DISPLAY_NAME:?DISPLAY_NAME required}"
  : "${GCP_PROJECT:?GCP_PROJECT required}"
  : "${GRAFANA_STACK:=$PROJECT_SLUG}"
  : "${GRAFANA_CLOUD_ORG:=$PROJECT_SLUG}"
  : "${TF_STATE_BUCKET:=${GCP_PROJECT}-tf-state}"
  : "${GH_REPO:?GH_REPO required (e.g. org/repo)}"
else
  ask PROJECT_SLUG       "Project slug (kebab-case, e.g. myproject)"
  ask DISPLAY_NAME       "Display name (human-readable, e.g. MyProject)"      "$(tr '[:lower:]' '[:upper:]' <<< "${PROJECT_SLUG:0:1}")${PROJECT_SLUG:1}"
  ask GCP_PROJECT        "GCP project ID"                                     "${PROJECT_SLUG}-app"
  ask GRAFANA_STACK      "Grafana Cloud stack subdomain (<x>.grafana.net)"    "$PROJECT_SLUG"
  ask GRAFANA_CLOUD_ORG  "Grafana Cloud org slug (grafana.com/orgs/<x>)"      "$PROJECT_SLUG"
  ask TF_STATE_BUCKET    "GCS bucket for Terraform state"                     "${GCP_PROJECT}-tf-state"
  ask GH_REPO            "GitHub repo (org/repo)"
fi

# Files to substitute. Skip binary files, the schema (3rd-party), and this script.
mapfile -t FILES < <(
  find "$HERE" \
    -type f \
    \( -name '*.tf' -o -name '*.json' -o -name '*.yaml' -o -name '*.yml' \
       -o -name '*.md' -o -name 'justfile' -o -name '*.sh' \) \
    -not -path '*/tests/schemas/*' \
    -not -path '*/.git/*' \
    -not -name 'init.sh'
)

subst() {
  local file="$1"
  sed -i \
    -e "s|{{project_slug}}|$PROJECT_SLUG|g" \
    -e "s|{{display_name}}|$DISPLAY_NAME|g" \
    -e "s|{{gcp_project}}|$GCP_PROJECT|g" \
    -e "s|{{grafana_stack}}|$GRAFANA_STACK|g" \
    -e "s|{{grafana_cloud_org}}|$GRAFANA_CLOUD_ORG|g" \
    -e "s|{{tf_state_bucket}}|$TF_STATE_BUCKET|g" \
    -e "s|{{gh_repo}}|$GH_REPO|g" \
    "$file"
}

for f in "${FILES[@]}"; do
  subst "$f"
done

# Generate services/grafana/.template-vars from the (now substituted) example.
# Apps consume this at sync + pre-commit time. Safe to commit.
TEMPLATE_VARS_OUT="$HERE/services/grafana/.template-vars"
if [ -f "$HERE/services/grafana/.template-vars.example" ] && [ ! -f "$TEMPLATE_VARS_OUT" ]; then
  cp "$HERE/services/grafana/.template-vars.example" "$TEMPLATE_VARS_OUT"
  echo "Wrote $TEMPLATE_VARS_OUT (edit CLOUD_RUN_SERVICES / VM_NAME / BUCKET_NAME if relevant)."
fi

echo
echo "Substituted placeholders across ${#FILES[@]} files."
echo
echo "Remaining {{…}} occurrences (should only be Grafana label interp like {{resource.label.service_name}}):"
# Excludes:
#   - init.sh itself (contains the placeholder names as documentation)
#   - justfile (just uses {{var}} for its own recipe argument interpolation)
grep -rnE '\{\{[a-z_]+\}\}' "$HERE" \
  --include='*.tf' --include='*.json' --include='*.yaml' --include='*.md' --include='*.sh' \
  --exclude='init.sh' \
  || echo "  (none)"

cat <<EOF

Next steps:

  1. Move/copy these into your project:
       services/grafana/
       .github/workflows/deploy-grafana-dashboards.yaml
       tests/schemas/grafana-dashboard-5.x.json

  2. Make sure the stack \`$GRAFANA_STACK.grafana.net\` exists. If not, create
     it once via https://grafana.com/orgs/$GRAFANA_CLOUD_ORG/stacks (free tier
     allows one stack per org; if you already have a stack with a different
     slug, edit services/grafana/infra/stack.tf to reference it).

  3. Create the GCS state bucket:
       gsutil mb -p $GCP_PROJECT -l US gs://$TF_STATE_BUCKET
       gsutil versioning set on gs://$TF_STATE_BUCKET

  4. Create the grafana-cloud-reader GCP service account + grants + key.
     See services/grafana/README.md → "1. GCP service account" for the
     gcloud one-liner.

  5. Create the org-level Cloud bootstrap token at
       https://grafana.com/orgs/$GRAFANA_CLOUD_ORG/access-policies
     with **org-realm** scopes:
       stack-service-accounts:write    # TF mints the per-stack admin SA
       stack-plugins:write             # TF installs plugins on the stack
       stacks:write                    # only if you let TF create stacks (Pro tier)
     Then stash the token in Secret Manager:
       gcloud secrets create grafana-cloud-access-policy-token --project=$GCP_PROJECT --replication-policy=automatic
       echo -n "<glc_…token>" | gcloud secrets versions add grafana-cloud-access-policy-token --data-file=- --project=$GCP_PROJECT

  6. If you have multiple GCP projects, point ADC's quota project at this
     one so the GCS state backend doesn't 403 with UserProjectAccountProblem:
       gcloud auth application-default set-quota-project $GCP_PROJECT

  7. cd services/grafana && just init && just apply

The same org bootstrap token in step 5 can be reused for every app you
spin up in this Cloud org — you don't make a new one per app.
EOF
