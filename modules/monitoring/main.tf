# canary_enabled is false: the bot publishes SiteUp itself every minute, and
# the alarm reads silence as down. planned_causes is empty: a replacement of
# any kind drops the bot's ops until someone re-ops it, so it is an outage.
module "availability" {
  source = "git::https://github.com/kjiwa/terraform-aws-status-page.git//modules/availability?ref=v0.6.0"

  name_prefix      = "eggdrop"
  metric_namespace = var.metric_namespace
  primary_domain   = var.domain_name
  asg_name         = var.asg_name
  alert_email      = var.alert_email
  active           = var.active
  canary_enabled   = false
  planned_causes   = []

  alarm_publishers = module.host_alarms.alarm_names
}

module "host_alarms" {
  source = "git::https://github.com/kjiwa/terraform-aws-status-page.git//modules/host-alarms?ref=v0.6.0"

  name_prefix                       = "eggdrop"
  metric_namespace                  = var.metric_namespace
  alarm_topic_arn                   = module.availability.sns_topic_arn
  episodes_log_group_name           = module.availability.episodes_log_group_name
  spot_interruptions_log_group_name = module.availability.spot_interruptions_log_group_name
  backup_enabled                    = false
  host_metrics_enabled              = false
}
