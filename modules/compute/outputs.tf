output "bucket_name" {
  description = "Bot bucket. scripts/upload.sh puts the Eggdrop tarball under eggdrop/ here."
  value       = aws_s3_bucket.this.id
}

output "irc_log_group_name" {
  description = "Log group the bots write server events to."
  value       = aws_cloudwatch_log_group.irc.name
}

output "slot_gate_seconds" {
  description = "Minimum seconds between a bot's jumps to its slot server."
  value       = local.slot_gate_seconds
}

output "asg_name" {
  description = "Auto Scaling group name."
  value       = aws_autoscaling_group.this.name
}
