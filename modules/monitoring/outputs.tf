output "episodes_log_group_name" {
  description = "Log group holding the availability episodes."
  value       = module.availability.episodes_log_group_name
}

output "spot_interruptions_log_group_name" {
  description = "Log group holding the Spot interruption captures."
  value       = module.availability.spot_interruptions_log_group_name
}
