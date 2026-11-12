output "origins" {
  description = "CloudFront origins of the status page, for modules/edge."
  value       = module.core.origins
}

output "behaviors" {
  description = "CloudFront ordered cache behaviors of the status page, for modules/edge."
  value       = module.core.behaviors
}
