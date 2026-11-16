locals {
  # Minimum over a minute is the smallest value any bot reports; two jump
  # gates outlast one failed-over bot returning to its slot server.
  on_slot_alarm_minutes = 2 * var.slot_gate_seconds / 60

  # Named here, not read from the alarm, which needs the topic this feeds.
  group_size_alarm_name = "eggdrop-group-size"
  on_slot_alarm_name    = "eggdrop-on-slot-server"
}

# canary_enabled is false: the bot publishes SiteUp itself every minute, and
# the alarm reads silence as down. planned_causes is empty: an outage is no
# bot connected, and a replacement counts only if it leaves none.
module "availability" {
  source = "git::https://github.com/kjiwa/terraform-aws-status-page.git//modules/availability?ref=v0.8.0"

  name_prefix      = "eggdrop"
  metric_namespace = var.metric_namespace
  primary_domain   = var.domain_name
  asg_name         = var.asg_name
  alert_email      = var.alert_email
  active           = var.active
  canary_enabled   = false
  planned_causes   = []

  # Any bad minute alarms: eggdrop's server-cycle-wait is 60 s, so every
  # disconnect spans at least one heartbeat.
  site_down_alarm = { datapoints_to_alarm = 1 }

  alarm_publishers = concat(module.host_alarms.alarm_names, [local.group_size_alarm_name, local.on_slot_alarm_name])
}

module "host_alarms" {
  source = "git::https://github.com/kjiwa/terraform-aws-status-page.git//modules/host-alarms?ref=v0.8.0"

  name_prefix                       = "eggdrop"
  metric_namespace                  = var.metric_namespace
  alarm_topic_arn                   = module.availability.sns_topic_arn
  episodes_log_group_name           = module.availability.episodes_log_group_name
  spot_interruptions_log_group_name = module.availability.spot_interruptions_log_group_name
  backup_enabled                    = false
  host_metrics_enabled              = false
}

# Minimum over a minute is the smallest group any bot sees. Missing data is
# breaching: with no bot connected nobody publishes.
resource "aws_cloudwatch_metric_alarm" "group_size" {
  count = var.active ? 1 : 0

  alarm_name          = local.group_size_alarm_name
  alarm_description   = "Fewer than ${var.group_size} listed nicks share a channel for 20 minutes: a bot is down, split off or on another network."
  namespace           = var.metric_namespace
  metric_name         = "GroupSize"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 20
  datapoints_to_alarm = 20
  comparison_operator = "LessThanThreshold"
  threshold           = var.group_size
  treat_missing_data  = "breaching"
  alarm_actions       = [module.availability.sns_topic_arn]
  ok_actions          = [module.availability.sns_topic_arn]
}

# Silence is not a breach: SiteUp covers it.
resource "aws_cloudwatch_metric_alarm" "on_slot_server" {
  count = var.active ? 1 : 0

  alarm_name          = local.on_slot_alarm_name
  alarm_description   = "A bot has been off its slot server for ${local.on_slot_alarm_minutes} minutes: its slot server refuses it, or it cannot return."
  namespace           = var.metric_namespace
  metric_name         = "OnSlotServer"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = local.on_slot_alarm_minutes
  datapoints_to_alarm = local.on_slot_alarm_minutes
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [module.availability.sns_topic_arn]
  ok_actions          = [module.availability.sns_topic_arn]
}
