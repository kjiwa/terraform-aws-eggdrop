output "bucket_name" {
  description = "Bot bucket. scripts/upload.sh puts the Eggdrop tarball under eggdrop/ here."
  value       = module.compute.bucket_name
}

output "asg_name" {
  description = "Auto Scaling group name; start an instance refresh on it to replace the bot."
  value       = module.compute.asg_name
}

output "ipv6_cidr_block" {
  description = "The VPC's /56. The bot's address always falls inside it."
  value       = module.network.ipv6_cidr_block
}

output "status_url" {
  description = "Public HTTPS URL of the status page."
  value       = module.edge.url
}
