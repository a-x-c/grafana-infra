resource "grafana_folder" "main" {
  provider = grafana.stack

  title = "{{display_name}}"
  uid   = "{{project_slug}}"
}
