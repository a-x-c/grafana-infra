# Alerting scaffold. Everything below is commented out by design — uncomment
# when you want alerts live. The structure is:
#
#   1. A contact point (where notifications go: email, Slack webhook, PagerDuty, ...)
#   2. A notification policy (routing tree; which alerts go to which contact point)
#   3. A rule group (the actual alert rules)
#
# Pre-uncomment checklist:
#   - Make sure the contact point settings (email address / webhook URL) are real.
#   - Pick the right datasource UID in `data` blocks for the rule.
#   - The stack admin SA in stack_admin.tf has role=Admin, so no extra
#     scope grants are needed to manage alert rules.

# ─── Contact point ───────────────────────────────────────────────────────────
# resource "grafana_contact_point" "default" {
#   provider = grafana.stack
#   name     = "{{project_slug}}-default"
#
#   email {
#     addresses               = ["oncall@{{project_slug}}.example.com"]
#     single_email            = false
#     subject                 = "[{{display_name}}] {{ template \"default.title\" . }}"
#     message                 = "{{ template \"default.message\" . }}"
#     disable_resolve_message = false
#   }
#
#   # Or a Slack webhook:
#   # slack {
#   #   url   = "https://hooks.slack.com/services/..."
#   #   title = "[{{display_name}}] alert"
#   # }
# }

# ─── Notification policy (root) ──────────────────────────────────────────────
# resource "grafana_notification_policy" "root" {
#   provider      = grafana.stack
#   contact_point = grafana_contact_point.default.name
#   group_by      = ["grafana_folder", "alertname"]
#
#   group_wait      = "30s"
#   group_interval = "5m"
#   repeat_interval = "4h"
# }

# ─── Rule group: Cloud Run health ────────────────────────────────────────────
# resource "grafana_rule_group" "cloud_run_health" {
#   provider         = grafana.stack
#   name             = "Cloud Run health"
#   folder_uid       = grafana_folder.main.uid
#   interval_seconds = 60
#
#   rule {
#     name      = "Cloud Run 5xx rate > 1% for 5m"
#     condition = "C"
#     for       = "5m"
#     no_data_state  = "OK"
#     exec_err_state = "Error"
#
#     # A: pull request_count partitioned by response_code_class
#     data {
#       ref_id     = "A"
#       relative_time_range { from = 600; to = 0 }
#       datasource_uid = grafana_data_source.gcp_monitoring.uid
#       model = jsonencode({
#         refId       = "A"
#         queryType   = "metrics"
#         metricQuery = {
#           projectName        = var.gcp_project_id
#           metricType         = "run.googleapis.com/request_count"
#           perSeriesAligner   = "ALIGN_RATE"
#           crossSeriesReducer = "REDUCE_SUM"
#           groupBys           = ["resource.label.service_name", "metric.label.response_code_class"]
#           alignmentPeriod    = "60s"
#         }
#       })
#     }
#
#     # B: reduce to one value per series (last)
#     data {
#       ref_id         = "B"
#       relative_time_range { from = 0; to = 0 }
#       datasource_uid = "__expr__"
#       model = jsonencode({
#         refId      = "B"
#         type       = "reduce"
#         expression = "A"
#         reducer    = "last"
#       })
#     }
#
#     # C: threshold — fire when 5xx share > 0.01 (placeholder; real ratio needs a math expr over labels)
#     data {
#       ref_id         = "C"
#       relative_time_range { from = 0; to = 0 }
#       datasource_uid = "__expr__"
#       model = jsonencode({
#         refId      = "C"
#         type       = "threshold"
#         expression = "B"
#         conditions = [{
#           evaluator = { type = "gt", params = [0.01] }
#           operator  = { type = "and" }
#           query     = { params = ["C"] }
#           reducer   = { type = "last", params = [] }
#           type      = "query"
#         }]
#       })
#     }
#
#     labels = {
#       severity = "page"
#       team     = "{{project_slug}}"
#     }
#     annotations = {
#       summary     = "Cloud Run 5xx rate elevated"
#       description = "Sustained 5xx rate above threshold for at least 5 minutes."
#     }
#   }
# }
