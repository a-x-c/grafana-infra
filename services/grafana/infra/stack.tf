# Reference the existing `{{grafana_stack}}.grafana.net` stack rather than
# creating a new one. Grafana Cloud's free tier caps an org at one hosted
# instance per region, so if you want a per-app stack you need Pro tier.
# The recommended pattern is one stack per Cloud org and folder-namespace
# per app — drop new apps' dashboards into their own folder with their own
# UID prefix in the same stack.
#
# Create the stack once via https://grafana.com/orgs/{{grafana_cloud_org}}/stacks
# (or via TF if on Pro — replace this data block with a `grafana_cloud_stack`
# resource).
data "grafana_cloud_stack" "main" {
  provider = grafana.cloud
  slug     = "{{grafana_stack}}"
}
