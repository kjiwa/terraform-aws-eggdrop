output "name_servers" {
  description = "Name servers to set at the registrar for the domain."
  value       = aws_route53_zone.this.name_servers
}

output "status_url" {
  description = "Public HTTPS URL of the status page."
  value       = module.eggdrop.status_url
}

output "bucket_name" {
  description = "Bot bucket. scripts/upload.sh puts the Eggdrop tarball here."
  value       = module.eggdrop.bucket_name
}
