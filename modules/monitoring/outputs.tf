output "episodes_log_group_name" {
  description = "Log group holding the availability episodes."
  value       = module.availability.episodes_log_group_name
}

output "spot_interruptions_log_group_name" {
  description = "Log group holding the Spot interruption captures."
  value       = module.availability.spot_interruptions_log_group_name
}

output "alarm_topic_arn" {
  description = "ARN of the topic the alarms notify."
  value       = module.availability.sns_topic_arn
}

output "outage_alarm_names" {
  description = "Alarms that fire while the bots are down or split: site down and group size."
  value       = [module.availability.site_down_alarm_name, local.group_size_alarm_name]
}
