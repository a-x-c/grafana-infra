# Grafana Cloud — IaC Template

Drop-in scaffolding for a Grafana-Cloud-backed observability setup on top of
GCP. Mirrors the pattern from `stackmatix-app/backend/services/grafana/`:
JSON dashboards + Terraform-managed folder / datasources / access policies +
GCS-backed state + a GH Actions workflow that validates JSON on PR and
applies on `main`. Plus a sync flow so downstream apps can pull template
dashboard updates without re-bootstrapping.

## What's in the box

```
.
├── README.md                                # this file — template usage
├── init.sh                                  # placeholder substitution helper
├── .pre-commit-config.yaml                  # JSON parseability, terraform_fmt, convention check
├── .github/workflows/
│   ├── deploy-grafana-dashboards.yaml       # validate on PR, apply on main
│   └── sync-grafana-template.yaml           # daily drift check → opens PR
└── services/grafana/
    ├── README.md                            # day-to-day authoring + ops guide
    ├── justfile                             # plan / apply / export / rotate / sync
    ├── .template-vars.example               # per-app substitution vars (copied at init)
    ├── dashboards/
    │   ├── cloud-run-overview.json          # Cloud Run req rate, p95, instances, WARN+ logs
    │   ├── gce-vm-overview.json             # GCE VM CPU/network/disk/logs + GCS bucket metrics
    │   └── gcp-billing-costs.json           # GCP billing export (BigQuery)
    ├── infra/
    │   ├── main.tf                          # providers (cloud + stack alias) + GCS backend
    │   ├── variables.tf
    │   ├── stack.tf                         # data source: reference existing stack
    │   ├── stack_admin.tf                   # stack admin SA + plugins + stack-reads token
    │   ├── folders.tf
    │   ├── datasources.tf                   # GCP Monitoring/Logging/BQ + Mimir/Loki/Tempo/Pyroscope
    │   ├── dashboards.tf                    # fileset() over dashboards/*.json
    │   ├── alerting.tf                      # commented contact_point + rule_group examples
    │   └── outputs.tf
    ├── schemas/
    │   └── grafana-dashboard-5.x.json       # used by CI + pre-commit dashboard validation
    └── scripts/
        ├── export-dashboard.sh              # pull a dashboard from the UI back to JSON
        ├── sync-from-template.sh            # pull dashboard updates from this template into an app
        └── validate-dashboards.py           # convention + schema check; shared by pre-commit + CI
```

## What this gives you

- **GCP data sources** — Cloud Monitoring (Cloud Run, Pub/Sub, GCS, etc.),
  Cloud Logging (severity/jsonPayload queries), BigQuery (billing exports,
  app analytics), all authenticated via one GCP service-account JWT.
- **Grafana-Cloud-hosted data sources** — Mimir (Prometheus-compatible),
  Loki, Tempo, Pyroscope, wired with a TF-minted stack-scoped read access
  policy token. Tempo is linked to Loki + Mimir + Pyroscope for one-click
  exemplar navigation. Apps that don't ship telemetry yet can still query
  the empty backends; queries simply return no data until data arrives.
- **Three starter dashboards** — `cloud-run-overview`, `gce-vm-overview`,
  `gcp-billing-costs`. App-specific dashboards (Loki / Tempo / Pyroscope
  views) are deliberately not shipped; they belong in each app once it has
  real telemetry to point at.
- **TF-minted stack-admin token** — no `glsa_…` paste step. You create one
  org-level bootstrap token once in the grafana.com UI; TF mints and rotates
  the stack-level token itself via `grafana_cloud_stack_service_account` +
  `grafana_cloud_stack_service_account_token`.
- **Plugin pre-install** — `googlecloud-logging-datasource` and
  `grafana-bigquery-datasource` are installed via `grafana_cloud_plugin_installation`
  before the datasources that need them are created. (Loki / Tempo /
  Pyroscope / Prometheus data source types are built-in — no plugin install.)
- **CI** — PRs get a `terraform plan` comment + JSON validation; pushes to
  `main` get `terraform apply -auto-approve`. A separate daily workflow
  (`sync-grafana-template.yaml`) opens a PR if upstream template dashboards
  have drifted from the app's local copies.
- **Alerting scaffold** — `alerting.tf` ships a worked-out (but commented)
  contact point + notification policy + Cloud Run 5xx rule group.
- **Local validation** — `.pre-commit-config.yaml` runs JSON parseability,
  `terraform_fmt`, end-of-file/trailing-whitespace fixes, and the same
  dashboard convention check CI runs. Apps inherit this config when they
  copy the template.

## Template → app sync

The downstream-app problem: each app's dashboards have been transformed
(`{{project_slug}}` → `imu`, `service-one` → `imu-api`, etc.) by `init.sh`
during bootstrap. Naïvely rsync'ing from the template would clobber those
substitutions. The sync flow re-applies them on every pull.

**Mechanism:**

- Each app stores its substitution vars in `services/grafana/.template-vars`
  (or wherever the grafana subtree lives — `tf/grafana/`, `infra/terraform/grafana/`,
  etc.). Generated automatically by `init.sh`.
- `just sync-from-template REF=main` (or `--ref v2026.05.20`) clones the
  template at the given ref, re-runs substitution against the template's
  dashboard JSONs using the app's stored vars, and overwrites only
  dashboards that already exist locally. New dashboards in the template
  are reported but not added — copy them in manually with `--include`.
- `.github/workflows/sync-grafana-template.yaml` runs the same script
  daily; non-empty diff opens a PR.

**Discipline:** app-specific dashboards go in *new* files. Don't hand-edit
templated ones — your edits will be reverted on the next sync. If a
templated dashboard is wrong for your app, fork it to `<name>-custom.json`
and delete the templated copy.

## Quick start

```bash
# 1. Copy this directory tree somewhere — either standalone repo or merged
#    into an existing repo's root.
git clone <this-template> myproject-grafana
cd myproject-grafana

# 2. Substitute placeholders. Interactive by default; prompts walk through
#    project_slug, display_name, gcp_project, etc. Writes
#    services/grafana/.template-vars at the end.
./init.sh

# 3. Move into target repo if you cloned standalone:
#    cp -r services/grafana <target>/services/
#    cp -r .pre-commit-config.yaml <target>/    # optional
#    cp .github/workflows/deploy-grafana-dashboards.yaml <target>/.github/workflows/
#    cp .github/workflows/sync-grafana-template.yaml     <target>/.github/workflows/

# 4. Bootstrap GCP side (one-time per project):
#    - create the GCS state bucket
#    - create the grafana-cloud-reader GCP service account + JSON key
#    - store the JSON key in Secret Manager as `grafana-cloud-reader-sa-key`
#    See services/grafana/README.md → "GCP service account" for the IAM grants.

# 5. Bootstrap Grafana Cloud side (one-time):
#    - in https://grafana.com/orgs/<org>/access-policies, create an access
#      policy named e.g. `<project>-tf-bootstrap` with scopes
#      `stack-service-accounts:write`, `stack-plugins:write`,
#      `accesspolicies:read`, `accesspolicies:write`
#      and a token from it.
#    - store the token in Secret Manager as `grafana-cloud-access-policy-token`.

# 6. Apply.
cd services/grafana
just init
just apply

# 7. Install pre-commit (optional but recommended).
pip install --user pre-commit && pre-commit install
```

After the first apply, day-to-day work happens in `services/grafana/` — see
its README.

## Non-interactive `init.sh`

For scripted / CI templating:

```bash
PROJECT_SLUG=myproject \
DISPLAY_NAME=MyProject \
GCP_PROJECT=myproject-app \
GRAFANA_STACK=myproject \
GRAFANA_CLOUD_ORG=myproject \
GRAFANA_CLOUD_REGION=us \
TF_STATE_BUCKET=myproject-app-tf-state \
GH_REPO=myorg/myproject \
./init.sh --non-interactive
```

## Bumping the template

When the template ships a dashboard change you want in your apps:

1. Land it in this repo (PR + merge to `main`).
2. Tag a release: `git tag v2026.05.20 && git push --tags`.
3. In each downstream app, either:
   - Wait for the daily `sync-grafana-template` workflow to open a PR
     (it'll re-target `main`, or whatever `TEMPLATE_REF` is in
     `.template-vars`).
   - Or run manually: `just sync-from-template REF=v2026.05.20` →
     `git diff dashboards/` → commit if happy.

## What this template does NOT include

These are easy to add when you need them:

- **Alerting that actually fires** — `alerting.tf` is commented out by
  default. Uncomment + edit contact-point recipients.
- **Synthetic Monitoring** — uptime/HTTP/DNS checks via
  `grafana_synthetic_monitoring_check`.
- **OnCall** — schedules/escalations via `grafana_oncall_*`.
- **SLOs** — `grafana_slo`.
- **Data-shipping config** — Mimir/Loki/Tempo/Pyroscope queryers are wired,
  but actually getting telemetry INTO Grafana Cloud (OTel collector,
  Alloy, profiling SDKs) is per-app and out of scope here.
- **Self-hosted Loki/Prometheus** — this template is Cloud-only. For a
  Docker-Compose-based local stack, see
  `stackmatix-app/backend/services/observability/`.

## Source

Based on the May 2026 setup in
`~/Dev/workspaces/stackmatix-app/backend/services/grafana/` and the
companion docs in `backend/docs/grafana.md`.
