# Grafana Cloud (IaC)

Terraform-managed dashboards, datasources, and folder on
`{{grafana_stack}}.grafana.net`, plus a TF-minted stack admin SA + token
and the required plugin installs.

```
services/grafana/
├── dashboards/         # raw dashboard JSON, one file per dashboard
├── infra/              # terraform (providers, stack reference, admin SA, stack-reads token, datasources, folder, dashboards, alerting)
├── schemas/            # JSON Schema used by pre-commit + CI
├── scripts/            # helpers: export-dashboard.sh, sync-from-template.sh, validate-dashboards.py
├── .template-vars      # per-app substitution values, consumed by sync-from-template
└── justfile
```

## Authoring model

JSON-first. Dashboards live as JSON files in `dashboards/`. Terraform's
`grafana_dashboard.all` walks the directory via `for_each` and applies
every file with `overwrite = true`, so TF always wins on drift.

When you tweak a dashboard in the Grafana Cloud UI, pull it back with
`just export-dashboard <uid>` so the change survives the next
`terraform apply`.

## Stack model — one stack, folder-namespaced apps

The TF here **references** an existing stack via a `data` block; it does
not create one. Reason: Grafana Cloud's free tier caps an org at one
hosted instance, so per-app stacks require Pro tier ($19/mo+). The
recommended pattern for solo devs / small teams is to create one stack
per Cloud org and namespace apps by folder + UID prefix:

```
{{grafana_stack}}.grafana.net
├── Folder: {{display_name}}      ← this app, UIDs = "{{project_slug}}-*"
├── Folder: AnotherApp            ← next app, UIDs = "anotherapp-*"
└── Folder: ThirdApp              ← ...
```

When you add another app, its TF root references the same stack via the
same data block, picks its own `{{project_slug}}` and `{{display_name}}`,
and creates its own folder + datasources + dashboards in the same stack.
No collisions as long as UID prefixes differ.

## Bootstrap (one-time per app)

Prerequisites:
- `terraform` >= 1.7
- `gcloud auth application-default login`
- `gcloud auth application-default set-quota-project {{gcp_project}}` if you
  have multiple GCP projects (avoids `UserProjectAccountProblem` on the GCS
  backend)
- `roles/secretmanager.secretAccessor` on the GCP secrets below
- An existing Grafana Cloud stack `{{grafana_stack}}` (create at
  https://grafana.com/orgs/{{grafana_cloud_org}}/stacks if needed)

### 1. GCP service account

```bash
gcloud iam service-accounts create grafana-cloud-reader \
  --project={{gcp_project}} \
  --display-name="Grafana Cloud reader"

EMAIL="grafana-cloud-reader@{{gcp_project}}.iam.gserviceaccount.com"

for role in roles/monitoring.viewer roles/logging.viewer roles/bigquery.dataViewer roles/bigquery.jobUser; do
  gcloud projects add-iam-policy-binding {{gcp_project}} \
    --member="serviceAccount:${EMAIL}" --role="$role" --condition=None
done

gcloud iam service-accounts keys create /tmp/sa.json --iam-account="$EMAIL"
gcloud secrets create grafana-cloud-reader-sa-key --project={{gcp_project}} --replication-policy=automatic
gcloud secrets versions add grafana-cloud-reader-sa-key --data-file=/tmp/sa.json --project={{gcp_project}}
rm /tmp/sa.json
```

### 2. Grafana Cloud bootstrap token

Create an access policy at
https://grafana.com/orgs/{{grafana_cloud_org}}/access-policies with **org**
realm and scopes:

- `stack-service-accounts:write` — so TF can mint the per-stack admin SA
- `stack-plugins:write` — so TF can install plugins on the stack
- `stacks:write` *(optional, only if you create stacks via TF — Pro tier)*

Create a token from it, then stash in Secret Manager:

```bash
gcloud secrets create grafana-cloud-access-policy-token --project={{gcp_project}} --replication-policy=automatic
echo -n "<glc_…token>" | gcloud secrets versions add grafana-cloud-access-policy-token \
  --data-file=- --project={{gcp_project}}
```

The same org token can be reused across every app in this Cloud org — you
don't make a new one per app.

### 3. GCS state bucket

```bash
gsutil mb -p {{gcp_project}} -l US gs://{{tf_state_bucket}}
gsutil versioning set on gs://{{tf_state_bucket}}
```

### 4. Init + first apply

```bash
just init
just apply
```

First apply creates: the stack admin SA + token (in TF state, not pasted
anywhere), the plugin installs, the folder, the three datasources, and the
dashboards. Plan output may show stack-side resources as `(known after
apply)` on the very first run because the `grafana.stack` provider's auth
depends on the SA token TF mints in the same apply. Subsequent plans are
clean.

## Day-to-day

| Workflow | Command |
| --- | --- |
| Add a new dashboard | drop `dashboards/<slug>.json` → `just apply` (or merge to `main` and let CI apply) |
| UI edit → pull back to repo | `just export-dashboard <uid>` → commit → `just apply` |
| See pending changes | `just plan` |
| Rotate stack-admin token | `just rotate-stack-token` (taints + re-mints via TF) |
| Rotate org bootstrap token | rotate in grafana.com UI → `just rotate-cloud-token` |

### CI

`.github/workflows/deploy-grafana-dashboards.yaml` watches `services/grafana/`.

- **PRs** → validate every dashboard JSON (parseability, UID prefix
  (`{{project_slug}}-`), title prefix (`{{display_name}}`), `schemaVersion >= 39`,
  JSON-Schema check) and post a `terraform plan` comment.
- **Push to `main`** → `terraform apply -auto-approve`.

Required GH secrets (mirror GCP Secret Manager via `just sync-secrets-to-gh`):

- `GRAFANA_CLOUD_ACCESS_POLICY_TOKEN` — org bootstrap token (`glc_…`)
- `GRAFANA_CLOUD_READER_SA_KEY` — GCP SA JSON

Required GH vars (for Workload Identity Federation to the GCS state bucket):

- `GCP_WORKLOAD_IDENTITY_PROVIDER`
- `GCP_SERVICE_ACCOUNT`

## Datasources (referenced from dashboard JSON)

| Datasource | UID | Type | Use for |
| --- | --- | --- | --- |
| Cloud Monitoring | `{{project_slug}}-gcp-monitoring` | `stackdriver` (built-in) | GCP-native metrics (Cloud Run, GCS, Cloud SQL, Pub/Sub, etc.) |
| Cloud Logging | `{{project_slug}}-gcp-logging` | `googlecloud-logging-datasource` | Log queries (Cloud Run stdout, audit logs) |
| BigQuery | `{{project_slug}}-bigquery` | `grafana-bigquery-datasource` | Any BQ table — billing exports, app analytics, custom data |
| Mimir | `{{project_slug}}-prometheus` | `prometheus` (built-in) | App metrics shipped to Grafana Cloud's hosted Prometheus (Prom-compatible PromQL) |
| Loki | `{{project_slug}}-loki` | `loki` (built-in) | App logs shipped to Grafana Cloud's hosted Loki (LogQL) |
| Tempo | `{{project_slug}}-tempo` | `tempo` (built-in) | Distributed traces shipped via OTLP; pre-wired to Loki/Mimir/Pyroscope for trace navigation |
| Pyroscope | `{{project_slug}}-pyroscope` | `grafana-pyroscope-datasource` (built-in) | Continuous profiles (CPU, allocs, ...) |

These UIDs are stable. Hard-code them in `panels[*].datasource.uid`. The
last four backends share auth: a stack-scoped read access policy minted in
`stack_admin.tf` (`grafana_cloud_access_policy.stack_reads`). They're
queryable on day one — they'll just return no data until an app ships
telemetry to them.

## Adding a new dashboard

### Option A: import from grafana.com

Most community dashboards ship with `__inputs` placeholders that need to
be substituted. Pattern (see `dashboards/gcp-billing-costs.json` for a
worked example):

```bash
ID=12494  # the grafana.com dashboard ID
curl -sS "https://grafana.com/api/dashboards/${ID}/revisions/1/download" -o /tmp/raw.json

python3 <<'PY'
import json
d = json.load(open('/tmp/raw.json'))

# 1. Strip import metadata
for k in ('__inputs', '__elements', '__requires', 'id', 'version', 'iteration'):
    d.pop(k, None)

# 2. Stamp the naming convention
d['uid']   = '{{project_slug}}-<slug>'
d['title'] = '{{display_name}} — <Human Title>'
d['tags']  = ['{{project_slug}}', '<topic>']

# 3. Replace ${DS_*} datasource placeholders with concrete UIDs
TARGET_DS = {'type': 'grafana-bigquery-datasource', 'uid': '{{project_slug}}-bigquery'}
def walk(o):
    if isinstance(o, dict):
        for k, v in list(o.items()):
            if k == 'datasource' and (isinstance(v, str) and v.startswith('${DS_')
                                      or isinstance(v, dict) and v.get('uid','').startswith('${DS_')):
                o[k] = TARGET_DS
            else:
                walk(v)
    elif isinstance(o, list):
        for x in o: walk(x)
walk(d)

json.dump(d, open('dashboards/<slug>.json', 'w'), indent=2)
PY

just apply
```

### Option B: hand-author

Minimum viable dashboard JSON (Grafana 10+, `schemaVersion: 39`):

```json
{
  "uid": "{{project_slug}}-<slug>",
  "title": "{{display_name}} — <Title>",
  "tags": ["{{project_slug}}"],
  "schemaVersion": 39,
  "editable": true,
  "refresh": "30s",
  "time": { "from": "now-1h", "to": "now" },
  "templating": { "list": [] },
  "panels": [ /* see panel target cheatsheet below */ ]
}
```

### Option C: build in the UI, then export

```bash
just export-dashboard <uid>
# wrote dashboards/<slug>.json
just apply
```

## Panel target cheatsheet

### Cloud Monitoring (`{{project_slug}}-gcp-monitoring`)

```json
{
  "refId": "A",
  "queryType": "metrics",
  "metricQuery": {
    "projectName": "{{gcp_project}}",
    "metricType": "run.googleapis.com/request_count",
    "filters": ["resource.label.service_name", "=~", "$service"],
    "aliasBy": "{{resource.label.service_name}}",
    "alignmentPeriod": "stackdriver-auto",
    "perSeriesAligner": "ALIGN_RATE",
    "crossSeriesReducer": "REDUCE_SUM",
    "groupBys": ["resource.label.service_name"]
  }
}
```

Useful Cloud Run metric types:
- `run.googleapis.com/request_count` — counter, `ALIGN_RATE` for req/s
- `run.googleapis.com/request_latencies` — distribution, `ALIGN_DELTA` + `REDUCE_PERCENTILE_95` for p95
- `run.googleapis.com/container/instance_count` — gauge
- `run.googleapis.com/container/cpu/utilizations` — 0–1
- `run.googleapis.com/container/memory/utilizations` — 0–1

Full metric catalog: https://cloud.google.com/monitoring/api/metrics_gcp

### Cloud Logging (`{{project_slug}}-gcp-logging`)

```json
{
  "refId": "A",
  "projectId": "{{gcp_project}}",
  "queryText": "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=~\"$service\" AND severity>=WARNING"
}
```

Common patterns:

- All Cloud Run errors for one service:
  `resource.type="cloud_run_revision" AND resource.labels.service_name="my-service" AND severity>=ERROR`
- HTTP 5xx only:
  `resource.type="cloud_run_revision" AND httpRequest.status>=500`
- Structured-log field match:
  `resource.type="cloud_run_revision" AND jsonPayload.event="payment_failed"`

### BigQuery (`{{project_slug}}-bigquery`)

```json
{
  "refId": "A",
  "rawSql": "SELECT TIMESTAMP_TRUNC(usage_start_time, DAY) AS time, SUM(cost) AS cost, service.description AS service FROM `{{gcp_project}}.billing_export.gcp_billing_export_v1_*` WHERE $__timeFilter(usage_start_time) GROUP BY time, service ORDER BY time",
  "format": "time_series",
  "location": "US",
  "project": "{{gcp_project}}"
}
```

`$__timeFilter(col)` is the Grafana macro that interpolates the dashboard
time range into `BETWEEN ... AND ...` on the given column.

## Template variables

Conventions used across this folder:

- `$service` — multi-select Cloud Run service name. Type `custom`,
  hard-coded values, `allValue` is a regex alternation so metric/log
  filters can use `=~"$service"`.
- `$source_project`, `$source_dataset` — textbox vars used by community
  dashboards (e.g. billing). Set sensible defaults so the dashboard
  works on first load.

See `dashboards/cloud-run-overview.json` (service multi-select) and
`dashboards/gcp-billing-costs.json` (textbox defaults).

## Starter dashboards

The template ships three starters under `dashboards/`. Keep the ones
relevant to your project; delete the rest before first apply.

| File | When to keep |
| --- | --- |
| `cloud-run-overview.json` | Project runs Cloud Run services. Ships with placeholder names `service-one`/`-two`/`-three` — find/replace with actual service names. |
| `gce-vm-overview.json` | Project runs Compute Engine VMs (e.g. self-hosted Ghost, n8n, app servers). Ships with `__VM_NAME__` + `__BUCKET_NAME__` placeholders — find/replace with the actual VM and primary GCS bucket. |
| `gcp-billing-costs.json` | Always keep. Universal; lights up after enabling BigQuery billing export. |

## Conventions

- **UID prefix**: every dashboard UID starts with `{{project_slug}}-`.
- **Title prefix**: every dashboard title starts with `{{display_name}}`.
- **`schemaVersion: 39`** for new dashboards (Grafana 10+).
- **`overwrite: true`** in TF means apply always wins drift — JSON in
  `dashboards/` is the source of truth.

## Alerting

`infra/alerting.tf` ships a fully commented contact-point + notification
policy + Cloud Run 5xx rule-group example. To enable:

1. Uncomment the resources you want.
2. Replace the placeholder email/webhook with real ones.
3. Adjust the rule expressions to match your services.
4. `just apply`.

The stack admin SA in `stack_admin.tf` has role=Admin so all alerting
operations work out of the box; no extra scope grant is needed.

## State

GCS backend: `gs://{{tf_state_bucket}}/services/grafana/`.

## Secrets

| GCP secret | GH secret (CI mirror) | TF var | Contents |
| --- | --- | --- | --- |
| `grafana-cloud-access-policy-token` | `GRAFANA_CLOUD_ACCESS_POLICY_TOKEN` | `cloud_access_policy_token` | Org-level access-policy token (`glc_…`) |
| `grafana-cloud-reader-sa-key` | `GRAFANA_CLOUD_READER_SA_KEY` | `gcp_sa_jwt` | JSON key for `grafana-cloud-reader@{{gcp_project}}` |

Stack-admin token (used internally by the `grafana.stack` provider) lives
in TF state — it's minted by TF, not pasted from the UI.

## Pre-commit dashboard validation

A `.pre-commit-config.yaml` ships at the repo root. Install once:

```bash
pip install --user pre-commit
pre-commit install
```

Hooks:

| Hook | What it does |
| --- | --- |
| `check-json` | dashboard JSON is parseable |
| `terraform_fmt` | `services/grafana/infra/*.tf` are formatted |
| `end-of-file-fixer` / `trailing-whitespace` | sanitize text files |
| `validate-dashboard-conventions` | UID prefix, title prefix, `schemaVersion >= 39`, JSON-Schema check |

The convention hook reads `services/grafana/.template-vars` for
`PROJECT_SLUG` and `DISPLAY_NAME`, so each app enforces its own naming.
The same script (`scripts/validate-dashboards.py`) is what CI runs — if a
commit fails locally, fix the JSON and re-commit; don't `--no-verify`
around it.

## Syncing template updates

Pull dashboard changes from the upstream grafana template into this app:

```bash
just sync-from-template                    # uses TEMPLATE_REF in .template-vars (default: main)
just sync-from-template REF=v2026.05.20    # pin a tag
just sync-from-template-dry-run            # report drift without writing
```

The script (`scripts/sync-from-template.sh`) clones the template at the
given ref, re-runs `init.sh`'s substitutions against the template's
dashboards using this app's `.template-vars`, and writes the result into
`dashboards/` — but only over files that already exist locally. New
dashboards from the template are reported but not added; copy them in
manually with `--include <filename.json>` if you want them.

`.github/workflows/sync-grafana-template.yaml` runs the same flow on cron
and opens a PR when there's drift. App-specific (non-templated)
dashboards are never touched.
