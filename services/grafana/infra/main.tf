terraform {
  required_version = ">= 1.5"

  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "~> 3.18"
    }
  }

  backend "gcs" {
    bucket = "{{tf_state_bucket}}"
    prefix = "services/grafana"
  }
}

# Cloud control-plane provider: manages plugin installs, stack service
# accounts, and (on Pro tier) stacks themselves at the grafana.com org level.
# Authenticated with an org-scoped access-policy token created once via the
# grafana.com UI and stored in GCP Secret Manager as
# `grafana-cloud-access-policy-token`.
provider "grafana" {
  alias                     = "cloud"
  cloud_access_policy_token = var.cloud_access_policy_token
}

# Stack provider: manages dashboards, folders, datasources, alerting inside
# the stack. Authenticated with the stack service-account token TF mints in
# stack_admin.tf. The URL is read from the data source so this stays correct
# even if the stack moves clusters.
#
# First apply will show stack resources as `(known after apply)` because the
# SA token doesn't exist yet — apply once, then plans are clean afterward.
provider "grafana" {
  alias = "stack"
  url   = data.grafana_cloud_stack.main.url
  auth  = grafana_cloud_stack_service_account_token.tf_admin.key
}
