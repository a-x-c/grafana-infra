# All three datasources auth to GCP via the same JWT (the grafana-cloud-reader
# service account). Role bindings on the SA in GCP IAM determine what each can
# actually read; see the service README for the minimum set.

resource "grafana_data_source" "gcp_monitoring" {
  provider = grafana.stack

  type = "stackdriver" # built-in; no plugin install needed
  uid  = "{{project_slug}}-gcp-monitoring"
  name = "GCP Monitoring ({{gcp_project}})"

  json_data_encoded = jsonencode({
    authenticationType = "jwt"
    defaultProject     = var.gcp_project_id
    tokenUri           = "https://oauth2.googleapis.com/token"
    clientEmail        = jsondecode(var.gcp_sa_jwt).client_email
  })

  secure_json_data_encoded = jsonencode({
    privateKey = jsondecode(var.gcp_sa_jwt).private_key
  })
}

resource "grafana_data_source" "gcp_logging" {
  provider   = grafana.stack
  depends_on = [grafana_cloud_plugin_installation.googlecloud_logging]

  type = "googlecloud-logging-datasource"
  uid  = "{{project_slug}}-gcp-logging"
  name = "GCP Logging ({{gcp_project}})"

  json_data_encoded = jsonencode({
    authenticationType = "jwt"
    defaultProject     = var.gcp_project_id
    tokenUri           = "https://oauth2.googleapis.com/token"
    clientEmail        = jsondecode(var.gcp_sa_jwt).client_email
  })

  secure_json_data_encoded = jsonencode({
    privateKey = jsondecode(var.gcp_sa_jwt).private_key
  })
}

resource "grafana_data_source" "bigquery" {
  provider   = grafana.stack
  depends_on = [grafana_cloud_plugin_installation.bigquery]

  type = "grafana-bigquery-datasource"
  uid  = "{{project_slug}}-bigquery"
  name = "BigQuery ({{gcp_project}})"

  json_data_encoded = jsonencode({
    authenticationType = "jwt"
    defaultProject     = var.gcp_project_id
    tokenUri           = "https://oauth2.googleapis.com/token"
    clientEmail        = jsondecode(var.gcp_sa_jwt).client_email
  })

  secure_json_data_encoded = jsonencode({
    privateKey = jsondecode(var.gcp_sa_jwt).private_key
  })
}

# ── Grafana-Cloud-hosted backends ──────────────────────────────────────────
# Prometheus (Mimir), Loki, Tempo, and Pyroscope are part of every Grafana
# Cloud stack. Each one's URL + numeric user ID is exposed by the stack data
# source; auth is basic-auth using the user ID + a stack-scoped access policy
# token minted in stack_admin.tf (`grafana_cloud_access_policy_token.stack_reads`).
#
# All four UIDs follow the same `<project_slug>-<service>` convention as the
# GCP datasources so dashboard panels can hard-code `datasource.uid`.

resource "grafana_data_source" "prometheus" {
  provider = grafana.stack

  type = "prometheus"
  uid  = "{{project_slug}}-prometheus"
  name = "Mimir ({{display_name}})"
  url  = data.grafana_cloud_stack.main.prometheus_url

  basic_auth_enabled  = true
  basic_auth_username = data.grafana_cloud_stack.main.prometheus_user_id

  json_data_encoded = jsonencode({
    httpMethod     = "POST"
    prometheusType = "Mimir"
    timeInterval   = "60s"
  })

  secure_json_data_encoded = jsonencode({
    basicAuthPassword = grafana_cloud_access_policy_token.stack_reads.token
  })
}

resource "grafana_data_source" "loki" {
  provider = grafana.stack

  type = "loki"
  uid  = "{{project_slug}}-loki"
  name = "Loki ({{display_name}})"
  url  = data.grafana_cloud_stack.main.logs_url

  basic_auth_enabled  = true
  basic_auth_username = data.grafana_cloud_stack.main.logs_user_id

  secure_json_data_encoded = jsonencode({
    basicAuthPassword = grafana_cloud_access_policy_token.stack_reads.token
  })
}

resource "grafana_data_source" "tempo" {
  provider = grafana.stack

  type = "tempo"
  uid  = "{{project_slug}}-tempo"
  name = "Tempo ({{display_name}})"
  url  = data.grafana_cloud_stack.main.traces_url

  basic_auth_enabled  = true
  basic_auth_username = data.grafana_cloud_stack.main.traces_user_id

  # Link Tempo traces back to logs/metrics in the same stack for one-click
  # exemplar navigation. UIDs match the resources above so the wiring is
  # static and review-friendly.
  json_data_encoded = jsonencode({
    tracesToLogsV2 = {
      datasourceUid      = "{{project_slug}}-loki"
      spanStartTimeShift = "-1m"
      spanEndTimeShift   = "1m"
      filterByTraceID    = true
      filterBySpanID     = false
    }
    tracesToMetrics = {
      datasourceUid = "{{project_slug}}-prometheus"
    }
    tracesToProfiles = {
      datasourceUid = "{{project_slug}}-pyroscope"
      profileTypeId = "process_cpu:cpu:nanoseconds:cpu:nanoseconds"
    }
    serviceMap = {
      datasourceUid = "{{project_slug}}-prometheus"
    }
    nodeGraph = { enabled = true }
  })

  secure_json_data_encoded = jsonencode({
    basicAuthPassword = grafana_cloud_access_policy_token.stack_reads.token
  })
}

resource "grafana_data_source" "pyroscope" {
  provider = grafana.stack

  type = "grafana-pyroscope-datasource"
  uid  = "{{project_slug}}-pyroscope"
  name = "Pyroscope ({{display_name}})"
  url  = data.grafana_cloud_stack.main.profiles_url

  basic_auth_enabled  = true
  basic_auth_username = data.grafana_cloud_stack.main.profiles_user_id

  secure_json_data_encoded = jsonencode({
    basicAuthPassword = grafana_cloud_access_policy_token.stack_reads.token
  })
}
