# Stack admin credentials TF uses to manage dashboards/folders/datasources/
# alerting inside the stack.
#
# Why a stack service account, not a cloud access policy: the control-plane
# scopes for CRUD on dashboards/folders/datasources (`dashboards:write`,
# `folders:write`, etc.) only exist on legacy `realm = org` cloud access
# policies. Modern `realm = stack` cloud access policies are limited to
# data-plane scopes (`metrics:read`, `logs:write`, `traces:read`, ...).
# A stack service account with role=Admin is the supported way to mint a
# token (`glsa_…`) the `grafana.stack` provider can use to call the stack's
# own admin API.
resource "grafana_cloud_stack_service_account" "tf_admin" {
  provider = grafana.cloud

  stack_slug  = data.grafana_cloud_stack.main.slug
  name        = "{{project_slug}}-tf-admin"
  role        = "Admin"
  is_disabled = false
}

resource "grafana_cloud_stack_service_account_token" "tf_admin" {
  provider = grafana.cloud

  stack_slug         = data.grafana_cloud_stack.main.slug
  service_account_id = grafana_cloud_stack_service_account.tf_admin.id
  name               = "{{project_slug}}-tf-admin"
  # No seconds_to_live — TF state is the source of truth. Taint + apply to rotate.
}

# Plugin installs. Plugins must exist on the stack before TF tries to create
# a datasource of their type, so these are managed cloud-side and depended-on
# from datasources.tf (`depends_on = [grafana_cloud_plugin_installation.*]`).
#
# Plugin install resources are stack-wide. If another TF root has already
# installed the same plugin on this stack, `terraform apply` here will fail
# with 409 "already installed" — import it via
#   terraform import grafana_cloud_plugin_installation.<name> <stack-slug>:<plugin-slug>
resource "grafana_cloud_plugin_installation" "googlecloud_logging" {
  provider = grafana.cloud

  stack_slug = data.grafana_cloud_stack.main.slug
  slug       = "googlecloud-logging-datasource"
  version    = "1.6.0" # bump as needed; see https://grafana.com/grafana/plugins/googlecloud-logging-datasource/
}

resource "grafana_cloud_plugin_installation" "bigquery" {
  provider = grafana.cloud

  stack_slug = data.grafana_cloud_stack.main.slug
  slug       = "grafana-bigquery-datasource"
  version    = "3.1.5" # bump as needed; see https://grafana.com/grafana/plugins/grafana-bigquery-datasource/
}

# ── Stack-scoped read access policy + token ────────────────────────────────
# Used by the Loki / Prometheus (Mimir) / Tempo / Pyroscope datasources in
# datasources.tf for basic-auth password. Scopes are read-only across the
# stack's data planes; no cross-stack reach.
#
# Unlike the stack-admin SA above, this is a `grafana_cloud_access_policy`
# (data-plane auth) rather than a stack service account (control-plane auth).
# Both auth styles coexist on the same stack.
resource "grafana_cloud_access_policy" "stack_reads" {
  provider = grafana.cloud

  region       = data.grafana_cloud_stack.main.region_slug
  name         = "{{project_slug}}-stack-reads"
  display_name = "{{display_name}} stack reads"

  scopes = [
    "metrics:read",
    "logs:read",
    "traces:read",
    "profiles:read",
    "alerts:read",
    "stacks:read",
  ]

  realm {
    type       = "stack"
    identifier = data.grafana_cloud_stack.main.id
  }
}

resource "grafana_cloud_access_policy_token" "stack_reads" {
  provider = grafana.cloud

  region           = data.grafana_cloud_stack.main.region_slug
  access_policy_id = grafana_cloud_access_policy.stack_reads.policy_id
  name             = "{{project_slug}}-stack-reads"
  display_name     = "{{display_name}} stack reads token"
}
