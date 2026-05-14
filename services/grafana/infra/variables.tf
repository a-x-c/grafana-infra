variable "cloud_access_policy_token" {
  description = "Grafana Cloud org-level access-policy token (`glc_…`). One-time create at https://grafana.com/orgs/{{grafana_cloud_org}}/access-policies with scopes `stack-service-accounts:write`, `stack-plugins:write` (+ `stacks:write` if you create stacks via TF on Pro tier). Store in GCP Secret Manager as `grafana-cloud-access-policy-token`; read at plan/apply via TF_VAR_cloud_access_policy_token."
  type        = string
  sensitive   = true
}

variable "gcp_project_id" {
  description = "GCP project that Cloud Monitoring / Cloud Logging / BigQuery read from."
  type        = string
  default     = "{{gcp_project}}"
}

variable "gcp_sa_jwt" {
  description = "JSON key for the grafana-cloud-reader GCP service account. Read at apply time from GCP Secret Manager (`grafana-cloud-reader-sa-key`) via TF_VAR_gcp_sa_jwt."
  type        = string
  sensitive   = true
}
