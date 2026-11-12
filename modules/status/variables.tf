variable "domain_name" {
  description = "Apex domain the status page is served from."
  type        = string
}

variable "distribution_arn" {
  description = "CloudFront distribution ARN the status page's Lambda and bucket are scoped to."
  type        = string
}

variable "asg_name" {
  description = "Auto Scaling group the status page reports on."
  type        = string
}

variable "episodes_log_group" {
  description = "Log group holding the availability episodes (modules/monitoring output)."
  type        = string
}

variable "spot_interruptions_log_group" {
  description = "Log group holding the Spot interruption captures (modules/monitoring output)."
  type        = string
}

variable "metric_namespace" {
  description = "CloudWatch namespace the bot publishes SiteUp to."
  type        = string
}

variable "spot_enabled" {
  description = "Whether the ASG runs Spot, which shows the Spot panel before the first reclaim."
  type        = bool
}

variable "status_key" {
  description = "HMAC key that signs status page tokens. Stored in SSM for the Lambda to verify with."
  type        = string
  sensitive   = true
}

variable "token_key" {
  description = "localStorage key the status page reads its token from."
  type        = string
}
