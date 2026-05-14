output "monitoring_datasource_uid" {
  value = grafana_data_source.gcp_monitoring.uid
}

output "logging_datasource_uid" {
  value = grafana_data_source.gcp_logging.uid
}

output "bigquery_datasource_uid" {
  value = grafana_data_source.bigquery.uid
}

output "prometheus_datasource_uid" {
  value = grafana_data_source.prometheus.uid
}

output "loki_datasource_uid" {
  value = grafana_data_source.loki.uid
}

output "tempo_datasource_uid" {
  value = grafana_data_source.tempo.uid
}

output "pyroscope_datasource_uid" {
  value = grafana_data_source.pyroscope.uid
}

output "stack_url" {
  value = data.grafana_cloud_stack.main.url
}

output "folder_url" {
  value = "${data.grafana_cloud_stack.main.url}/dashboards/f/${grafana_folder.main.uid}"
}

output "dashboard_uids" {
  value = { for k, v in grafana_dashboard.all : k => v.uid }
}

# The minted stack-admin token (a `glsa_…` SA key). Persists in TF state;
# the `grafana.stack` provider in main.tf reads it from state on every
# apply. Not normally needed at the CLI, but consumed by `just export-
# dashboard` and useful for ad-hoc curl debugging.
output "stack_admin_token" {
  value     = grafana_cloud_stack_service_account_token.tf_admin.key
  sensitive = true
}
