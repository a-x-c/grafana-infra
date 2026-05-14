---
name: setup-axc-grafana
description: Bootstrap Grafana Cloud observability for a new app — creates a folder + 3 GCP datasources + starter dashboard(s) in the existing axc.grafana.net stack, plus the GCP-side prep (state bucket, reader SA, Secret Manager secrets). Targets Andrew's "one-stack, folder-per-app" pattern where every app is its own GCP project. Auto-detects what GCP services the project uses and picks matching starter dashboards. Use when the user says "set up grafana for X", "bootstrap grafana for this project", "wire up observability", or "/setup-axc-grafana".
user_invocable: true
tools: Bash, Read, Edit, Write, AskUserQuestion, Glob, Grep
argument-hint: [project_slug]
---

# Setup axc Grafana

Brings up a new app's observability inside the existing `axc.grafana.net` stack. Each app gets its own folder, seven datasources (Cloud Monitoring, Cloud Logging, BigQuery + Mimir/Loki/Tempo/Pyroscope), and starter dashboards matched to what the project actually runs. Proven on `imu` (Cloud Run) and `llms-blog` (GCE VM); template lives at `~/Dev/templates/grafana/`.

## Constants (never ask the user)

- Grafana Cloud org: `axc`
- Grafana stack: `axc.grafana.net` (existing, shared across all apps)
- Template source: `~/Dev/templates/grafana/`
- Reader SA name: `grafana-cloud-reader`
- Reader SA key secret: `grafana-cloud-reader-sa-key`
- Bootstrap token secret: `grafana-cloud-access-policy-token`

## Workflow

Idempotent — every step checks current state before acting. Don't plough through ambiguity; ask if anything is unclear.

### 1. Gather inputs

Auto-detect aggressively, then confirm via `AskUserQuestion`.

**Required inputs:**

- **`PROJECT_SLUG`** (kebab-case): from `$ARGUMENTS`, else repo basename, else ask.
- **`DISPLAY_NAME`**: default = `PROJECT_SLUG`. Check `README.md` / `CLAUDE.md` for a branded name (e.g. llms-blog → llms.blog). If different from slug, surface both options in `AskUserQuestion`.
- **`GCP_PROJECT`**: try in order, halting on the first hit:
  1. Any `project_id = "..."` line in `<project>/**/terraform.tfvars`
  2. Any `default = "..."` after `variable "project_id" {` in `<project>/**/variables.tf`
  3. `gcloud projects list --filter="projectId:${PROJECT_SLUG}*"` → pick the most recent / only match
  4. Ask. Suggest `${PROJECT_SLUG}-prod-axc` (Andrew's pattern).
- **`GH_REPO`**: from `git -C <project> remote get-url origin`, normalized to `org/repo`.

**Detected from project conventions** (do not hardcode):

- **`DEST_PATH`** — find the project's TF home and put grafana TF next to it. Scan in order:
  1. `<project>/infra/terraform/<existing-subdir>/` exists → use `infra/terraform/grafana/`
  2. `<project>/tf/<*.tf>` exists → use `tf/grafana/`
  3. `<project>/infra/<*.tf>` exists → use `infra/grafana/`
  4. Otherwise → `services/grafana/`

  Refuse to overwrite an existing `<dest>`.

- **`TF_STATE_BUCKET`** — find an existing state bucket if the project has one, reuse it:
  1. `grep -rhE 'backend "gcs"' -A3 <project>` → if it finds an existing bucket name, propose reusing it with prefix derived from `DEST_PATH` (e.g. prefix `infra/grafana` if dest is `infra/terraform/grafana`).
  2. Otherwise default `${GCP_PROJECT}-tfstate` (no dash — matches llms-blog) or `${GCP_PROJECT}-tf-state` (with dash — matches imu). Pick whichever convention already exists in the user's other projects; if uncertain, ask.

Show the assembled config and confirm before any side effects.

### 2. Verify prereqs

Run in parallel. Halt with a clear next-step on any failure.

| Check | Command | On failure |
| --- | --- | --- |
| Template present | `test -d ~/Dev/templates/grafana/services/grafana/infra` | Stop. |
| Active gcloud account | `gcloud auth list --format='value(account)' --filter='status:ACTIVE'` | `! gcloud auth login` |
| ADC works | `gcloud auth application-default print-access-token >/dev/null 2>&1` | `! gcloud auth application-default login` |
| ADC quota project | parse `~/.config/gcloud/application_default_credentials.json` for `quota_project_id == $GCP_PROJECT` | Auto-fix: `gcloud auth application-default set-quota-project $GCP_PROJECT` |
| GCP project reachable | `gcloud projects describe $GCP_PROJECT` | Wrong project ID. |
| Terraform >= 1.7 | `terraform version` | Stop. |
| just installed | `just --version` | Stop. |
| gsutil installed | `gsutil version` | Stop. |

Enable required APIs on `$GCP_PROJECT` (idempotent):

```bash
for api in iam.googleapis.com iamcredentials.googleapis.com secretmanager.googleapis.com \
           storage.googleapis.com monitoring.googleapis.com logging.googleapis.com bigquery.googleapis.com; do
  gcloud services list --enabled --project=$GCP_PROJECT --format='value(config.name)' --filter="config.name=$api" \
    | grep -q . || gcloud services enable "$api" --project=$GCP_PROJECT
done
```

### 3. Bootstrap token

The `grafana-cloud-access-policy-token` is org-level, reusable across every app.

```bash
gcloud secrets versions access latest --secret=grafana-cloud-access-policy-token --project=$GCP_PROJECT 2>/dev/null | head -c 1
```

**If non-empty:** skip to step 4.

**If missing / empty:** ask the user (via `AskUserQuestion`) whether they have it in *another* app's GCP project. If yes, ask which project, then:

```bash
# Create destination secret if needed
gcloud secrets describe grafana-cloud-access-policy-token --project=$GCP_PROJECT >/dev/null 2>&1 \
  || gcloud secrets create grafana-cloud-access-policy-token --project=$GCP_PROJECT --replication-policy=automatic

# Copy from source project
gcloud secrets versions access latest --secret=grafana-cloud-access-policy-token --project=<source-project> \
  | gcloud secrets versions add grafana-cloud-access-policy-token --data-file=- --project=$GCP_PROJECT
```

If they don't have it in another project, print these instructions and **wait** for the user:

> 1. Open https://grafana.com/orgs/axc/access-policies
> 2. Click **Create access policy**
> 3. Realm: **Organization** (axc)
> 4. Scopes: `stack-service-accounts:write`, `stack-plugins:write`,
>    `accesspolicies:read`, `accesspolicies:write`
>    (the last two are required so TF can mint the per-app stack-reads
>    access policy that powers Loki/Mimir/Tempo/Pyroscope auth)
> 5. Save. Click **Add token** on the new policy, copy the `glc_…` string.

The existing `axc` bootstrap policy was confirmed (May 2026) to already
carry all the needed scopes, so apps adopting the template *after* imu /
llms-blog don't need to touch the policy unless they're on a different
Grafana Cloud org. If TF apply fails with `accesspolicies:write` /
`accesspolicies:read` missing, edit the existing access policy in the
grafana.com UI and add them — tokens issued by the policy continue
working with the expanded scopes; no token rotation needed.

Tell the user to paste with this command in their own terminal (never through chat):

```
! ( gcloud secrets describe grafana-cloud-access-policy-token --project=__GCP_PROJECT__ >/dev/null 2>&1 \
      || gcloud secrets create grafana-cloud-access-policy-token --project=__GCP_PROJECT__ --replication-policy=automatic ) \
  && read -s -p "Paste glc_… token: " T && echo \
  && printf '%s' "$T" | gcloud secrets versions add grafana-cloud-access-policy-token --data-file=- --project=__GCP_PROJECT__
```

Re-verify before continuing.

### 4. Verify `axc` stack exists

```bash
TOK=$(gcloud secrets versions access latest --secret=grafana-cloud-access-policy-token --project=$GCP_PROJECT)
curl -sSf -H "Authorization: Bearer $TOK" https://www.grafana.com/api/instances/axc >/dev/null
```

If 404 → walk user through creating it at https://grafana.com/orgs/axc/stacks (slug `axc`).

### 5. Pick starter dashboards based on project's services

Scan the project's TF for GCP resource types and pick matching starters. **`gcp-billing-costs.json` always lands** (billing is universal).

| Detected resource | Dashboard to copy | VM/bucket placeholders to fill |
| --- | --- | --- |
| `google_cloud_run_v2_service` or `google_cloud_run_service` | `cloud-run-overview.json` | swap `service-one`/`-two`/`-three` for detected service names (pipe-joined regex + options list); see step 5d |
| `google_compute_instance` | `gce-vm-overview.json` | swap `__VM_NAME__` for the VM `name`/var, `__BUCKET_NAME__` for the first `google_storage_bucket` name/var |
| `google_container_cluster` | *(not yet shipped — skip for now, suggest user adds manually)* | — |
| `google_cloudfunctions(2)_function` | *(not yet shipped — skip)* | — |
| none of the above | offer the user a choice: cloud-run, gce, or no app dashboard (just billing) | — |

Detection commands:

```bash
# Cloud Run
grep -rEl '^resource "google_cloud_run_(v2_)?(service|job)"' <project>/**/*.tf 2>/dev/null

# GCE
grep -rEl '^resource "google_compute_instance"' <project>/**/*.tf 2>/dev/null
# Extract VM name (literal or var → resolve default):
grep -A2 '^resource "google_compute_instance"' <tf-file> | grep -E '^\s*name\s*=' | head -1
# If `name = var.<x>`, look up `variable "<x>" { ... default = "..." }`.

# GCS buckets (for GCE dashboard's $bucket var)
grep -A2 '^resource "google_storage_bucket"' <tf-file> | grep -E '^\s*name\s*=' | head -1
```

Present the detected services + the dashboards to copy via `AskUserQuestion` (multiSelect: false on the "is this right?" question) before proceeding.

### 6. Copy template + substitute placeholders

Refuse if `<project>/<DEST_PATH>` or `.github/workflows/deploy-grafana-dashboards.yaml` already exist.

```bash
mkdir -p <project>/<DEST_PATH> <project>/.github/workflows
# services/grafana/ already contains schemas/, scripts/, dashboards/, infra/,
# .template-vars.example, justfile, README.md — copy the lot.
cp -r ~/Dev/templates/grafana/services/grafana/. <project>/<DEST_PATH>/

# Drop dashboards that don't match this project's services
for d in cloud-run-overview gce-vm-overview; do
  if [[ ! " ${KEEP_DASHBOARDS[*]} " =~ " $d " ]]; then
    rm -f <project>/<DEST_PATH>/dashboards/$d.json
  fi
done

# Workflows (ask if user wants CI; default yes)
cp ~/Dev/templates/grafana/.github/workflows/deploy-grafana-dashboards.yaml <project>/.github/workflows/
cp ~/Dev/templates/grafana/.github/workflows/sync-grafana-template.yaml      <project>/.github/workflows/

# Pre-commit config (ask if user wants it; default yes if they don't have one).
# If <project>/.pre-commit-config.yaml exists, merge the hooks instead of
# overwriting — don't clobber the user's existing setup.
test -f <project>/.pre-commit-config.yaml \
  || cp ~/Dev/templates/grafana/.pre-commit-config.yaml <project>/
```

Substitute placeholders inline:

```bash
mapfile -t FILES < <(
  find <project>/<DEST_PATH> \
       <project>/.github/workflows/deploy-grafana-dashboards.yaml \
       <project>/.github/workflows/sync-grafana-template.yaml \
    -type f \
    \( -name '*.tf' -o -name '*.json' -o -name '*.yaml' -o -name '*.yml' \
       -o -name '*.md' -o -name 'justfile' -o -name '*.sh' -o -name '.template-vars*' \) \
    -not -path '*/schemas/grafana-dashboard-5.x.json'
)
for f in "${FILES[@]}"; do
  sed -i \
    -e "s|{{project_slug}}|$PROJECT_SLUG|g" \
    -e "s|{{display_name}}|$DISPLAY_NAME|g" \
    -e "s|{{gcp_project}}|$GCP_PROJECT|g" \
    -e "s|{{grafana_stack}}|axc|g" \
    -e "s|{{grafana_cloud_org}}|axc|g" \
    -e "s|{{tf_state_bucket}}|$TF_STATE_BUCKET|g" \
    -e "s|{{gh_repo}}|$GH_REPO|g" \
    -e "s|{{dest_path}}|$DEST_PATH|g" \
    "$f"
done

# Materialize .template-vars from .example for the sync flow to consume.
mv <project>/<DEST_PATH>/.template-vars.example <project>/<DEST_PATH>/.template-vars
# Populate the per-app runtime detections (left blank in the example):
sed -i \
  -e "s|^CLOUD_RUN_SERVICES=.*|CLOUD_RUN_SERVICES=${DETECTED_CLOUD_RUN_SERVICES:-}|" \
  -e "s|^VM_NAME=.*|VM_NAME=${DETECTED_VM_NAME:-}|" \
  -e "s|^BUCKET_NAME=.*|BUCKET_NAME=${DETECTED_BUCKET_NAME:-}|" \
  <project>/<DEST_PATH>/.template-vars
```

**For GCE dashboard:** swap the runtime-detected placeholders too.

```bash
if [ -f <project>/<DEST_PATH>/dashboards/gce-vm-overview.json ]; then
  sed -i \
    -e "s|__VM_NAME__|$DETECTED_VM_NAME|g" \
    -e "s|__BUCKET_NAME__|$DETECTED_BUCKET_NAME|g" \
    <project>/<DEST_PATH>/dashboards/gce-vm-overview.json
fi
```

**For Cloud Run dashboard:** swap `service-one`/`-two`/`-three` for actual service names if detected. Use `python3 -c` with `json.load`/`json.dump` to edit the `templating.list[0]` (`query`, `allValue` pipe-joined, `options` list) — sed is too fragile for nested JSON arrays.

**Adjust workflow paths if `DEST_PATH != services/grafana`:**

```bash
for wf in deploy-grafana-dashboards.yaml sync-grafana-template.yaml; do
  sed -i "s|services/grafana/|$DEST_PATH/|g" <project>/.github/workflows/$wf
done
```

Note: the schema file lives at `<DEST_PATH>/schemas/grafana-dashboard-5.x.json`
in apps (same place as the template). No special schema-path substitution.

**Adjust GCS backend prefix in `main.tf`** to reflect dest path (last path component or shortened form):

```bash
# Pick a sensible prefix that won't collide with the project's existing TF state.
# Rule: derive from DEST_PATH, replacing leading "services/" or "tf/" or "infra/terraform/" with "infra/" and ending with "grafana".
# Examples: services/grafana → infra/grafana, infra/terraform/grafana → infra/grafana, tf/grafana → tf/grafana.
sed -i "s|prefix = \"services/grafana\"|prefix = \"$NEW_PREFIX\"|" <project>/<DEST_PATH>/infra/main.tf
```

Verify substitution and format:

```bash
grep -rnE '\{\{[a-z_]+\}\}|__VM_NAME__|__BUCKET_NAME__' <project>/<DEST_PATH> \
  | grep -vE '\{\{(uid|resource\.|metric\.|labels|severity)' \
  || echo "  (none)"
( cd <project>/<DEST_PATH>/infra && terraform fmt -check )
```

> **Do NOT run `terraform validate` here** — it requires `terraform init` first to load providers. fmt is the only validation that works pre-init.

### 7. Bootstrap GCP (idempotent)

```bash
# State bucket — if reusing an existing one (from project conventions), skip creation.
gsutil ls -b "gs://$TF_STATE_BUCKET" >/dev/null 2>&1 \
  || gsutil mb -p "$GCP_PROJECT" -l US "gs://$TF_STATE_BUCKET"
gsutil versioning set on "gs://$TF_STATE_BUCKET" >/dev/null

# Reader SA
SA_EMAIL="grafana-cloud-reader@${GCP_PROJECT}.iam.gserviceaccount.com"
gcloud iam service-accounts describe "$SA_EMAIL" --project="$GCP_PROJECT" >/dev/null 2>&1 \
  || gcloud iam service-accounts create grafana-cloud-reader \
       --project="$GCP_PROJECT" --display-name="Grafana Cloud reader"

# IAM grants
for role in roles/monitoring.viewer roles/logging.viewer \
            roles/bigquery.dataViewer roles/bigquery.jobUser; do
  gcloud projects add-iam-policy-binding "$GCP_PROJECT" \
    --member="serviceAccount:${SA_EMAIL}" --role="$role" \
    --condition=None --quiet >/dev/null
done

# SA JSON key → Secret Manager (new version every run is fine — TF reads "latest")
KEY=$(mktemp /tmp/sa-key.XXXXXX.json)
trap "rm -f $KEY" EXIT
gcloud iam service-accounts keys create "$KEY" --iam-account="$SA_EMAIL" --project="$GCP_PROJECT" >/dev/null
gcloud secrets describe grafana-cloud-reader-sa-key --project="$GCP_PROJECT" >/dev/null 2>&1 \
  || gcloud secrets create grafana-cloud-reader-sa-key --project="$GCP_PROJECT" --replication-policy=automatic
gcloud secrets versions add grafana-cloud-reader-sa-key --data-file="$KEY" --project="$GCP_PROJECT" >/dev/null
```

### 8. Strip plugin install resources if already on axc (cross-app collision)

Plugin install resources (`grafana_cloud_plugin_installation`) are stack-wide. The first app to apply owns them; subsequent apps must skip them. `terraform import` is the canonical fix but **fails with chicken-and-egg** because the stack provider can't authenticate until the SA token exists, which doesn't until after apply.

Check whether the plugins are already installed:

```bash
TOK=$(gcloud secrets versions access latest --secret=grafana-cloud-access-policy-token --project=$GCP_PROJECT)
INSTALLED=$(curl -sS -H "Authorization: Bearer $TOK" \
  https://www.grafana.com/api/instances/axc/plugins \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(','.join(p['pluginSlug'] for p in d.get('items',[])))")
echo "Plugins already installed on axc: $INSTALLED"
```

If `googlecloud-logging-datasource` or `grafana-bigquery-datasource` is in the list, strip the matching resource(s) from `<DEST_PATH>/infra/stack_admin.tf` AND drop the `depends_on` line(s) from `<DEST_PATH>/infra/datasources.tf`. Replace the stripped block with a comment block explaining cross-app dependency:

```hcl
# Plugin installs intentionally omitted. The plugins
# `googlecloud-logging-datasource` + `grafana-bigquery-datasource` are
# already installed by another TF root on the `axc` stack. If that root
# is destroyed, plugins disappear and this project's datasources break.
# Fix at that time by either re-adding the plugin install resources here
# and `terraform import`-ing them, or moving plugin management to a
# separate shared TF root.
```

### 9. terraform init + apply

```bash
cd <project>/<DEST_PATH>
just init
just apply
```

If `just init` fails with `UserProjectAccountProblem` → step 2 should've fixed it, but re-run `gcloud auth application-default set-quota-project $GCP_PROJECT`.

If `just apply` errors, surface verbatim and stop. Don't autocorrect — these are usually edge cases. Known errors and fixes:

- **"already installed"** on a plugin → step 8 missed it; run step 8 again and re-apply.
- **403 "Hosted instance limit reached"** → template still has `grafana_cloud_stack` *resource* form (we use `data` now). Indicates a stale template; check `<DEST_PATH>/infra/stack.tf` is the `data` form.
- **`grafana_cloud_stack.main.url` is null in output interpolation** → templates' `outputs.tf` predates the `data` rewrite; bump the template.

Capture outputs:

```bash
cd <project>/<DEST_PATH>/infra
terraform output
```

### 10. Post-apply

Print:

- Stack URL: `https://axc.grafana.net`
- Folder URL: `https://axc.grafana.net/dashboards/f/$PROJECT_SLUG`
- Each dashboard's deep link (from `terraform output dashboard_uids`)

Then offer two optional follow-ups (don't auto-do them):

**(a) BigQuery billing export.**

Check whether the `billing_export` dataset exists:

```bash
bq --project_id="$GCP_PROJECT" ls --datasets 2>/dev/null | awk 'NR>2 {print $1}' | grep -qx billing_export
```

If not, offer to create it:

```bash
bq --project_id="$GCP_PROJECT" --location=US mk --description="GCP billing export destination" billing_export
```

Then print the manual UI step (no gcloud equivalent):

> Cloud Console → Billing → Billing export → Detailed usage cost → Edit settings → Project: `$GCP_PROJECT`, Dataset: `billing_export` → Save.

Read billing account ID from `<project>/**/terraform.tfvars` if available so the URL can be exact.

**(b) Verify dashboards in the UI.**

Curl-check that the folder + dashboards landed:

```bash
TOK=$(cd <project>/<DEST_PATH>/infra && terraform output -raw stack_admin_token)
curl -sS -H "Authorization: Bearer $TOK" https://axc.grafana.net/api/folders/$PROJECT_SLUG
curl -sS -H "Authorization: Bearer $TOK" "https://axc.grafana.net/api/search?folderUIDs=$PROJECT_SLUG"
```

## Hard rules

- **Never echo secrets into chat.** Token paste uses `! read -s` so values never enter the conversation.
- **Never overwrite existing files.** If `<DEST_PATH>` exists, stop. If the workflow file exists, stop.
- **Never destructive gcloud actions.** No `gcloud secrets delete`, no `gcloud iam service-accounts delete`, no `gsutil rm`. All commands here are idempotent creates / IAM additions.
- **Don't run `terraform apply` without confirmation** if state is non-empty (modification risk). First-time bootstrap on a fresh state is OK to auto-apply.

## Cross-app plugin install management

Long-term, the right pattern is to factor plugin installs into a separate "shared" TF root that no individual app owns. Suggest this to the user once they have 3+ apps on the same stack. Until then, step 8's "strip + comment" workaround is fine.

## Quick reference — what gets created

Per app (in `$GCP_PROJECT`):

- `gs://<state-bucket>` (existing or new, versioned)
- `grafana-cloud-reader` SA + monitoring/logging viewer + bigquery dataViewer/jobUser
- Secret `grafana-cloud-reader-sa-key` (SA JSON key)
- Secret `grafana-cloud-access-policy-token` (copied from another app, or freshly minted)

Per app (in axc.grafana.net):

- Folder `$PROJECT_SLUG` (UID + title = `$PROJECT_SLUG` / `$DISPLAY_NAME`)
- 7 datasources:
  - `$PROJECT_SLUG-gcp-monitoring`, `$PROJECT_SLUG-gcp-logging`, `$PROJECT_SLUG-bigquery`
  - `$PROJECT_SLUG-prometheus` (Mimir), `$PROJECT_SLUG-loki`, `$PROJECT_SLUG-tempo`, `$PROJECT_SLUG-pyroscope`
- Starter dashboard(s) matching detected services: `$PROJECT_SLUG-cloud-run-overview` / `$PROJECT_SLUG-gce-overview`
- Always: `$PROJECT_SLUG-gcp-billing`
- Stack admin SA `$PROJECT_SLUG-tf-admin` + its glsa_ token (TF-managed, in state)
- Stack-reads access policy `$PROJECT_SLUG-stack-reads` + token (powers the 4 hosted-backend datasources)

Once per org (shared, first app owns; subsequent apps skip):

- Plugin installs: `googlecloud-logging-datasource`, `grafana-bigquery-datasource`
- Mimir/Loki/Tempo/Pyroscope datasource types are built-in — no plugin install needed.
