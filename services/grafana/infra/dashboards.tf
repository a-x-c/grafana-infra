locals {
  dashboard_files = fileset("${path.module}/../dashboards", "*.json")
}

resource "grafana_dashboard" "all" {
  provider = grafana.stack
  for_each = local.dashboard_files

  folder      = grafana_folder.main.uid
  overwrite   = true
  config_json = file("${path.module}/../dashboards/${each.value}")
}
